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
PAGES = ["index.html", "tech.html", "privacy.html", "support.html"]
STAMP = "20261112"   # cache-busting query for CSS/JS; change when the assets change
UPDATED = "2026-11-12"   # <lastmod> in sitemap.xml

# Files in the repository that the Technology page links to.
RULES = GITHUB + "/blob/main/MoveGrow/Motor/Resources/rules.json"
SOURCES = GITHUB + "/blob/main/MoveGrow/Motor/Resources/sources.json"
NOTES = GITHUB + "/blob/main/INSTANTHMR.md"
PROVENANCE = GITHUB + "/blob/main/MODEL_PROVENANCE.md"

# The Technology page's references, in the order of their numbers ({r1} … in content.py). Citations
# stay in English on every page.
REFS = [
    ("Adjel M, Chalabi K, Bonnet V. InstantHMR: Real-Time Human Mesh Recovery on Your Phone. HAL preprint hal-05854387, 2026.",
     "https://hal.science/hal-05854387"),
    ("Ferguson A, Osman AAA, Bescos B, et al. MHR: Momentum Human Rig. arXiv:2511.15586, 2025.",
     "https://arxiv.org/abs/2511.15586"),
    ("Yang X, Kukreja D, Pinkus D, et al. SAM 3D Body: Robust Full-Body Human Mesh Recovery. arXiv:2602.15989, 2026.",
     "https://arxiv.org/abs/2602.15989"),
    ("Ultralytics. YOLO26: model documentation.",
     "https://docs.ultralytics.com/models/yolo26/"),
    ("Jahn L, et al. Comparison of marker-less 2D image-based methods for infant pose estimation. Scientific Reports 2025;15:12148.",
     "https://doi.org/10.1038/s41598-025-96206-0"),
    ("Sotoodeh MS, Ossmy O, Donati G, et al. Automatic pose estimation in newborn infants: lessons from the Baby Grow study. Behavior Research Methods 2026;58:82.",
     "https://doi.org/10.3758/s13428-026-02943-z"),
    ("Dardaman C, Xu Z, Stone P, Adolph K, Han D, Pavlakos G. Baby Mesh Recovery Enables Infant Behavior Identification. IEEE International Conference on Development and Learning (ICDL), 2026.",
     "https://geopavlakos.github.io/babymesh/"),
    ("Chatzichristodoulou G, Efthymiou N, Filntisis P, Pavlakos G, Maragos P. Age-Inclusive 3D Human Mesh Recovery for Action-Preserving Data Anonymization. arXiv:2512.05259, 2025.",
     "https://arxiv.org/abs/2512.05259"),
    ("Huntsman RJ, Lowry NJ, Sankaran K. Nonepileptic motor phenomena in the neonate. Paediatrics & Child Health 2008;13(8):680–684.",
     "https://pmc.ncbi.nlm.nih.gov/articles/PMC2606074/"),
    ("Thelen E. Rhythmical stereotypies in normal human infants. Animal Behaviour 1979;27:699–715.",
     None),
    ("Smith BA, et al. Daily quantity of infant leg movement. Sensors 2015;15:19006.",
     "https://pmc.ncbi.nlm.nih.gov/articles/PMC4570357"),
    ("Einspieler C, Peharz R, Marschik PB. Fidgety movements – tiny in appearance, but huge in impact. Jornal de Pediatria 2016;92(3 Suppl 1):S64–S70.",
     "https://www.jped.com.br/en-fidgety-movements-tiny-in-articulo-S0021755716000516"),
]

BIBTEX = """@software{shi2026movegrow,
  author  = {Shi, Ziqing},
  title   = {{MoveGrow}: an on-device journal of infant movement},
  year    = {2026},
  url     = {%s},
  license = {AGPL-3.0-only}
}""" % GITHUB


def esc(s):
    return html.escape(s, quote=True)


def fill(s, lang, rel):
    return s.format(github=GITHUB, email=EMAIL, privacy=rel + "privacy.html")


def fill_tech(s):
    """Technology-page strings: repository links and the numbered references."""
    cites = {f"r{i + 1}": f'<a class="cite" href="#ref-{i + 1}">[{i + 1}]</a>' for i in range(len(REFS))}
    return s.format(github=GITHUB, email=EMAIL, rules=RULES, sources=SOURCES, notes=NOTES, provenance=PROVENANCE, **cites)


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
      <a class="section-link" href="tech.html"{cur('tech.html')}>{esc(t['nav_tech'])}</a>
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
      <a href="tech.html">{esc(t['foot_tech'])}</a>
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
        <p class="actions"><a class="button" href="tech.html">{esc(t['oss_tech'])}</a><a class="button" href="{GITHUB}">{esc(t['oss_button'])}</a></p>
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


