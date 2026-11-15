"""lldb side of phigros++ on ios 26 and later, where code the app writes only runs in pages a debugger wrote in.
command script import scripts/jit.py, then target stop-hook add -P jit.Serve -I false: the library stops on
"brk #0xf00d" with x0 = a table of {page, its first 8 bytes} and x1 = its length, this writes the bytes back as they
are and lets the app go on. the other stops (crashes) stay stopped"""
import struct

import lldb

BRK = 0xD43E01A0  # brk #0xf00d


class Serve:
    def __init__(self, target, extra_args, internal):
        pass

    def handle_stop(self, exe_ctx, stream):
        process = exe_ctx.GetProcess()
        error = lldb.SBError()
        for thread in process:
            frame = thread.GetFrameAtIndex(0)
            pc = frame.FindRegister("pc").GetValueAsUnsigned()  # frame.GetPC() can be the last stop's
            if thread.GetStopReason() == lldb.eStopReasonNone or process.ReadUnsignedFromMemory(pc, 4, error) != BRK:
                continue
            table, count = (frame.FindRegister(r).GetValueAsUnsigned() for r in ("x0", "x1"))
            data = process.ReadMemory(table, 16 * count, error)
            for page, bytes_ in struct.iter_unpack("<Q8s", data or b""):
                if process.WriteMemory(page, bytes_, error) != 8:
                    stream.Print("jit: couldn't write at %x: %s\n" % (page, error))
                    return True
            frame.SetPC(pc + 4)
            return False
        return True
