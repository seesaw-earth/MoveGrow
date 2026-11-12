#!/usr/bin/env python3
# MoveGrow — Copyright (C) 2026 Ziqing Shi
# SPDX-License-Identifier: AGPL-3.0-only
"""Localization checks (English, Simplified Chinese, Spanish).

1. Every key passed to tr("…") in the app is in MoveGrow/Localizable.xcstrings, translated into
   zh-Hans and es (state "translated", not empty).
2. Each translation has the same placeholders as its key (%@, %lld …, numbered or not; numbered
   ones may be reordered) — a wrong placeholder would crash or garble the text.
3. No visible text is left as a bare literal in SwiftUI (Text("…"), Button("…"), Label("…"),
   navigationTitle("…") …): those would stay English. Brand names use Text(verbatim:).
4. rules.json carries zh, en and es for every rule text, with matching {placeholders}.
5. The English entries equal their keys, and InfoPlist.xcstrings covers the permission prompts.
"""
from pathlib import Path
import json, re, sys

root = Path(__file__).resolve().parents[1]
app = root / 'MoveGrow'
langs = ['zh-Hans', 'es']
errors: list[str] = []

def swift_files():
    return sorted(p for p in app.rglob('*.swift'))

STR = r'"((?:[^"\\]|\\.)*)"'
tr_re = re.compile(r'\btr\(\s*' + STR)

def unescape(s: str) -> str:
    return s.encode('utf-8').decode('unicode_escape').encode('latin-1').decode('utf-8') if '\\' in s else s

keys: dict[str, str] = {}
for f in swift_files():
    text = f.read_text()
    for m in tr_re.finditer(text):
        k = unescape(m.group(1))
        if '\\(' in m.group(1):
            errors.append(f'{f.relative_to(root)}: tr() key uses string interpolation: {m.group(1)!r}')
        keys.setdefault(k, str(f.relative_to(root)))

catalog_path = app / 'Localizable.xcstrings'
if not catalog_path.exists():
    errors.append('MoveGrow/Localizable.xcstrings is missing')
    catalog = {'strings': {}}
else:
    catalog = json.loads(catalog_path.read_text())
    if catalog.get('sourceLanguage') != 'en':
        errors.append('Localizable.xcstrings: sourceLanguage must be en')
strings = catalog.get('strings', {})

ph_re = re.compile(r'%(?:(\d+)\$)?(?:l{0,2}|h|q)?([@dDiuUf])|%%')

def placeholders(s: str):
    """Placeholder types by argument position (numbered ones keep their number)."""
    out = {}
    n = 0
    for m in ph_re.finditer(s):
        if m.group(0) == '%%':
            continue
        conv = m.group(2)
        kind = '@' if conv == '@' else ('f' if conv == 'f' else 'd')
        if m.group(1):
            pos = int(m.group(1))
        else:
            n += 1
            pos = n
        out[pos] = kind
    return out

def value(entry, lang):
    loc = entry.get('localizations', {}).get(lang)
    if not loc:
        return None
    unit = loc.get('stringUnit')
    if not unit or unit.get('state') != 'translated':
        return None
    return unit.get('value')

for k, where in sorted(keys.items()):
    entry = strings.get(k)
    if entry is None:
        errors.append(f'missing from catalog: {k!r} ({where})')
        continue
    want = placeholders(k)
    en = value(entry, 'en')
    if en is not None and en != k:
        errors.append(f'en value differs from key: {k!r} → {en!r}')
    for lang in langs:
        v = value(entry, lang)
        if not v:
            errors.append(f'no {lang} translation: {k!r}')
            continue
        got = placeholders(v)
        if got != want:
            errors.append(f'{lang} placeholders {got} ≠ {want}: {k!r} → {v!r}')
        if v.strip() != v and k.strip() == k:
            errors.append(f'{lang} has stray spaces: {k!r} → {v!r}')

# Entries Xcode extracts by itself from plain literals (chart value labels …) are not ours to check.
unused = sorted(k for k in set(strings) - set(keys) if strings[k].get('extractionState') == 'manual')
if unused:
    errors.append(f'{len(unused)} catalog keys are not used by the app, e.g. {unused[:5]}')

# 3. Bare literals in SwiftUI that would stay English.
ui_calls = ['Text', 'Button', 'Label', 'Toggle', 'Picker', 'Section', 'TextField', 'DatePicker', 'Menu', 'Link',
            'NavigationLink', 'LabeledContent', 'ContentUnavailableView', 'ProgressView', 'Stepper', 'SharePreview',
            r'\.navigationTitle', r'\.accessibilityLabel', r'\.accessibilityHint', r'\.accessibilityValue', r'\.alert',
            r'\.confirmationDialog', r'\.help']
literal_re = re.compile(r'(?<![\w.])(' + '|'.join(ui_calls) + r')\(\s*' + STR)
allowed = {'MoveGrow', '0.25×', '0.5×', '1×', '2×'}
for f in swift_files():
    for i, line in enumerate(f.read_text().splitlines(), 1):
        if line.strip().startswith('//'):
            continue
        for m in literal_re.finditer(line):
            s = re.sub(r'\\\([^)]*\)', '', m.group(2))
            if re.search(r'[A-Za-z]', s) and m.group(2) not in allowed:
                errors.append(f'{f.relative_to(root)}:{i}: bare UI text {m.group(1)}("{m.group(2)}") — use tr() or verbatim:')

# 4. Rule book languages.
rules = json.loads((app / 'Motor/Resources/rules.json').read_text())
var_re = re.compile(r'\{([a-z_0-9]+)')
for r in rules['rules']:
    for field in ['name', 'message', 'message_expected', 'explain', 'followup', 'abstain_reason']:
        t = r.get(field)
        if not t:
            continue
        for lang in ['zh', 'en', 'es']:
            if not t.get(lang):
                errors.append(f'rules.json {r["id"]}.{field}: no {lang}')
        base = lambda s: {re.sub(r'_(zh|en|es)$', '', v) for v in var_re.findall(s or '')}
        if base(t.get('en')) != base(t.get('es')) or base(t.get('en')) != base(t.get('zh')):
            errors.append(f'rules.json {r["id"]}.{field}: placeholders differ between languages')

# 5. Permission prompts.
info = app / 'InfoPlist.xcstrings'
if not info.exists():
    errors.append('MoveGrow/InfoPlist.xcstrings is missing')
else:
    ic = json.loads(info.read_text())['strings']
    for key in ['NSCameraUsageDescription', 'NSPhotoLibraryAddUsageDescription']:
        for lang in ['en'] + langs:
            if not value(ic.get(key, {}), lang):
                errors.append(f'InfoPlist.xcstrings: {key} has no {lang}')

if errors:
    print('\n'.join(errors))
    print(f'FAIL: {len(errors)} localization problems')
    sys.exit(1)
print(f'PASS: {len(keys)} texts in English, 简体中文 and Español; rule book in 3 languages; no bare UI text.')
