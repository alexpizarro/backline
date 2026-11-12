#!/usr/bin/env python3
"""WCAG 2.2 contrast audit for Backline.

Part 1 checks the colours the app ships today (Backline/UI/Theme.swift, dark only), using the pairings
the views actually draw. Part 2 checks the proposed 'Soundcheck' tokens in docs/design/tokens.json for
light and dark. Translucent colours are composited over their real backdrop first (gamma-space 'over',
which is what Core Animation does for sRGB layers).

Run:  python3 -I docs/design/contrast.py            (prints Markdown tables)
      python3 -I docs/design/contrast.py --strict   (exit 1 if any proposed pairing fails)

Targets: body text 4.5:1, large text (>= 18 pt, or >= 14 pt bold) 3:1, UI component boundaries and
meaningful graphics 3:1 (WCAG 1.4.11). Rows marked 'deco' are decorative and are reported, not judged.
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


# ----------------------------------------------------------------------------- colour maths

def hex_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def rgb_hex(c):
    return '#' + ''.join(f'{round(max(0, min(1, v)) * 255):02X}' for v in c)


def over(fg, alpha, bg):
    """Composite fg at `alpha` over opaque bg (gamma space)."""
    return tuple(f * alpha + b * (1 - alpha) for f, b in zip(fg, bg))


def lum(c):
    def ch(v):
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(v) for v in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def oklch(l, c, h):
    """Same maths as Theme.oklchToSRGB (gamut clipped)."""
    hr = math.radians(h)
    a, b = c * math.cos(hr), c * math.sin(hr)
    l_ = l + 0.3963377774 * a + 0.2158037573 * b
    m_ = l - 0.1055613458 * a - 0.0638541728 * b
    s_ = l - 0.0894841775 * a - 1.2914855480 * b
    L, M, S = l_ ** 3, m_ ** 3, s_ ** 3
    rl = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
    gl = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
    bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S

    def gamma(x):
        v = max(0.0, min(1.0, x))
        return 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055
    return (gamma(rl), gamma(gl), gamma(bl))


TARGET = {'text': 4.5, 'large': 3.0, 'ui': 3.0, 'graphic': 3.0, 'visible': 2.0, 'deco': 0.0}


def row(label, fg, bg, kind, where=''):
    r = ratio(fg, bg)
    t = TARGET[kind]
    verdict = 'deco' if kind == 'deco' else ('PASS' if r >= t else 'FAIL')
    return (label, rgb_hex(fg), rgb_hex(bg), r, kind, t, verdict, where)


def table(title, rows):
    out = [f'\n### {title}\n', '| Pairing | Fg | Bg | Ratio | Kind | Target | Result | Where |',
           '|---|---|---|---:|---|---:|---|---|']
    for label, fg, bg, r, kind, t, verdict, where in rows:
        mark = f'**{verdict}**' if verdict == 'FAIL' else verdict
        out.append(f'| {label} | `{fg}` | `{bg}` | {r:.2f} | {kind} | {t:g} | {mark} | {where} |')
    fails = sum(1 for x in rows if x[6] == 'FAIL')
    out.append(f'\n{fails} of {sum(1 for x in rows if x[6] != "deco")} judged pairings fail.')
    return '\n'.join(out), fails


# ----------------------------------------------------------------------------- part 1: today

def current_rows():
    H = hex_rgb
    bg, chrome, elevated, card = H('0F0F14'), H('13131B'), H('181824'), H('1F1F2C')
    card_hover, inset, toggle_off = H('262636'), H('15151E'), H('2E2E40')
    ink, ink2, muted, inaudible = H('F4F4F5'), H('D4D4D8'), H('8B8B9E'), H('3A3A4C')
    primary, primary_hover, tint = H('6E56CF'), H('7C66D9'), H('A594F0')
    magenta, magenta_text = H('D946EF'), H('F0ABFC')
    warning, danger, success = H('F59E0B'), H('EF4444'), H('22C55E')
    white = (1.0, 1.0, 1.0)
    off_row = over(elevated, 0.45, bg)                     # StemRow background when the part is off
    rows = [
        row('ink on bg', ink, bg, 'text', 'titles'),
        row('muted on bg', muted, bg, 'text', 'captions, meta line'),
        row('muted on elevated', muted, elevated, 'text', 'stem status "Playing", library artist'),
        row('muted on card', muted, card, 'text', 'sheet captions (sheets use card)'),
        row('muted on cardHover', muted, card_hover, 'text', 'Solo "S" (12 pt bold)'),
        row('muted @0.8 on card', over(muted, 0.8, card), card, 'text', '"Only use music you\'re allowed to use."'),
        row('muted @0.85 on card', over(muted, 0.85, card), card, 'text', 'Record footnote'),
        row('muted @0.5 on card', over(muted, 0.5, card), card, 'ui', 'disabled stepper minus/plus'),
        row('primaryTint on bg', tint, bg, 'text', 'links, Tempo menu, Dance style'),
        row('primaryTint on card', tint, card, 'text', '"Cancel"/"Done" in sheets'),
        row('white on primary', white, primary, 'text', 'primary buttons 15 pt semibold'),
        row('white on primaryHover (pressed)', white, primary_hover, 'text', 'primary button pressed'),
        row('white on magenta', white, magenta, 'text', '"Tap on the 1" (13 pt bold)'),
        row('magentaText on magenta@0.2/card', magenta_text, over(magenta, 0.2, card), 'text', 'active section chip 11.5 pt'),
        row('magenta on off-row', magenta, off_row, 'text', 'stem status "Removed" 11.5 pt'),
        row('muted on off-row', muted, off_row, 'text', 'stem name when off (15 pt)'),
        row('bg on warning', bg, warning, 'text', 'Solo active "S"'),
        row('warning on bg', warning, bg, 'text', '"Paused. Come back…"'),
        row('danger on card', danger, card, 'text', 'inline errors in Add Song'),
        row('toggleOff track vs elevated row', toggle_off, elevated, 'ui', 'part switch OFF state'),
        row('toggleOff track vs off-row', toggle_off, off_row, 'ui', 'part switch OFF on a dimmed row'),
        row('slider track vs elevated', toggle_off, elevated, 'ui', 'volume slider rail'),
        row('card fill vs chrome', card, chrome, 'ui', 'stepper / chip / secondary button body'),
        row('hairline2 border vs chrome', over(white, 0.08, chrome), chrome, 'ui', 'stepper, chip, button outline'),
        row('hairline vs bg', over(white, 0.06, bg), bg, 'deco', 'stem row outline'),
        row('cardHover (S button) vs elevated', card_hover, elevated, 'ui', 'Solo button body'),
        row('ModeSwitch selected fill vs card', over(primary, 0.36, card), card, 'ui', 'selected mode capsule'),
        row('ChoicePill active border vs bg', over(magenta, 0.6, bg), bg, 'ui', '"I\'m playing" selected pill'),
        row('ToggleChip on fill vs chrome', over(primary, 0.18, chrome), chrome, 'ui', 'Count-in/Click ON'),
        row('overview idle bars vs inset', over(muted, 0.45, inset), inset, 'graphic', 'overview unplayed bars'),
        row('overview played bars vs inset', primary_hover, inset, 'graphic', 'overview played bars'),
        row('inaudible stem bars vs elevated', inaudible, elevated, 'visible', 'waveform of a part that is off'),
        row('grid line white@0.07 vs inset', over(white, 0.07, inset), inset, 'deco', 'bar/eight grid lines'),
        row('loop fill magenta@0.10 vs inset', over(magenta, 0.10, inset), inset, 'deco', 'loop region tint'),
        row('loop edge magenta vs inset', magenta, inset, 'graphic', 'loop edges and handles'),
        row('progress track card vs bg', card, bg, 'ui', 'Analyzing progress rail'),
        row('progress fill vs card', primary, card, 'graphic', 'Analyzing progress fill'),
        row('pending step dot vs bg', toggle_off, bg, 'graphic', 'Analyzing step dots'),
    ]
    for name, hue in [('vocals', 20), ('lead', 330), ('rhythm', 295), ('bass', 260), ('drums', 200),
                      ('keys', 150), ('other', 90), ('kick', 215), ('toms', 235)]:
        c = oklch(0.72, 0.15, hue)
        rows.append(row(f'stem {name} vs elevated', c, elevated, 'graphic', 'switch track ON, waveform bars'))
    return rows


# ----------------------------------------------------------------------------- part 2: proposed

def proposed_rows(mode, tokens):
    T = {}
    for k, v in tokens['tokens'].items():
        T[k] = (hex_rgb(v[mode]), v.get('a', 1.0))

    def solid(name, bg=None):
        c, a = T[name]
        return c if a >= 1 else over(c, a, bg)

    canvas, surface, raised, sunken = (solid(n) for n in ('canvas', 'surface', 'raised', 'sunken'))
    ink, ink2, ink3 = solid('ink'), solid('ink2'), solid('ink3')
    accent, edge, on_accent, accent_text = solid('accent'), solid('accentEdge'), solid('onAccent'), solid('accentText')
    glass = solid('glassTint', canvas)
    rows = []
    for fgn in ('ink', 'ink2', 'ink3', 'accentText', 'live', 'ok', 'caution'):
        for bgn, bgc in (('canvas', canvas), ('surface', surface), ('raised', raised), ('glass', glass)):
            rows.append(row(f'{fgn} on {bgn}', solid(fgn), bgc, 'text'))
    rows += [
        row('onAccent on accent', on_accent, accent, 'text', 'play glyph, primary button label'),
        row('canvas on caution', canvas, solid('caution'), 'text', 'solo "S" when on'),
        row('ink on accentSoft/surface', ink, solid('accentSoft', surface), 'text', 'selected chip label'),
        row('accentText on accentSoft/surface', accent_text, solid('accentSoft', surface), 'text', 'selected chip label (accent)'),
        row('accentEdge vs canvas', edge, canvas, 'ui', 'primary button / play button boundary'),
        row('accentEdge vs surface', edge, surface, 'ui', 'primary button on a sheet'),
        row('stroke vs surface', solid('stroke'), surface, 'ui', 'secondary button, stepper, chip outline'),
        row('stroke vs canvas', solid('stroke'), canvas, 'ui', 'outline on the canvas'),
        row('stroke vs glass', solid('stroke'), glass, 'ui', 'controls on the chrome'),
        row('switchOff vs surface', solid('switchOff'), surface, 'ui', 'part switch OFF track'),
        row('knob vs switchOff', solid('knob'), solid('switchOff'), 'ui', 'switch knob on OFF track'),
        row('waveIdle vs sunken', solid('waveIdle', sunken), sunken, 'graphic', 'overview unplayed bars'),
        row('wavePlayed vs sunken', solid('wavePlayed'), sunken, 'graphic', 'overview played bars'),
        row('playhead vs sunken', solid('playhead'), sunken, 'graphic', 'playhead'),
        row('loopEdge vs sunken', solid('loopEdge'), sunken, 'graphic', 'loop edges and spike-tape tabs'),
        row('loopEdge vs loopFill', solid('loopEdge'), solid('loopFill', sunken), 'graphic', 'loop edge inside the lit region'),
        row('waveLit vs loopFill', solid('waveLit'), solid('loopFill', sunken), 'graphic', 'every bar inside the loop (no played/unplayed split there; the playhead shows position)'),
        row('playhead vs loopFill', solid('playhead'), solid('loopFill', sunken), 'visible', 'playhead inside the loop (glow and width carry it)'),
        row('wavePlayed vs waveIdle', solid('wavePlayed'), solid('waveIdle'), 'visible', 'played vs not played'),
        row('waveOff vs surface', solid('waveOff'), surface, 'visible', 'bars of a part that is off'),
        row('ink on scrim over a mid photo', ink if mode == 'dark' else hex_rgb('F7F1E8'),
            over(T['scrim'][0], T['scrim'][1], hex_rgb('8A7A6A')), 'text', 'captions on photography'),
        row('hairline vs surface', solid('hairline', surface), surface, 'deco', 'separators'),
        row('tapeInk on tapeFill', solid('tapeInk'), solid('tapeFill'), 'text', 'marker text on tape (>= 13 pt)'),
        row('onAccent on accent tape', on_accent, accent, 'text', 'YOU tape, active section tape'),
        row('tapeFill vs glass', solid('tapeFill'), glass, 'deco', 'tape outline: decorative; the marker text (12:1+) identifies the control, the selected tape is amber'),
        row('onPhoto on scrim over a light photo area', solid('onPhoto'), over(T['scrim'][0], T['scrim'][1], hex_rgb('D9C2A0')), 'text', 'title on the brightest part of a photo')
    ]
    L = tokens['stemLightness'][mode]
    C = tokens['stemLightness']['chroma']
    for name, v in tokens['stems'].items():
        if name.startswith('_'):
            continue
        c = oklch(L, C, v['hue'])
        rows.append(row(f'stem {name} {rgb_hex(c)} vs surface', c, surface, 'graphic', 'switch ON track, bars'))
        rows.append(row(f'stem {name} vs sunken', c, sunken, 'graphic', 'colour tab, bars in a well'))
    return rows


def stem_hex(tokens):
    out = ['\n### Part colours (hex to paste into the asset catalog)\n', '| Part | Hue | Light | Dark |', '|---|---:|---|---|']
    for name, v in tokens['stems'].items():
        if name.startswith('_'):
            continue
        lo = rgb_hex(oklch(tokens['stemLightness']['light'], tokens['stemLightness']['chroma'], v['hue']))
        dk = rgb_hex(oklch(tokens['stemLightness']['dark'], tokens['stemLightness']['chroma'], v['hue']))
        out.append(f'| {name} | {v["hue"]} | `{lo}` | `{dk}` |')
    return '\n'.join(out)


def main():
    tokens = json.load(open(os.path.join(HERE, 'tokens.json')))
    print('## Part 1: colours shipping today (dark only)')
    text, _ = table('Theme.swift pairings', current_rows())
    print(text)
    print('\n## Part 2: proposed Soundcheck tokens')
    total = 0
    for mode in ('dark', 'light'):
        text, fails = table(f'{mode.capitalize()} mode', proposed_rows(mode, tokens))
        total += fails
        print(text)
    print(stem_hex(tokens))
    if '--strict' in sys.argv and total:
        sys.exit(1)


if __name__ == '__main__':
    main()
