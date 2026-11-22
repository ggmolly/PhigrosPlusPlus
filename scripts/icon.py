"""usage: icon.py <size> < artwork > png, the ios app's home screen icon (scripts/patch_ipa.ts): the store's artwork
at that size with the ++ tab"""
import io
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from patch_apk import badge  # noqa: E402

size = int(sys.argv[1])
png = io.BytesIO()
Image.open(io.BytesIO(sys.stdin.buffer.read())).convert("RGB").resize((size, size), Image.LANCZOS).save(png, "PNG")
sys.stdout.buffer.write(badge(png.getvalue(), inset=0.06))
