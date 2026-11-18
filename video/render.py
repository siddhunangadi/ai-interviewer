"""Export explainer.html to an MP4.

    pip install playwright imageio-ffmpeg
    playwright install chromium
    python video/render.py                 # -> video/ai-interviewer.mp4
    python video/render.py --stills 2 8 16 # -> PNG frames at those seconds, for a quick check
"""
import argparse
import subprocess
from pathlib import Path

import imageio_ffmpeg
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
PAGE = (HERE / "explainer.html").as_uri() + "?capture"
FPS = 30


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(HERE / "ai-interviewer.mp4"))
    ap.add_argument("--stills", nargs="*", type=float)
    args = ap.parse_args()

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1920, "height": 1080})
        page.goto(PAGE)
        page.wait_for_function("typeof window.render === 'function'")
        duration = page.evaluate("window.DURATION")

        if args.stills is not None:
            for s in args.stills:
                page.evaluate(f"render({s})")
                out = HERE / f"still-{s:05.1f}.png"
                page.screenshot(path=str(out))
                print(out)
            browser.close()
            return

        ffmpeg = subprocess.Popen(
            [imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-loglevel", "error",
             "-f", "image2pipe", "-framerate", str(FPS), "-i", "-",
             "-c:v", "libx264", "-preset", "slow", "-crf", "18",
             "-pix_fmt", "yuv420p", "-movflags", "+faststart", args.out],
            stdin=subprocess.PIPE,
        )
        frames = int(duration * FPS)
        for i in range(frames):
            page.evaluate(f"render({i / FPS})")
            ffmpeg.stdin.write(page.screenshot(type="png"))
            if i % FPS == 0:
                print(f"{i // FPS}s / {int(duration)}s", flush=True)
        ffmpeg.stdin.close()
        ffmpeg.wait()
        browser.close()
        print(args.out)


if __name__ == "__main__":
    main()
