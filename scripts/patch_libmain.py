"""usage: patch_libmain.py <libmain.so> <output>, makes the game's libmain.so load libphigrospp.so"""
import sys

import lief

src, dst = sys.argv[1], sys.argv[2]
elf = lief.parse(src)
if "libphigrospp.so" not in elf.libraries:
    elf.add_library("libphigrospp.so")
elf.write(dst)