# The body frame: a baby on the back seen from above, the axes u, v, w and the torso-length ruler.
# A drawing (not data). Its only text is the letters u, v, w and the figure 1, so it needs no
# translation; colours and type come from site.css.
BODY_FRAME_SVG = """<svg viewBox="0 0 360 450" role="img" aria-label="{label}">
            <circle class="bf-head" cx="180" cy="92" r="36"/>
            <circle class="bf-eye" cx="167" cy="88" r="3.5"/><circle class="bf-eye" cx="193" cy="88" r="3.5"/>
            <path class="bf-bone" d="M180 128V258M136 152H224M154 258H206M136 152L96 122L112 76M224 152L270 178L292 226M154 258L112 312L146 366M206 258L252 304L228 362"/>
            <g class="bf-joint"><circle cx="136" cy="152" r="5"/><circle cx="224" cy="152" r="5"/><circle cx="96" cy="122" r="5"/><circle cx="270" cy="178" r="5"/><circle cx="154" cy="258" r="5"/><circle cx="206" cy="258" r="5"/><circle cx="112" cy="312" r="5"/><circle cx="252" cy="304" r="5"/><circle cx="112" cy="76" r="7.5"/><circle cx="292" cy="226" r="7.5"/><circle cx="146" cy="366" r="7.5"/><circle cx="228" cy="362" r="7.5"/></g>
            <path class="bf-rule" d="M104 152V258M94 152H114M94 258H114"/>
            <text class="bf-label bf-one" x="80" y="213" text-anchor="middle">1</text>
            <path class="bf-axis" d="M180 205V166M180 205H240"/>
            <path class="bf-tip" d="M180 150L171 168H189ZM256 205L238 196V214Z"/>
            <circle class="bf-axis bf-w" cx="180" cy="205" r="11"/><circle class="bf-tip" cx="180" cy="205" r="4"/>
            <text class="bf-label" x="196" y="182">v</text>
            <text class="bf-label" x="246" y="232">u</text>
            <text class="bf-label" x="150" y="234">w</text>
          </svg>"""


def table(head, rows, stack=True, label_all=False):
    """A data table. Row headers are in the first column; on narrow screens each row becomes a block
    and cells are labelled with their column heading (data-label): every cell with label_all, else
    every cell after the first."""
    ths = "".join(f'<th scope="col">{h}</th>' for h in head)
    body = []
    for row in rows:
        cells = f'<th scope="row">{fill_tech(row[0])}</th>' + "".join(
            f'<td data-label="{esc(head[i + 1])}">{fill_tech(c)}</td>' for i, c in enumerate(row[1:])
        )
        body.append(f"            <tr>{cells}</tr>")
    cls = ("data stack all" if label_all else "data stack") if stack else "data"
    return (
        f'<div class="table-wrap"><table class="{cls}">\n'
        f"          <thead><tr>{ths}</tr></thead>\n          <tbody>\n" + "\n".join(body) + "\n          </tbody>\n        </table></div>"
    )


