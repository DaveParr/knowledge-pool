"""Draw the Knowledge Pool mark and the GitHub repo art in Pool block.

Run: python3 docs/brand/build.py  (needs google-chrome to rasterise; fonts come
from Google Fonts, so it needs the network). Writes SVGs and PNGs next to itself.

The mark is the spinning top of the first icon redrawn in the design system's
language: one ink line, a disc filled with the pool gradient (the five mana
tints, as global.css draws it off a deck), and a hard offset ink shadow.
"""

import math
import pathlib
import subprocess
import tempfile

HERE = pathlib.Path(__file__).parent

TAGLINE = "Drink deep, brew better."

# Light is Pool block as designed. Dark is global.css's provisional dark theme
# (ink and paper swapped) until #229 designs one; the mana tints, and the dark
# text on them, stay the same in both.
THEMES = {
    "light": {"ink": "#1d1c1a", "paper": "#f7f6f2", "surface": "#ffffff", "muted": "#55524c"},
    "dark": {"ink": "#f5f4ef", "paper": "#1f1e1d", "surface": "#282725", "muted": "#a6a49c"},
}
ON_POOL = "#1d1c1a"
MANA = {"w": "#f8f3d6", "u": "#b4d7f0", "b": "#c8c1bd", "r": "#f0a68c", "g": "#9fd0ae"}
FONTS = (
    '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?'
    'family=Archivo:wght@800;900&family=Inter:wght@500;600;700&display=swap">'
)


def pool_gradient(gid: str, angle: float = 110) -> str:
    """The pool gradient as an SVG linearGradient, CSS angle convention."""
    a = math.radians(angle)
    dx, dy = math.sin(a) / 2, -math.cos(a) / 2
    stops = "".join(
        f'<stop offset="{i * 25}%" stop-color="{c}"/>' for i, c in enumerate(MANA.values())
    )
    return (
        f'<linearGradient id="{gid}" x1="{0.5 - dx:.3f}" y1="{0.5 - dy:.3f}" '
        f'x2="{0.5 + dx:.3f}" y2="{0.5 + dy:.3f}">{stops}</linearGradient>'
    )


def mark(t: dict, cx: float, cy: float, scale: float, gid: str, w: float = 9, shadow: float = 10) -> str:
    """The spinning top, centred on (cx, cy); scale 1 spans about 420px.

    Drawn in a local frame whose axis is vertical, then tilted. `w` is the ink
    weight and `shadow` the offset of the solid ink copy behind it (0 for none).
    """
    rx, ry, band = 168, 54, 24

    INK, SURFACE = t["ink"], t["surface"]
    lower = '<polygon points="-9,30 9,30 34,236 -34,236" fill="{f}" stroke="{s}" stroke-width="{w}" stroke-linejoin="round"/>'
    upper = '<polygon points="-5,-40 5,-40 24,-226 -24,-226" fill="{f}" stroke="{s}" stroke-width="{w}" stroke-linejoin="round"/>'
    hub = '<ellipse cx="0" cy="{y}" rx="46" ry="17" fill="{f}" stroke="{s}" stroke-width="{w}"/>'
    # The crown: a short frustum with three points, standing on the disc.
    crown = (
        '<path d="M -46 -2 L -42 -72 L -22 -46 L 0 -98 L 22 -46 L 42 -72 L 46 -2 '
        'A 46 15 0 0 1 -46 -2 Z" fill="{f}" stroke="{s}" stroke-width="{w}" stroke-linejoin="round"/>'
    )

    def shapes(fill_top, fill_band, fill_parts, stroke):
        out = [
            lower.format(f=INK, s=stroke, w=w),
            hub.format(y=band + 22, f=fill_parts, s=stroke, w=w),
            # The rim: the disc's underside, then its top face.
            f'<ellipse cx="0" cy="{band}" rx="{rx}" ry="{ry}" fill="{fill_band}" stroke="{stroke}" stroke-width="{w}"/>',
            f'<rect x="{-rx}" y="0" width="{2 * rx}" height="{band}" fill="{fill_band}"/>',
            f'<line x1="{-rx}" y1="0" x2="{-rx}" y2="{band}" stroke="{stroke}" stroke-width="{w}"/>',
            f'<line x1="{rx}" y1="0" x2="{rx}" y2="{band}" stroke="{stroke}" stroke-width="{w}"/>',
            f'<ellipse cx="0" cy="0" rx="{rx}" ry="{ry}" fill="{fill_top}" stroke="{stroke}" stroke-width="{w}"/>',
        ]
        if stroke == INK and fill_top != INK:
            # Notches across the front of the rim, like the first mark's.
            for deg in range(20, 180, 32):
                t = math.radians(deg)
                x, y = rx * math.cos(t), ry * math.sin(t)
                out.append(
                    f'<line x1="{x:.1f}" y1="{y:.1f}" x2="{x:.1f}" y2="{y + band:.1f}" '
                    f'stroke="{INK}" stroke-width="{w * 0.7:.1f}" stroke-linecap="round"/>'
                )
        out.append(crown.format(f=fill_parts, s=stroke, w=w))
        out.append(upper.format(f=fill_parts if fill_parts == INK else INK, s=stroke, w=w))
        return "".join(out)

    tilt = 30
    body = []
    if shadow:
        body.append(
            f'<g transform="translate({cx + shadow * scale} {cy + shadow * scale}) rotate({tilt}) scale({scale})">'
            f"{shapes(INK, INK, INK, INK)}</g>"
        )
    body.append(
        f'<g transform="translate({cx} {cy}) rotate({tilt}) scale({scale})">'
        f'{shapes(f"url(#{gid})", SURFACE, SURFACE, INK)}</g>'
    )
    return "".join(body)


