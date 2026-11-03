#!/usr/bin/env python3
# MoveGrow website — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds the GitHub Pages site into docs/ from website/ (Python 3 standard library only):
#
#   python3 website/build.py            # from the repository root
#
# English pages live at the root (index.html, privacy.html, support.html: the App Store links to
# these), Chinese under zh/ and Spanish under es/. Images (icons, social cards) are made by
# website/images.py and kept in docs/assets; this script leaves them alone.

import html
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from content import LANGS, GITHUB, EMAIL  # noqa: E402

ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "docs")
BASE = "https://seesaw-earth.github.io/MoveGrow/"
ORDER = ["en", "zh", "es"]
PREFIX = {"en": "", "zh": "zh/", "es": "es/"}
HREFLANG = {"en": "en", "zh": "zh-Hans", "es": "es"}
PAGES = ["index.html", "privacy.html", "support.html"]
STAMP = "20261103"   # cache-busting query for CSS/JS; change when the assets change


def esc(s):
    return html.escape(s, quote=True)


def fill(s, lang, rel):
    return s.format(github=GITHUB, email=EMAIL, privacy=rel + "privacy.html")


def url(lang, page):
    return BASE + PREFIX[lang] + ("" if page == "index.html" else page)


def href(from_lang, to_lang, page):
    """A relative link from a page in from_lang to the same page in to_lang."""
    up = "" if from_lang == "en" else "../"
    target = PREFIX[to_lang] + ("" if page == "index.html" else page)
    return (up + target) or "./"


def head(t, lang, page, title, desc):
    rel = "" if lang == "en" else "../"
    alt = "\n".join(
        f'  <link rel="alternate" hreflang="{HREFLANG[l]}" href="{url(l, page)}">' for l in ORDER
    )
    og_alt = "\n".join(
        f'  <meta property="og:locale:alternate" content="{LANGS[l]["og_locale"]}">' for l in ORDER if l != lang
    )
    image = f"{BASE}assets/og-{lang}.png"
    return f"""<!doctype html>
<html lang="{t['html_lang']}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
  <meta name="referrer" content="strict-origin-when-cross-origin">
  <title>{esc(title)}</title>
  <meta name="description" content="{esc(desc)}">
  <link rel="canonical" href="{url(lang, page)}">
{alt}
  <link rel="alternate" hreflang="x-default" href="{url('en', page)}">
  <meta name="theme-color" content="#F6F8F2" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#111A10" media="(prefers-color-scheme: dark)">
  <meta name="color-scheme" content="light dark">
  <link rel="icon" type="image/png" sizes="32x32" href="{rel}assets/icon-32.png">
  <link rel="apple-touch-icon" href="{rel}assets/icon-180.png">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="MoveGrow">
  <meta property="og:title" content="{esc(title)}">
  <meta property="og:description" content="{esc(desc)}">
  <meta property="og:url" content="{url(lang, page)}">
  <meta property="og:image" content="{image}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:image:alt" content="{esc(t['og_alt'])}">
  <meta property="og:locale" content="{t['og_locale']}">
{og_alt}
  <meta name="twitter:card" content="summary_large_image">
  <link rel="stylesheet" href="{rel}assets/site.css?v={STAMP}">
</head>
"""


def header(t, lang, page):
    rel = "" if lang == "en" else "../"
    home = "./"
    how = "#how" if page == "index.html" else home + "#how"
    hints = []
    for l in ORDER:
        if l == lang:
            continue
        o = LANGS[l]
        hints.append(
            f'<span data-offer="{l}" lang="{o["html_lang"]}" hidden>{esc(o["hint_offer"])} '
            f'<a href="{href(lang, l, page)}" hreflang="{HREFLANG[l]}">{esc(o["hint_link"])}</a>'
            f'<button type="button">{esc(o["hint_close"])}</button></span>'
        )
    langs = "".join(
        f'<a href="{href(lang, l, page)}" hreflang="{HREFLANG[l]}" lang="{LANGS[l]["html_lang"]}"'
        + (' aria-current="true"' if l == lang else "")
        + f'>{esc(LANGS[l]["name"])}</a>'
        for l in ORDER
    )
    cur = lambda p: ' aria-current="page"' if p == page else ""
    return f"""<body>
<a class="skip" href="#main">{esc(t['skip'])}</a>
<div class="lang-hint" id="lang-hint" hidden><div class="wrap">{''.join(hints)}</div></div>
<header class="site-header">
  <div class="wrap">
    <a class="brand" href="{home}"><img src="{rel}assets/icon-180.png" alt="" width="36" height="36">MoveGrow</a>
    <nav class="site-nav" aria-label="MoveGrow">
      <a class="section-link" href="{how}">{esc(t['nav_how'])}</a>
      <a class="section-link" href="privacy.html"{cur('privacy.html')}>{esc(t['nav_privacy'])}</a>
      <a class="section-link" href="support.html"{cur('support.html')}>{esc(t['nav_support'])}</a>
      <a class="section-link" href="{GITHUB}">{esc(t['nav_source'])}</a>
      <span class="langs" role="group" aria-label="{esc(t['langs_label'])}">{langs}</span>
    </nav>
  </div>
</header>
"""