def tech(t, lang):
    """The Technology page: laid out like a research project page (summary and links, figure, method,
    measures, limits, licences, citation, references), in the site's own style."""
    rel = "" if lang == "en" else "../"
    page = "tech.html"
    links = "".join(
        f'<a class="button{" primary" if i == 0 else ""}" href="{fill_tech(u)}">{esc(label)}</a>'
        for i, (label, u) in enumerate(t["tk_links"])
    )
    paras = lambda ps: "\n".join(f"        <p>{fill_tech(p)}</p>" for p in ps)
    stages = "\n".join(f"        <li><h3>{esc(h)}</h3><p>{fill_tech(p)}</p></li>" for h, p in t["tk_pipe"])
    notes = "\n".join(f"        <li>{fill_tech(p)}</li>" for p in t["tk_pipe_notes"])
    limits = "\n".join(f"        <li><strong>{esc(h)}</strong>{fill_tech(p)}</li>" for h, p in t["tk_limits"])
    refs = "\n".join(
        f'        <li id="ref-{i + 1}">{esc(text)}'
        + (f' <a href="{u}">{esc(u.split("//", 1)[1].rstrip("/"))}</a>' if u else "")
        + "</li>"
        for i, (text, u) in enumerate(REFS)
    )
    body = f"""<main id="main" class="tech">
  <section class="hero">
    <div class="wrap">
      <div class="hero-copy">
        <h1>{t['tk_h1']}</h1>
        <p class="lead">{esc(t['tk_lead'])}</p>
        <div class="actions">{links}</div>
        <p class="small byline">{esc(t['tk_byline'])}<br>{esc(t['tk_updated'])}</p>
      </div>
      <figure class="specimen">
        <div class="panel frame-panel">
          {BODY_FRAME_SVG.format(label=esc(t['tk_fig_label']))}
        </div>
        <figcaption>{t['tk_fig_caption']}</figcaption>
      </figure>
    </div>
  </section>

  <section class="tint">
    <div class="wrap split">
      <h2>{esc(t['tk_over_h2'])}</h2>
      <div>
{paras(t['tk_over'])}
      </div>
    </div>
  </section>

  <section id="pipeline">
    <div class="wrap pipeline">
      <div class="pipeline-head">
        <h2>{esc(t['tk_pipe_h2'])}</h2>
        <p class="lead">{esc(t['tk_pipe_intro'])}</p>
      </div>
      <ol class="stages">
{stages}
      </ol>
      <ul class="notes">
{notes}
      </ul>
    </div>
  </section>

  <section class="tint" id="measures">
    <div class="wrap">
      <div class="section-head">
        <h2>{esc(t['tk_meas_h2'])}</h2>
        <p class="lead">{esc(t['tk_meas_intro'])}</p>
      </div>
      {table(t['tk_meas_head'], t['tk_meas'])}
    </div>
  </section>

  <section id="engines">
    <div class="wrap">
      <div class="section-head">
        <h2>{esc(t['tk_eng_h2'])}</h2>
        <p class="lead">{esc(t['tk_eng_intro'])}</p>
      </div>
      {table(t['tk_eng_head'], t['tk_eng'], label_all=True)}
    </div>
  </section>

  <section class="night" id="accuracy">
    <div class="wrap">
      <div class="section-head">
        <h2>{esc(t['tk_acc_h2'])}</h2>
        <p>{fill_tech(t['tk_acc_p'])}</p>
      </div>
      {table(t['tk_acc_head'], t['tk_acc_rows'], stack=False)}
      <p class="after">{esc(t['tk_acc_after'])}</p>
      <ul class="facts">
{limits}
      </ul>
      <p class="more">{esc(t['tk_checks'])}</p>
    </div>
  </section>

  <section id="observations">
    <div class="wrap">
      <div class="section-head">
        <h2>{esc(t['tk_obs_h2'])}</h2>
{paras(t['tk_obs_p'])}
      </div>
      {table(t['tk_obs_head'], t['tk_obs'])}
      <div class="after">
{paras(t['tk_obs_after'])}
      </div>
    </div>
  </section>

  <section class="tint" id="licences">
    <div class="wrap">
      <div class="section-head">
        <h2>{esc(t['tk_lic_h2'])}</h2>
        <p class="lead">{esc(t['tk_lic_intro'])}</p>
      </div>
      {table(t['tk_lic_head'], t['tk_lic'])}
      <p class="after">{fill_tech(t['tk_lic_after'])}</p>
    </div>
  </section>

  <section id="cite">
    <div class="wrap split">
      <h2>{esc(t['tk_cite_h2'])}</h2>
      <div>
        <p>{fill_tech(t['tk_cite_p'])}</p>
        <div class="bibtex">
          <div class="bibtex-bar"><span>BibTeX</span><button type="button" data-copy="bibtex" data-done="{esc(t['tk_copied'])}">{esc(t['tk_copy'])}</button></div>
          <pre id="bibtex" lang="en" tabindex="0">{esc(BIBTEX)}</pre>
        </div>
      </div>
    </div>
  </section>

  <section class="tint" id="references">
    <div class="wrap">
      <h2>{esc(t['tk_refs_h2'])}</h2>
      <ol class="reflist" lang="en">
{refs}
      </ol>
    </div>
  </section>
</main>
"""
    return (
        head(t, lang, page, t["tk_title"], t["tk_desc"]) + header(t, lang, page) + body
        + footer(t, lang, page) + "</body>\n</html>\n"
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
            rows.append(f"  <url><loc>{url(l, page)}</loc><lastmod>{UPDATED}</lastmod>{alts}</url>")
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
        write(PREFIX[l] + "tech.html", tech(t, l))
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
