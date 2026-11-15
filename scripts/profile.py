"""usage: profile.py <script.json> [seconds] [thread], records the game on the plugged device with simpleperf (the app is
profileable) and prints where a thread (UnityMain by default) spends its time, running or waiting, by C# method from
the il2cpp dump's script.json, and in each hitch the performance monitor logged. the stacks of every thread go to
build/profile.folded, for a flame graph on speedscope.app"""
import bisect
import collections
import json
import os
import re
import subprocess
import sys

PACKAGE = os.environ.get("PACKAGE", "sh.molly.phigrosplusplus")
DATA = "/data/local/tmp/phigrospp.data"
BUILD = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "build")
FOLDED = os.path.join(BUILD, "profile.folded")
TOP = 40
HITCH = re.compile(r"monitor: hitch from ([\d.]+) to ([\d.]+)(.*)")


def adb(*args):
    subprocess.run(["adb", "shell", *args], check=True)


# methods by address. the dump's other addresses start functions il2cpp has no name for (its runtime, generic
# sharing), so code after them isn't put on the method before
def methods(path):
    dump = json.load(open(path))
    names = {m["Address"]: m["Name"].replace("$$", ".") for m in dump["ScriptMethod"]}
    starts = sorted(set(dump["Addresses"]) | set(names))
    return starts, names


# phigros++'s own functions, from the unstripped copy the build keeps (the device's is stripped)
def ours():
    out = subprocess.run(["nm", "-n", "--defined-only", os.path.join(BUILD, "libphigrospp.sym.so")],
                         capture_output=True, text=True).stdout
    symbols = [(int(a, 16), n) for a, kind, n in (line.split() for line in out.splitlines()) if kind in "tT"]
    return [a for a, _ in symbols], [n for _, n in symbols]


def name(frame, starts, names, symbols):
    file, address, symbol = frame
    library = file.rsplit("/", 1)[-1]
    if library == "libil2cpp.so":
        start = starts[bisect.bisect_right(starts, address) - 1]
        return names.get(start, f"libil2cpp+{start:x}")
    if library == "libphigrospp.so" and symbols[0]:
        return "phigros++ " + symbols[1][bisect.bisect_right(symbols[0], address) - 1]
    if library == "[kernel.kallsyms]":
        return "kernel"  # its addresses are hidden from apps on a user build
    return f"{library} {symbol}" if symbol else f"{library}+{address:x}"


# report-sample's text, read as it comes: a sample's fields, then its callchain's frames as vaddr_in_file, file and
# symbol lines
def samples():
    report = subprocess.Popen(["adb", "shell", "simpleperf", "report-sample", "-i", DATA, "--show-callchain"],
                              stdout=subprocess.PIPE, text=True)
    sample = None
    for line in report.stdout:
        key, _, value = line.strip().partition(": ")
        if line.startswith("sample:"):
            if sample:
                yield sample
            sample, frame = {"frames": []}, None
        elif sample is None:
            continue
        elif key in ("time", "event_count", "thread_name"):
            sample[key] = value
        elif key == "vaddr_in_file":
            frame = [None, int(value, 16), ""]
            sample["frames"].append(frame)
        elif key == "file":
            frame[0] = value
        elif key == "symbol":
            frame[2] = value
    if sample:
        yield sample
    assert report.wait() == 0, "simpleperf report-sample failed"


def table(title, counts, total, top=TOP):
    print(f"\n{title}")
    for key, count in counts.most_common(top):
        print(f"{100 * count / total:6.2f}%  {count / 1e6:9.1f} ms  {key}")


# what the thread did during each hitch of the log, by overlap with its samples. what nearly all of its time goes
# through (its thread's loop) isn't shown
def hitches(stacks, everywhere):
    log = subprocess.run(["adb", "logcat", "-d", "-s", "phigros++"], check=True, capture_output=True, text=True).stdout
    first, last = min(t for t, _, _ in stacks), max(t for t, _, _ in stacks)
    for match in HITCH.finditer(log):
        start, end = (int(float(x) * 1e9) for x in match.groups()[:2])
        if not first <= start <= last:
            continue
        inside = collections.Counter()
        for t, count, frames in stacks:
            overlap = min(end, t + count) - max(start, t)  # a sample covers the time from it to the next one
            for frame in set(frames) - everywhere if overlap > 0 else ():
                inside[frame] += overlap
        table(f"hitch of {(end - start) / 1e6:.0f} ms, {(start - first) / 1e9:.1f} s in{match.group(3)}", inside,
              end - start, 15)


def main(script, seconds="10", thread="UnityMain"):
    starts, names, symbols = *methods(script), ours()
    print(f"recording {seconds} s of {PACKAGE}, play now")
    # dwarf unwinding copies the top of the stack with every sample, unity's code has no frame pointers to follow. 32 KB
    # a thousand times a second is enough and keeps a minute under 100 MB
    adb("simpleperf", "record", "--app", PACKAGE, "-e", "cpu-clock", "-f", "1000", "--trace-offcpu",
        "--call-graph", "dwarf,32768", "--clockid", "monotonic", "--duration", seconds, "-o", DATA)
    threads, own, inside, folded = collections.Counter(), collections.Counter(), collections.Counter(), collections.Counter()
    stacks = []
    for sample in samples():
        count, frames = int(sample["event_count"]), [name(f, starts, names, symbols) for f in sample["frames"]]
        frames = [f for i, f in enumerate(frames) if i == 0 or f != frames[i - 1]]  # runs of kernel frames
        threads[sample["thread_name"]] += count
        folded[";".join([sample["thread_name"], *reversed(frames)])] += count
        if sample["thread_name"] == thread:
            stacks.append((int(sample["time"]), count, frames))
            own[frames[0]] += count
            for frame in set(frames):
                inside[frame] += count
    os.makedirs(os.path.dirname(FOLDED), exist_ok=True)
    with open(FOLDED, "w") as out:
        out.writelines(f"{stack} {count}\n" for stack, count in folded.items())
    table("threads, running or waiting", threads, sum(threads.values()))
    total = threads[thread] or 1
    table(f"{thread}, in the method itself", own, total)
    table(f"{thread}, in the method and what it calls", inside, total)
    hitches(stacks, {frame for frame, count in inside.items() if count > 0.8 * total})
    print(f"\nflame graph: {FOLDED}")


if __name__ == "__main__":
    main(*sys.argv[1:])
