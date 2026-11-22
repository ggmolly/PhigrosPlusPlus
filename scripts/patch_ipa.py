"""usage: patch_ipa.py <in.ipa> <out.ipa> <libphigrospp.dylib> <dump/script.json> <sources...>, copies the game's ipa with
phigros++ in it: UnityFramework loads the library, the app is Phigros++ (sh.molly.phigrosplusplus) with its folder shown
in the Files app, and the store's signature and data are left out for AltStore or SideStore to sign it. the other
entries are copied byte for byte.

ios doesn't let an app write code without a debugger, so the hooks are written here instead: every method the sources
may hook (its class and its name are strings or names in them) starts with a jump to a stub, which jumps to the
address in its slot of a table in UnityFramework's data, or goes on with the method while the slot is 0. hooking it
is then writing its slot (phigrospp/ios.c)"""
import io
import json
import os
import plistlib
import re
import struct
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from patch_apk import added, badge, data_offset, put  # noqa: E402

APP = "Payload/Phigros.app/"
UNITY = APP + "Frameworks/UnityFramework.framework/UnityFramework"
LIB = "Frameworks/libphigrospp.dylib"
# the store's data and the account that bought the game. each bundle's _CodeSignature/ and SC_Info/ (its encryption
# info) go too
DROPPED = ("META-INF/", "iTunesMetadata.plist", "iTunesArtwork", APP + "embedded.mobileprovision")
# the home screen icon, drawn from the store's 600 px artwork with the ++ tab at every size ios asks for. the game's
# own comes from Assets.car, a compiled catalog, so CFBundleIconName goes and ios uses these files instead
ICONS = {"AppIcon60x60@2x.png": 120, "AppIcon60x60@3x.png": 180, "AppIcon76x76@2x~ipad.png": 152,
         "AppIcon83.5x83.5@2x~ipad.png": 167}
ICON_FILES = {"CFBundleIcons": ["AppIcon60x60"], "CFBundleIcons~ipad": ["AppIcon60x60", "AppIcon76x76", "AppIcon83.5x83.5"]}
INFO = {
    "CFBundleIdentifier": "sh.molly.phigrosplusplus",
    "CFBundleDisplayName": "Phigros++",
    "UIFileSharingEnabled": True,  # Documents/phigros++ in the Files app, to add mods and charts
    "LSSupportsOpeningDocumentsInPlace": True,
    "CADisableMinimumFrameDurationOnPhone": True,  # 120 Hz on iphones that have it
}


# a LC_LOAD_DYLIB of the library after the last load command, in the free space before the first section
def load_library(data):
    magic, _, _, _, count, size = struct.unpack_from("<IiiIII", data)
    assert magic == 0xFEEDFACF, "UnityFramework isn't a 64-bit mach-o"
    at, first = 32, len(data)
    for _ in range(count):
        command, length = struct.unpack_from("<II", data, at)
        if command == 0x19:  # LC_SEGMENT_64: its sections (80 bytes each) follow its 72 bytes
            for i in range(struct.unpack_from("<I", data, at + 64)[0]):
                offset = struct.unpack_from("<I", data, at + 72 + i * 80 + 48)[0]
                first = min(first, offset or first)
        at += length
    path = b"@executable_path/" + LIB.encode()
    name = path + bytes(1 + -(len(path) + 1) % 8)
    load = struct.pack("<6I", 0xC, 24 + len(name), 24, 2, 0, 0) + name  # name offset, timestamp, versions
    end = 32 + size
    assert end + len(load) <= first and not any(data[end:end + len(load)]), "no room for a load command"
    out = bytearray(data)
    out[end:end + len(load)] = load
    struct.pack_into("<II", out, 16, count + 1, size + len(load))
    return bytes(out)


def segments(data):
    """{name: (vmaddr, vmsize, fileoff, end of its last section)} of a 64-bit mach-o"""
    _, _, _, _, count, _ = struct.unpack_from("<IiiIII", data)
    found, at = {}, 32
    for _ in range(count):
        command, length = struct.unpack_from("<II", data, at)
        if command == 0x19:
            name = data[at + 8:at + 24].rstrip(b"\0").decode()
            vmaddr, vmsize, fileoff = struct.unpack_from("<QQQ", data, at + 24)
            end = vmaddr
            for i in range(struct.unpack_from("<I", data, at + 64)[0]):
                addr, size = struct.unpack_from("<QQ", data, at + 72 + i * 80 + 32)
                end = max(end, addr + size)
            found[name] = (vmaddr, vmsize, fileoff, end)
        at += length
    return found


def symbol(data, name):
    _, _, _, _, count, _ = struct.unpack_from("<IiiIII", data)
    at = 32
    for _ in range(count):
        command, length = struct.unpack_from("<II", data, at)
        if command == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, _ = struct.unpack_from("<IIII", data, at + 8)
            for i in range(nsyms):
                strx, _, _, _, value = struct.unpack_from("<IBBHQ", data, symoff + 16 * i)
                if data[stroff + strx:data.index(b"\0", stroff + strx)] == name:
                    return value
        at += length
    raise KeyError(name)


# the strings of a lua or c file, skipping comments (the other groups are delimiters)
LUA_STRINGS = re.compile(r'--\[(=*)\[.*?\]\1\]|--[^\n]*|"((?:[^"\\\n]|\\.)*)"|\'((?:[^\'\\\n]|\\.)*)\'|\[(=*)\[(.*?)\]\4\]',
                         re.S)
C_STRINGS = re.compile(r'//[^\n]*|/\*.*?\*/|\'(?:[^\'\\\n]|\\.)*\'|"((?:[^"\\\n]|\\.)*)"', re.S)


