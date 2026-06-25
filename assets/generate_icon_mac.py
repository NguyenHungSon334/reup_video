"""Generate assets/icon.icns for macOS — run on Mac before building."""
import os
import subprocess
import tempfile
from PIL import Image, ImageDraw, ImageFont


def make_png(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    r = size // 5
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill="#1f6feb")

    fs = int(size * 0.58)
    font = None
    for name in ("Arial Bold.ttf", "Arial.ttf", "Helvetica.ttc", "DejaVuSans-Bold.ttf"):
        try:
            font = ImageFont.truetype(name, fs)
            break
        except Exception:
            pass
    if font is None:
        font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), "R", font=font)
    tx = (size - (bbox[2] - bbox[0])) // 2 - bbox[0]
    ty = (size - (bbox[3] - bbox[1])) // 2 - bbox[1]
    draw.text((tx, ty), "R", fill="#ffffff", font=font)
    return img


def make_icns():
    # macOS iconset requires these exact sizes
    iconset_sizes = [16, 32, 64, 128, 256, 512, 1024]

    with tempfile.TemporaryDirectory() as tmp:
        iconset_dir = os.path.join(tmp, "icon.iconset")
        os.makedirs(iconset_dir)

        for size in iconset_sizes:
            img = make_png(size)
            img.save(os.path.join(iconset_dir, f"icon_{size}x{size}.png"))
            # @2x (retina) variant
            if size <= 512:
                img2 = make_png(size * 2)
                img2.save(os.path.join(iconset_dir, f"icon_{size}x{size}@2x.png"))

        out = os.path.join(os.path.dirname(__file__), "icon.icns")
        subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", out], check=True)
        print(f"Created {out}")


if __name__ == "__main__":
    make_icns()