def svg(width: int, height: int, inner: str, defs: str = "") -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}"><defs>{defs}</defs>{inner}</svg>'
    )


def tile(t: dict, x, y, size, radius, frame, shadow) -> str:
    """An ink box with a hard offset shadow, as every panel in the app is drawn."""
    return (
        f'<rect x="{x + shadow}" y="{y + shadow}" width="{size}" height="{size}" rx="{radius}" fill="{t["ink"]}"/>'
        f'<rect x="{x}" y="{y}" width="{size}" height="{size}" rx="{radius}" fill="{t["paper"]}" '
        f'stroke="{t["ink"]}" stroke-width="{frame}"/>'
    )


def icon_tile(t: dict, size: int = 512) -> str:
    """The mark in a paper tile with an ink frame and offset shadow (avatar, favicon)."""
    k = size / 512
    box, off = 468 * k, 18 * k
    defs = pool_gradient("pool")
    inner = tile(t, 10 * k, 10 * k, box, 72 * k, 14 * k, off) + mark(
        t, 10 * k + box / 2 - 6 * k, 10 * k + box / 2 + 2 * k, 0.78 * k, "pool", w=11, shadow=9
    )
    return svg(size, size, inner, defs)


def icon_full(t: dict, size: int = 512) -> str:
    """Full-bleed paper square for platforms that round the corners themselves."""
    k = size / 512
    defs = pool_gradient("pool")
    inner = f'<rect width="{size}" height="{size}" fill="{t["paper"]}"/>' + mark(
        t, size / 2 - 6 * k, size / 2, 0.92 * k, "pool", w=11, shadow=10
    )
    return svg(size, size, inner, defs)


def mark_only(t: dict, size: int = 512) -> str:
    k = size / 512
    return svg(size, size, mark(t, size / 2 - 6 * k, size / 2, 0.98 * k, "pool", w=10, shadow=9), pool_gradient("pool"))


def pip(letter: str, colour: str, size: int) -> str:
    return (
        f'<span class="pip" style="width:{size}px;height:{size}px;background:{colour};'
        f'font-size:{size * 0.5:.0f}px">{letter}</span>'
    )


POOL_CSS = f"linear-gradient(110deg,{','.join(MANA.values())})"


def page_css(t: dict) -> str:
    return f"""
html,body{{margin:0;background:transparent}}
.pip{{display:inline-flex;align-items:center;justify-content:center;border-radius:50%;
  border:3px solid {t["ink"]};box-sizing:border-box;color:{ON_POOL};font:800 16px/1 Inter,sans-serif}}
"""