def footer(t, lang, page):
    rel = "" if lang == "en" else "../"
    return f"""<footer class="site-footer">
  <div class="wrap">
    <nav aria-label="MoveGrow">
      <a href="privacy.html">{esc(t['foot_privacy'])}</a>
      <a href="support.html">{esc(t['foot_support'])}</a>
      <a href="{GITHUB}">{esc(t['foot_source'])}</a>
      <a href="{GITHUB}/blob/main/LICENSE">{esc(t['foot_license'])}</a>
    </nav>
    <p class="legal">© 2026 Ziqing Shi. {esc(t['foot_note'])}</p>
  </div>
</footer>
<script src="{rel}assets/site.js?v={STAMP}"></script>
"""


def index(t, lang):
    rel = "" if lang == "en" else "../"
    page = "index.html"
    steps = "\n".join(
        f"        <li><h3>{esc(h)}</h3><p>{esc(p)}</p></li>" for h, p in t["steps"]
    )
    feats = "\n".join(
        f"        <div><h3>{esc(h)}</h3><p>{esc(p)}</p></div>" for h, p in t["features"]
    )
    facts = "\n".join(
        f"        <li><strong>{esc(h)}</strong>{esc(p)}</li>" for h, p in t["facts"]
    )
    faq = "\n".join(
        f"      <details><summary>{esc(q)}</summary><p>{esc(a)}</p></details>" for q, a in t["faq"]
    )
    pills = "".join(
        f'<span class="pill" data-limb="{k}">{esc(t[n])}</span>'
        for k, n in (("L_arm", "pill_la"), ("R_arm", "pill_ra"), ("L_leg", "pill_ll"), ("R_leg", "pill_rl"))
    )
    body = f"""<main id="main">
  <section class="hero">
    <div class="wrap">
      <div class="hero-copy">
        <h1>{t['h1']}</h1>
        <p class="lead">{esc(t['lead'])}</p>
        <div class="actions">
          <!-- When MoveGrow is on the App Store, put the Download on the App Store badge first here. -->
          <a class="button primary" href="#how">{esc(t['cta_how'])}</a>
          <a class="button" href="{GITHUB}">{esc(t['cta_source'])}</a>
        </div>
        <p class="small">{esc(t['hero_note'])}</p>
      </div>
      <figure class="specimen">
        <div class="panel">
          <div class="readout" aria-hidden="true"><span class="time" id="hero-time">0:10</span><span class="pills">{pills}</span></div>
          <canvas id="hero-canvas" role="img" aria-label="{esc(t['fig_label'])}" data-arms="{esc(t['row_arms'])}" data-legs="{esc(t['row_legs'])}"></canvas>
        </div>
        <figcaption>{esc(t['fig_caption'])}</figcaption>
      </figure>
    </div>
  </section>

  <section id="how" class="how">
    <div class="wrap">
      <div class="section-head">
        <h2>{esc(t['how_h2'])}</h2>
        <p class="lead">{esc(t['how_intro'])}</p>
      </div>
      <ol class="steps">
{steps}
      </ol>
    </div>
  </section>

  <section class="tint">
    <div class="wrap">
      <div class="section-head"><h2>{esc(t['feat_h2'])}</h2></div>
      <div class="features">
{feats}
      </div>
    </div>
  </section>

  <section class="night" id="privacy">
    <div class="wrap">
      <div class="section-head"><h2>{esc(t['priv_h2'])}</h2></div>
      <ul class="facts">
{facts}
      </ul>
      <p class="more"><a href="privacy.html">{esc(t['priv_link'])}</a></p>
    </div>
  </section>

  <section>
    <div class="wrap split">
      <h2>{esc(t['health_h2'])}</h2>
      <div>
        <p>{esc(t['health_p1'])}</p>
        <p>{esc(t['health_p2'])}</p>
        <div class="callout"><p>{esc(t['health_call'])}</p></div>
      </div>
    </div>
  </section>

  <section class="tint">
    <div class="wrap split">
      <h2>{esc(t['oss_h2'])}</h2>
      <div>
        <p>{esc(t['oss_p'])}</p>
        <p class="actions"><a class="button" href="{GITHUB}">{esc(t['oss_button'])}</a></p>
      </div>
    </div>
  </section>

  <section class="faq">
    <div class="wrap">
      <h2>{esc(t['faq_h2'])}</h2>
{faq}
    </div>
  </section>
</main>
"""
    return (
        head(t, lang, page, t["home_title"], t["home_desc"])
        + header(t, lang, page)
        + body
        + footer(t, lang, page)
        + f'<script src="{rel}assets/motion.js?v={STAMP}"></script>\n'
        + f'<script src="{rel}assets/hero.js?v={STAMP}"></script>\n'
        + "</body>\n</html>\n"
    )


