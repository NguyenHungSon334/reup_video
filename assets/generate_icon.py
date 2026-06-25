"""Generate assets/icon.ico — run once before building EXE."""
from PIL import Image, ImageDraw, ImageFont
import os

def make_icon():
    sizes = [256, 128, 64, 48, 32, 16]
    frames = []

    for size in sizes:
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)

        # Rounded background
        r = size // 6
        bg = "#1f6feb"
        draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=bg)

        # Letter "R"
        fs = int(size * 0.58)
        font = None
        for name in ("arialbd.ttf", "arial.ttf", "DejaVuSans-Bold.ttf"):
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

        frames.append(img)

    os.makedirs(os.path.dirname(__file__), exist_ok=True)
    out = os.path.join(os.path.dirname(__file__), "icon.ico")
    frames[0].save(out, format="ICO", sizes=[(s, s) for s in sizes],
                   append_images=frames[1:])
    print(f"Created {out}")

if __name__ == "__main__":
    make_icon()
