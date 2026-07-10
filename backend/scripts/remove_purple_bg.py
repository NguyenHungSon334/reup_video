"""Chroma-key a purple background out of a banner video, export ProRes 4444 .mov with alpha.

Usage:
    python remove_purple_bg.py <input.mp4> [output.mov] [--color 0xCA00FF] [--similarity 0.12] [--blend 0.08]
"""
import argparse
import subprocess
import sys

FFMPEG = "ffmpeg"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output", nargs="?", default=None)
    ap.add_argument("--color", default="0xCA00FF", help="background color to key out (hex)")
    ap.add_argument("--similarity", type=float, default=0.12, help="colorkey/chromakey similarity threshold")
    ap.add_argument("--blend", type=float, default=0.08, help="colorkey/chromakey edge blend")
    ap.add_argument("--mode", choices=["colorkey", "chromakey"], default="colorkey")
    ap.add_argument("--color2", default=None, help="second color to key out (chains a 2nd colorkey pass, hex)")
    args = ap.parse_args()

    out = args.output or (args.input.rsplit(".", 1)[0] + "_alpha.mov")

    key_fn = "chromakey" if args.mode == "chromakey" else "colorkey"
    vf = f"{key_fn}={args.color}:{args.similarity}:{args.blend}"
    if args.color2:
        vf += f",{key_fn}={args.color2}:{args.similarity}:{args.blend}"
    vf += ",format=yuva444p10le"
    cmd = [
        FFMPEG, "-y", "-i", args.input,
        "-vf", vf,
        "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le",
        "-c:a", "copy",
        out,
    ]
    print("Running:", " ".join(cmd))
    r = subprocess.run(cmd)
    if r.returncode != 0:
        sys.exit(r.returncode)
    print("Done ->", out)


if __name__ == "__main__":
    main()