def privacy(t, lang):
    rel = "" if lang == "en" else "../"
    page = "privacy.html"
    parts = []
    for h, ps in t["pp_sections"]:
        parts.append(f"      <h2>{esc(h)}</h2>")
        parts += [f"      <p>{fill(p, lang, rel)}</p>" for p in ps]
    note = (
        f'      <p class="note">{fill(t["pp_translation"], lang, "../")}</p>\n' if t["pp_translation"] else ""
    )
    body = f"""<main id="main" class="doc">
  <div class="wrap">
    <article>
      <h1>{esc(t['pp_h1'])}</h1>
      <p class="note">{esc(t['pp_updated'])}</p>
{note}      <p class="lead">{esc(t['pp_intro'])}</p>
{chr(10).join(parts)}
    </article>
  </div>
</main>
"""
    return (
        head(t, lang, page, t["pp_title"], t["pp_desc"]) + header(t, lang, page) + body
        + footer(t, lang, page) + "</body>\n</html>\n"
    )


def support(t, lang):
    rel = "" if lang == "en" else "../"
    page = "support.html"
    report = "\n".join(f"        <li>{esc(x)}</li>" for x in t["sp_report"])
    common = "\n".join(f"      <h3>{esc(q)}</h3>\n      <p>{esc(a)}</p>" for q, a in t["sp_common"])
    body = f"""<main id="main" class="doc">
  <div class="wrap">
    <article>
      <h1>{esc(t['sp_h1'])}</h1>
      <p class="lead">{fill(t['sp_intro'], lang, rel)}</p>
      <div class="callout"><p>{esc(t['sp_warning'])}</p></div>
      <h2>{esc(t['sp_report_h2'])}</h2>
      <ul>
{report}
      </ul>
      <h2>{esc(t['sp_common_h2'])}</h2>
{common}
      <h2>{esc(t['sp_medical_h2'])}</h2>
      <p>{esc(t['sp_medical'])}</p>
    </article>
  </div>
</main>
"""
    return (
        head(t, lang, page, t["sp_title"], t["sp_desc"]) + header(t, lang, page) + body
        + footer(t, lang, page) + "</body>\n</html>\n"
    )


def not_found():
    """Served by GitHub Pages for any missing path, at any depth, so it uses absolute URLs."""
    blocks = []
    for l in ORDER:
        t = LANGS[l]
        home = "/MoveGrow/" + PREFIX[l]
        blocks.append(
            f'    <section lang="{t["html_lang"]}"><h1>{esc(t["nf_h1"])}</h1>'
            f'<p>{esc(t["nf_p"])}</p><p><a href="{home}">{esc(t["nf_home"])}</a></p></section>'
        )
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex">
  <title>{esc(LANGS['en']['nf_title'])}</title>
  <link rel="icon" type="image/png" sizes="32x32" href="/MoveGrow/assets/icon-32.png">
  <link rel="stylesheet" href="/MoveGrow/assets/site.css?v={STAMP}">
</head>
<body>
<header class="site-header"><div class="wrap"><a class="brand" href="/MoveGrow/"><img src="/MoveGrow/assets/icon-180.png" alt="" width="36" height="36">MoveGrow</a></div></header>
<main class="doc notfound">
  <div class="wrap">
{chr(10).join(blocks)}
  </div>
</main>
</body>
</html>
"""


def sitemap():
    rows = []
    for page in PAGES:
        for l in ORDER:
            alts = "".join(
                f'<xhtml:link rel="alternate" hreflang="{HREFLANG[a]}" href="{url(a, page)}"/>' for a in ORDER
            )
            rows.append(f"  <url><loc>{url(l, page)}</loc><lastmod>2026-11-03</lastmod>{alts}</url>")
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
        + "\n".join(rows)
        + "\n</urlset>\n"
    )


def motion_js():
    with open(os.path.join(HERE, "data", "motion-kicking.json"), encoding="utf-8") as f:
        d = json.load(f)
    keep = {
        "fps": d["fps"], "start": 10, "scale": round(d["scale"], 3),
        "frames": [[round(v, 3) for v in fr] for fr in d["frames"]],
        "speed": {k: [round(v, 3) for v in vs] for k, vs in d["speed"].items()},
        "active": d["active"],
    }
    return (
        "/* Simulated baby from MoveGrow's test data (fixture rhythmic_kicking_bilateral, 10–20 s);\n"
        "   generated by website/build.py from website/data/motion-kicking.json. */\n"
        "window.MG_MOTION = " + json.dumps(keep, separators=(",", ":")) + ";\n"
    )


def write(rel, text):
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def main():
    for l in ORDER:
        t = LANGS[l]
        write(PREFIX[l] + "index.html", index(t, l))
        write(PREFIX[l] + "privacy.html", privacy(t, l))
        write(PREFIX[l] + "support.html", support(t, l))
    write("404.html", not_found())
    write("sitemap.xml", sitemap())
    write(".nojekyll", "")
    write("assets/motion.js", motion_js())
    for name in ("site.css", "site.js", "hero.js"):
        shutil.copyfile(os.path.join(HERE, "assets", name), os.path.join(OUT, "assets", name))
    print("Built", OUT)


if __name__ == "__main__":
    main()
