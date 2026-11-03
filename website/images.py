#!/usr/bin/env python3
# MoveGrow website — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
#
# Makes the site's images in docs/assets after website/build.py has run:
#   icon-32.png, icon-180.png, icon-512.png   from the app icon (Pillow)
#   og-en.png, og-zh.png, og-es.png           1200×630 link previews (Playwright + Chromium)
#
#   python3 website/images.py               # from the repository root

import html
import os
import sys
import tempfile

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from content import LANGS  # noqa: E402

ROOT = os.path.dirname(HERE)
ASSETS = os.path.join(ROOT, "docs", "assets")
ICON = os.path.join(ROOT, "MoveGrow", "Assets.xcassets", "AppIcon.appiconset", "MoveGrow-AppIcon-1024.png")


def icons():
    src = Image.open(ICON).convert("RGB")
    for size in (32, 180, 512):
        src.resize((size, size), Image.LANCZOS).save(os.path.join(ASSETS, f"icon-{size}.png"), optimize=True)


CARD = """<!doctype html>
<html lang="{lang}"><head><meta charset="utf-8">
<link rel="stylesheet" href="{assets}/site.css">
<style>
  /* Rendered on Linux: stand-ins close to the Apple faces the site uses (Palatino-like serif, Inter). */
  :root {{ --serif: "TeX Gyre Pagella", "Palatino Linotype", Palatino, serif; --sans: Inter, "Helvetica Neue", Arial, sans-serif; }}
  :lang(zh) {{ --serif: "Noto Serif CJK SC", serif; --sans: "Noto Sans CJK SC", sans-serif; }}
  html, body {{ width: 1200px; height: 630px; overflow: hidden; }}
  body {{ display: grid; grid-template-columns: 1fr 430px; gap: 64px; align-items: center; padding: 0 72px 0 84px; }}
  .brand {{ font-size: 34px; gap: 18px; margin-bottom: 44px; }}
  .brand img {{ width: 72px; height: 72px; border-radius: 17px; }}
  h1 {{ font-size: {h1}px; margin: 0 0 26px; }}
  p {{ font-size: 28px; line-height: 1.4; color: var(--ink-2); margin: 0; text-wrap: balance; }}
  .panel {{ height: 560px; width: 430px; aspect-ratio: auto; max-width: none; margin: 0; border-radius: 30px; }}
</style></head>
<body>
  <div><div class="brand"><img src="{assets}/icon-512.png" alt="">MoveGrow</div><h1>{title}</h1><p>{line}</p></div>
  <div class="panel">
    <div class="readout"><span class="time" id="hero-time"></span>{pills}</div>
    <canvas id="hero-canvas" data-arms="{arms}" data-legs="{legs}"></canvas>
  </div>
  <script src="{assets}/motion.js"></script>
  <script src="{assets}/hero.js"></script>
</body></html>
"""


def cards():
    with tempfile.TemporaryDirectory() as tmp, sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1200, "height": 630}, device_scale_factor=1,
                                reduced_motion="reduce", color_scheme="light")
        for code, t in LANGS.items():
            pills = "".join(
                f'<span class="pill" data-limb="{k}">{html.escape(t[n])}</span>'
                for k, n in (("L_arm", "pill_la"), ("R_arm", "pill_ra"), ("L_leg", "pill_ll"), ("R_leg", "pill_rl"))
            )
            doc = CARD.format(
                lang=t["html_lang"], assets="file://" + ASSETS, title=t["h1"], line=html.escape(t["og_line"]),
                pills=pills, arms=html.escape(t["row_arms"]), legs=html.escape(t["row_legs"]),
                h1={"zh": 68, "es": 56}.get(code, 64),
            )
            path = os.path.join(tmp, f"og-{code}.html")
            with open(path, "w", encoding="utf-8") as f:
                f.write(doc)
            page.goto("file://" + path)
            page.wait_for_timeout(300)
            out = os.path.join(ASSETS, f"og-{code}.png")
            page.screenshot(path=out)
            Image.open(out).convert("RGB").save(out, optimize=True)
        browser.close()


if __name__ == "__main__":
    icons()
    cards()
    print("Images in", ASSETS)