def hooked(dump, sources):
    """code addresses of the methods the sources may hook"""
    strings, names = set(), set()
    for path in sources:
        text = open(path, encoding="utf-8").read()
        names |= set(re.findall(r"[A-Za-z_]\w*", text))
        lua = path.endswith(".lua")
        for match in (LUA_STRINGS if lua else C_STRINGS).finditer(text):
            strings |= {match[i] for i in ((2, 3, 5) if lua else (1,)) if match[i]}
        if lua:  # table keys name methods too ({ get_width = "width" })
            strings |= set(re.findall(r"([A-Za-z_]\w*)\s*=(?!=)", text))
    found = set()
    for method in json.load(open(dump))["ScriptMethod"]:
        cls, _, name = method["Name"].rpartition("$$")
        # a coroutine or lambda class (Outer.<Start>d__4) counts as its outer class, which a pattern finds by that
        # name alone. another class is named with its namespace, and generic ones not at all
        outer = re.match(r"^(?:[\w.]*\.)?(\w+)\.<", cls)
        if name in strings and (outer.group(1) in names if outer else "<" not in cls and names.issuperset(cls.split("."))):
            found.add(method["Address"])
    return sorted(found)


B, BL_MASK = 0x14000000, 0x7C000000


def adrp(register, at, to):
    page = ((to >> 12) - (at >> 12)) & 0x1FFFFF
    return 0x90000000 | (page & 3) << 29 | (page >> 2) << 5 | register


def relocated(insn, at, to):
    """the instruction at `at` moved to `to`, None when it can't be (a short pc relative one)"""
    if insn & BL_MASK == B:  # b, bl
        target = at + ((insn & 0x3FFFFFF) ^ 0x2000000) * 4 - 0x8000000
        return insn & 0xFC000000 | ((target - to) >> 2) & 0x3FFFFFF
    if insn & 0x9F000000 == 0x90000000:  # adrp
        imm = ((insn >> 29 & 3) | (insn >> 5 & 0x7FFFF) << 2) ^ 0x100000
        return adrp(insn & 31, to, (at & ~0xFFF) + ((imm - 0x100000) << 12))
    if insn & 0x9F000000 == 0x10000000 or insn & 0x3B000000 == 0x18000000 or insn & 0x7C000000 == 0x34000000 or \
            insn & 0xFF000010 == 0x54000000:  # adr, literal loads, cbz/tbz, b.cond
        return None
    return insn


def prepatch(data, dump, sources):
    out = bytearray(data)
    text, rw = segments(data)["__TEXT"], segments(data)["__DATA"]
    assert text[0] == text[2] == 0, "__TEXT doesn't start the file"
    at, stubs_end = (text[3] + 15) & ~15, text[0] + text[1]  # the free end of __TEXT, zeros in the file
    slot, slots_end = (rw[3] + 7) & ~7, rw[0] + rw[1]  # the free end of __DATA, zeros in memory
    assert not any(data[at:stubs_end]), "the end of __TEXT isn't free"
    count = 0
    for target in [symbol(data, b"_il2cpp_init")] + hooked(dump, sources):
        assert target < text[3], f"{target:#x} isn't code"
        insn = struct.unpack_from("<I", data, target)[0]
        moved = relocated(insn, target, at + 16)
        if moved is None:
            continue
        assert at + 24 <= stubs_end and slot + 8 <= slots_end, "no room for more hooks at the end of UnityFramework's __TEXT (about 630)"
        # adrp x16, slot / ldr x16, [x16, slot] / cbz x16, +8 / br x16 / the method's first instruction / b back
        struct.pack_into("<6I", out, at, adrp(16, at, slot), 0xF9400210 | (slot & 0xFFF) >> 3 << 10, 0xB4000050,
                         0xD61F0200, moved, B | ((target + 4 - at - 20) >> 2) & 0x3FFFFFF)
        struct.pack_into("<I", out, target, B | ((at - target) >> 2) & 0x3FFFFFF)
        at, slot, count = at + 24, slot + 8, count + 1
    print(f"{count} methods hookable without JIT")
    return bytes(out)


def icon(artwork, size):
    from PIL import Image
    png = io.BytesIO()
    Image.open(io.BytesIO(artwork)).convert("RGB").resize((size, size), Image.LANCZOS).save(png, "PNG")
    return badge(png.getvalue(), inset=0.06)


def main(src, dst, lib, dump, *sources):
    central = []
    with zipfile.ZipFile(src) as ipa, open(src, "rb") as raw, open(dst, "wb") as out:
        for info in ipa.infolist():
            if info.filename.startswith(DROPPED) or "/_CodeSignature/" in info.filename or "/SC_Info/" in info.filename \
                    or info.filename[len(APP):] in ICONS:
                continue
            if info.filename == APP + "Info.plist":
                plist = plistlib.loads(ipa.read(info))
                plist.update(INFO)
                plist.pop("UISupportedDevices", None)
                for key, files in ICON_FILES.items():
                    plist[key] = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": files}}
                added(out, central, info.filename, plistlib.dumps(plist, fmt=plistlib.FMT_BINARY), mode=0o100644)
            elif info.filename == UNITY:
                unity = prepatch(load_library(ipa.read(info)), dump, sources)
                added(out, central, info.filename, unity, mode=0o100755)
            else:
                raw.seek(data_offset(raw, info))
                put(out, central, info, raw, align=False)
        with open(lib, "rb") as f:
            added(out, central, APP + LIB, f.read(), mode=0o100755)
        artwork = ipa.read("iTunesArtwork")
        for name, size in ICONS.items():
            added(out, central, APP + name, icon(artwork, size), mode=0o100644)
        start = out.tell()
        out.write(b"".join(central))
        out.write(struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(central), len(central), out.tell() - start, start, 0))


if __name__ == "__main__":
    main(*sys.argv[1:])
