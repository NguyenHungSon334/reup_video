"""Generate assets/icon.icns for macOS from assets/Logo.png — run on Mac before building."""
import os
import subprocess
import tempfile
from PIL import Image

SRC = os.path.join(os.path.dirname(__file__), "Logo.png")


def make_png(size: int) -> Image.Image:
    src = Image.open(SRC).convert("RGBA")
    return src.resize((size, size), Image.LANCZOS)


def make_icns():
    # macOS iconset requires these exact sizes (plus @2x retina variants)
    iconset_sizes = [16, 32, 64, 128, 256, 512, 1024]

    with tempfile.TemporaryDirectory() as tmp:
        iconset_dir = os.path.join(tmp, "icon.iconset")
        os.makedirs(iconset_dir)

        for size in iconset_sizes:
            make_png(size).save(os.path.join(iconset_dir, f"icon_{size}x{size}.png"))
            if size <= 512:  # @2x (retina) variant
                make_png(size * 2).save(
                    os.path.join(iconset_dir, f"icon_{size}x{size}@2x.png"))

        out = os.path.join(os.path.dirname(__file__), "icon.icns")
        subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", out], check=True)
        print(f"Created {out}")


if __name__ == "__main__":
    make_icns()