def social_preview(t: dict) -> str:
    """1280x640 GitHub social preview: mark tile left, wordmark and tagline right."""
    mark_svg = icon_tile(t, 360)
    pips = "".join(pip(k.upper(), c, 46) for k, c in MANA.items())
    return f"""<!doctype html><meta charset="utf-8">{FONTS}<style>{page_css(t)}
body{{width:1280px;height:640px;background:{t["paper"]};position:relative;overflow:hidden;font-family:Inter,sans-serif;color:{t["ink"]}}}
.cap{{position:absolute;left:0;right:0;top:0;height:22px;background:{POOL_CSS};border-bottom:4px solid {t["ink"]}}}
.foot{{position:absolute;left:0;right:0;bottom:0;height:14px;background:{t["ink"]}}}
.icon{{position:absolute;left:96px;top:136px}}
.copy{{position:absolute;left:520px;top:132px;right:60px}}
h1{{font:900 84px/0.9 Archivo,sans-serif;text-transform:uppercase;letter-spacing:-.02em;margin:0;color:{ON_POOL}}}
.title-box{{display:inline-block;background:{POOL_CSS};border:5px solid {t["ink"]};
  border-radius:14px;box-shadow:10px 10px 0 {t["ink"]};padding:22px 30px 18px;margin-bottom:34px}}
.tagline{{font:700 38px/1.1 Inter,sans-serif;letter-spacing:-.01em;margin:0 0 28px}}
.pips{{display:flex;gap:12px;align-items:center}}
.tag{{font:800 18px/1 Inter,sans-serif;text-transform:uppercase;letter-spacing:.06em;border:3px solid {t["ink"]};
  border-radius:8px;padding:9px 12px;background:{t["surface"]};box-shadow:4px 4px 0 {t["ink"]};margin-left:18px}}
</style><body><div class="cap"></div>
<div class="icon">{mark_svg}</div>
<div class="copy"><div class="title-box"><h1>Knowledge<br>Pool</h1></div>
<p class="tagline">{TAGLINE}</p>
<div class="pips">{pips}<span class="tag">Web</span><span class="tag">MCP</span></div></div>
<div class="foot"></div></body>"""


def readme_banner(t: dict) -> str:
    """1280x320 banner for the top of the README."""
    mark_svg = icon_tile(t, 220)
    return f"""<!doctype html><meta charset="utf-8">{FONTS}<style>{page_css(t)}
body{{width:1280px;height:320px;background:transparent;position:relative;font-family:Inter,sans-serif;color:{t["ink"]}}}
.frame{{position:absolute;left:12px;top:12px;width:1240px;height:280px;box-sizing:border-box;background:{t["paper"]};
  border:5px solid {t["ink"]};border-radius:18px;box-shadow:12px 12px 0 {t["ink"]};overflow:hidden}}
.cap{{height:26px;background:{POOL_CSS};border-bottom:4px solid {t["ink"]}}}
.icon{{position:absolute;left:52px;top:40px}}
.copy{{position:absolute;left:330px;top:90px}}
h1{{font:900 80px/0.95 Archivo,sans-serif;white-space:nowrap;text-transform:uppercase;letter-spacing:-.02em;margin:0 0 16px}}
.tagline{{font:700 32px/1.1 Inter,sans-serif;letter-spacing:-.01em;margin:0}}
</style><body><div class="frame"><div class="cap"></div>
<div class="icon">{mark_svg}</div>
<div class="copy"><h1>Knowledge Pool</h1><p class="tagline">{TAGLINE}</p></div>
</div></body>"""


def shoot(html: str, out: pathlib.Path, w: int, h: int, scale: int = 1) -> None:
    with tempfile.TemporaryDirectory() as d:
        page = pathlib.Path(d) / "page.html"
        page.write_text(html)
        subprocess.run(
            [
                "google-chrome", "--headless=new", "--disable-gpu", "--hide-scrollbars",
                "--default-background-color=00000000", f"--force-device-scale-factor={scale}",
                "--virtual-time-budget=4000", f"--window-size={w},{h}",
                f"--screenshot={out}", page.as_uri(),
            ],
            check=True, capture_output=True,
        )


def svg_page(t: dict, s: str) -> str:
    return f'<!doctype html><style>{page_css(t)}svg{{display:block}}</style>{s}'


def main() -> None:
    out = HERE
    for theme, t in THEMES.items():
        sfx = "" if theme == "light" else "-dark"
        for name, fn in [("icon-tile", icon_tile), ("icon-full", icon_full), ("mark", mark_only)]:
            (out / f"knowledge-pool-{name}{sfx}.svg").write_text(fn(t, 512))
            shoot(svg_page(t, fn(t, 512)), out / f"knowledge-pool-{name}{sfx}-512.png", 512, 512)
        for size in (16, 32, 64):
            shoot(svg_page(t, icon_tile(t, size)), out / f"knowledge-pool-icon-tile{sfx}-{size}.png", size, size)
        shoot(svg_page(t, icon_full(t, 180)), out / f"knowledge-pool-icon-full{sfx}-180.png", 180, 180)
        shoot(readme_banner(t), out / f"readme-banner{sfx}.png", 1280, 320, scale=2)
    # Link previews (Slack, X, LinkedIn) show one image with no theme, so the
    # social preview is light only.
    shoot(social_preview(THEMES["light"]), out / "social-preview.png", 1280, 640)


if __name__ == "__main__":
    main()
