# MoveGrow website

The source of https://seesaw-earth.github.io/MoveGrow/, published by GitHub Pages from `docs/` on `main`.

- English pages are at the root: `index.html`, `privacy.html`, `support.html`. App Store Connect and the app link to `privacy.html` and `support.html`, so keep those addresses.
- Chinese (Simplified) is under `zh/`, Spanish under `es/`. Every page links to its translations (`hreflang`), and a small bar offers the reader's browser language once; there is no automatic redirect.
- No cookies, analytics, web fonts or third-party requests. A Content-Security-Policy allows only the site's own files.

## Files

| Path | What it is |
| --- | --- |
| `content.py` | Every word on the site, in English, Chinese and Spanish |
| `build.py` | Writes the HTML, `404.html`, `sitemap.xml` and `assets/motion.js` into `docs/` (standard library only) |
| `images.py` | Makes the icons (from the app icon) and the 1200×630 link previews (Pillow, Playwright) |
| `assets/` | `site.css`, `site.js` (language bar), `hero.js` (the animated skeleton) |
| `data/motion-kicking.json` | The motion the hero replays: a simulated baby from the MotorKit test fixtures, not a real recording |
| `tools/motion_main.swift` | How that JSON was made from the fixture |

## Edit and publish

```bash
# from the repository root
python3 website/build.py          # after changing content.py, assets or data
python3 website/images.py         # only when the headline, icon or hero change
python3 -m http.server -d docs 8000   # preview at http://localhost:8000/
```

Commit `website/` and `docs/` together and push to `main`. If the CSS or JavaScript changed, bump `STAMP` in `build.py` so browsers fetch the new files. When MoveGrow is on the App Store, add the badge where `index()` in `build.py` leaves a comment for it.

Keep `PRIVACY_POLICY.md` and the privacy text in `content.py` in step; the English version prevails.
