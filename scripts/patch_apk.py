"""usage: patch_apk.py <in.apk> <out.apk> <package> [<path in apk>=<file>...], copies an apk under another package
(the providers named after it follow), named Phigros++ in the launcher, with the files given put in and the store's
signature left out. the other entries are copied byte for byte, keeping the build fast and reproducible"""
import struct
import sys
import zipfile
import zlib

ORIGINAL = "com.PigeonGames.Phigros"
LABEL = "Phigros++"
LABEL_ATTRIBUTE = 0x01010001  # android:label
# apksigner drops the source stamp, dropping it here lets a release be compared without its signature
DROPPED = ("META-INF/BNDLTOOL.", "META-INF/MANIFEST.MF", "stamp-cert-sha256")


def length(data, at, utf8):
    if utf8:
        n = data[at]
        return ((n & 0x7F) << 8 | data[at + 1], at + 2) if n & 0x80 else (n, at + 1)
    n = struct.unpack_from("<H", data, at)[0]
    return ((n & 0x7FFF) << 16 | struct.unpack_from("<H", data, at + 2)[0], at + 4) if n & 0x8000 else (n, at + 2)


def encode(s, utf8):
    def size(n, wide):
        if wide:
            return struct.pack("<H", n) if n < 0x8000 else struct.pack("<HH", 0x8000 | n >> 16, n & 0xFFFF)
        return bytes([n]) if n < 0x80 else bytes([0x80 | n >> 8, n & 0xFF])
    if utf8:
        b = s.encode()
        return size(len(s), False) + size(len(b), False) + b + b"\0"
    u = s.encode("utf-16-le")
    return size(len(u) // 2, True) + u + b"\0\0"


# a binary manifest is a string pool then the elements, which point into the pool by index
def manifest(data, package):
    pool = 8
    _, header, size, count, styles, flags, start, _ = struct.unpack_from("<HHIIIIII", data, pool)
    assert styles == 0, "AndroidManifest.xml: styled strings aren't handled"
    utf8 = bool(flags & 0x100)
    strings = []
    for offset in struct.unpack_from(f"<{count}I", data, pool + header):
        n, at = length(data, pool + start + offset, utf8)
        if utf8:
            n, at = length(data, at, utf8)
            strings.append(data[at:at + n].decode())
        else:
            strings.append(data[at:at + 2 * n].decode("utf-16-le"))
    strings = [package + s[len(ORIGINAL):] if s == ORIGINAL or s.startswith(ORIGINAL + ".") and s.endswith(".provider")
               else s for s in strings]

    rest, at, ids = bytearray(data[pool + size:]), 0, ()
    while at < len(rest):
        kind, _, chunk = struct.unpack_from("<HHI", rest, at)
        if kind == 0x0180:  # resource ids of the first strings, the attribute names
            ids = struct.unpack_from(f"<{(chunk - 8) // 4}I", rest, at + 8)
        elif kind == 0x0102 and strings[struct.unpack_from("<I", rest, at + 20)[0]] == "application":
            first, step, attributes = struct.unpack_from("<HHH", rest, at + 24)
            for i in range(attributes):
                attribute = at + 16 + first + i * step
                if ids[struct.unpack_from("<I", rest, attribute + 4)[0]] == LABEL_ATTRIBUTE:
                    strings.append(LABEL)
                    struct.pack_into("<IHBBI", rest, attribute + 8, len(strings) - 1, 8, 0, 0x03, len(strings) - 1)
        at += chunk

    offsets, body = [], b""
    for s in strings:
        offsets.append(len(body))
        body += encode(s, utf8)
    body += bytes(-len(body) % 4)
    header = 28 + 4 * len(strings)
    pool = struct.pack("<HHIIIIII", 1, 28, header + len(body), len(strings), 0, flags, header, 0)
    pool += struct.pack(f"<{len(offsets)}I", *offsets) + body
    return struct.pack("<HHI", 3, 8, 8 + len(pool) + len(rest)) + pool + rest


# unity finds its strings with getIdentifier(name, type, getPackageName()), which only searches the resource table's
# package of that name
def resources(data, package):
    data, at = bytearray(data), struct.unpack_from("<H", data, 2)[0]
    while at < len(data):
        kind, _, size = struct.unpack_from("<HHI", data, at)
        if kind == 0x0200 and data[at + 12:at + 268].decode("utf-16-le").rstrip("\0") == ORIGINAL:
            data[at + 12:at + 268] = package.encode("utf-16-le").ljust(256, b"\0")
        at += size
    return bytes(data)


def data_offset(file, info):
    file.seek(info.header_offset + 26)
    name, extra = struct.unpack("<HH", file.read(4))
    return info.header_offset + 30 + name + extra


# an uncompressed entry's data starts on its alignment, as android requires for resources.arsc, padded with the extra
# field zipalign uses (0xd935)
def put(out, central, info, source):
    name, offset, extra = info.filename.encode(), out.tell(), b""
    if info.compress_type == zipfile.ZIP_STORED:
        align = 16384 if info.filename.endswith(".so") else 4
        pad = -(offset + 30 + len(name)) % align
        while pad and pad < 6:
            pad += align
        extra = struct.pack("<HHH", 0xD935, pad - 4, align) + bytes(pad - 6) if pad else b""
    y, mo, d, h, mi, s = info.date_time
    fields = struct.pack("<HHHHHIII", info.extract_version, info.flag_bits & ~8, info.compress_type,
                         h << 11 | mi << 5 | s // 2, (y - 1980) << 9 | mo << 5 | d, info.CRC, info.compress_size,
                         info.file_size)
    out.write(struct.pack("<I", 0x04034B50) + fields + struct.pack("<HH", len(name), len(extra)) + name + extra)
    if isinstance(source, bytes):
        out.write(source)
    else:
        left = info.compress_size
        while left:
            chunk = source.read(min(left, 1 << 20))
            out.write(chunk)
            left -= len(chunk)
    central.append(struct.pack("<IH", 0x02014B50, info.create_system << 8 | info.create_version) + fields +
                   struct.pack("<HHHHHII", len(name), 0, 0, 0, 0, info.external_attr, offset) + name)


def added(out, central, name, data, method=zipfile.ZIP_DEFLATED):
    deflate = zlib.compressobj(9, zlib.DEFLATED, -15)
    compressed = deflate.compress(data) + deflate.flush() if method == zipfile.ZIP_DEFLATED else data
    info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
    info.compress_type, info.create_system, info.CRC = method, 0, zlib.crc32(data)
    info.compress_size, info.file_size = len(compressed), len(data)
    put(out, central, info, compressed)


def main(src, dst, package, *files):
    files = dict(f.split("=", 1) for f in files)
    central = []
    with zipfile.ZipFile(src) as apk, open(src, "rb") as raw, open(dst, "wb") as out:
        for info in apk.infolist():
            if info.filename.startswith(DROPPED) or info.filename in files:
                continue
            if info.filename == "AndroidManifest.xml":
                added(out, central, info.filename, manifest(apk.read(info), package))
            elif info.filename == "resources.arsc":
                added(out, central, info.filename, resources(apk.read(info), package), zipfile.ZIP_STORED)
            else:
                raw.seek(data_offset(raw, info))
                put(out, central, info, raw)
        for name, path in files.items():
            with open(path, "rb") as f:
                added(out, central, name, f.read())
        start = out.tell()
        out.write(b"".join(central))
        out.write(struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(central), len(central), out.tell() - start, start, 0))


if __name__ == "__main__":
    main(*sys.argv[1:])
