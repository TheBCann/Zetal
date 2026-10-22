# Writes assets/test.ppm: the 256x256 binary PPM (P6) the cubes and the ground are textured with.
# Red ramps with x, green with y, blue is (x * y) mod 256. The output is byte-for-byte the shipped
# asset, so rerunning this is safe. Run it from anywhere: the path is resolved from this file.
from pathlib import Path

width = 256
height = 256
maxval = 255

out_path = Path(__file__).resolve().parent.parent / "assets" / "test.ppm"
header = f"P6\n{width} {height}\n{maxval}\n".encode('ascii')

with open(out_path, "wb") as f:
    f.write(header)
    for y in range(height):
        for x in range(width):
            r = x % 256
            g = y % 256
            b = (x * y) % 256
            f.write(bytes([r, g, b]))
