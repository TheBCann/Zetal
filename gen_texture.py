width = 256
height = 256
maxval = 255

header = f"P6\n{width} {height}\n{maxval}\n".encode('ascii')

with open("test.ppm", "wb") as f:
    f.write(header)
    for y in range(height):
        for x in range(width):
            r = x % 256
            g = y % 256
            b = (x * y) % 256
            f.write(bytes([r, g, b]))
