"""Export the existing ivory/forest SVG brand-card design to four 1200x630 PNGs.

Uses the site's Outfit font and copy. No generated artwork, external images or services.
Normal npm builds ship these committed files and do not require Python dependencies.
"""
import argparse
import io
import json
import subprocess
from pathlib import Path
from xml.sax.saxutils import escape

from PIL import Image, ImageDraw, ImageFont
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parents[1]
FONT = ROOT / "node_modules/@fontsource-variable/outfit/files/outfit-latin-wght-normal.woff2"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--cjk-font", type=Path, default=Path("/System/Library/Fonts/Hiragino Sans GB.ttc"))
args = parser.parse_args()
if not args.cjk_font.exists():
    parser.error("A Simplified Chinese font is required via --cjk-font")

copies = json.loads(subprocess.check_output([
    "node", "--input-type=module", "-e",
    "const out={};for(const l of ['en','zh','de','es']){const {default:c}=await import(`./content/${l}.js`);out[l]={hero:c.hero,seo:c.seo};}process.stdout.write(JSON.stringify(out));",
], cwd=ROOT, text=True))
font_bytes = {}
for weight in [500, 650, 700]:
    font = instantiateVariableFont(TTFont(FONT), {"wght": weight}, inplace=True)
    font.flavor = None
    stream = io.BytesIO()
    font.save(stream)
    font_bytes[weight] = stream.getvalue()

SCALE = 2
PAPER, GREEN, INK, MUTED, LINE = "#f3f0e8", "#123f32", "#19221d", "#676d62", "#c8cbbd"


def render(language, copy):
    image = Image.new("RGB", (1200 * SCALE, 630 * SCALE), PAPER)
    draw = ImageDraw.Draw(image)
    elements = [f'<rect width="1200" height="630" fill="{PAPER}"/>']

    def font_for(size, weight, cjk=False):
        source = str(args.cjk_font) if cjk else io.BytesIO(font_bytes[weight])
        index = 2 if cjk and weight >= 600 and args.cjk_font.name == "Hiragino Sans GB.ttc" else 0
        return ImageFont.truetype(source, round(size * SCALE), index=index)

    def text(x, baseline, value, size, color, weight=500, cjk=False, right=False):
        font = font_for(size, weight, cjk)
        if right:
            x -= draw.textlength(value, font=font) / SCALE
        draw.text((round(x * SCALE), round(baseline * SCALE)), value, font=font, fill=color, anchor="ls")
        family = "Hiragino Sans GB, sans-serif" if cjk else "Outfit Variable, Arial, sans-serif"
        elements.append(f'<text x="{x:.2f}" y="{baseline}" font-family="{family}" font-size="{size}" font-weight="{weight}" fill="{color}">{escape(value)}</text>')

    def rule(y):
        draw.line((72 * SCALE, y * SCALE, 1128 * SCALE, y * SCALE), fill=LINE, width=SCALE)
        elements.append(f'<path d="M72 {y}h1056" stroke="{LINE}"/>')

    text(72, 100, "SkyCut", 44, GREEN, 700)
    text(1128, 98, "Sky Studio", 24, GREEN, right=True)
    rule(136)
    cjk = language == "zh"
    size = 110
    while any(draw.textlength(line, font=font_for(size, 650, cjk)) / SCALE > 1056 for line in copy["hero"]):
        size -= 1
    text(72, 294, copy["hero"][0], size, INK, 650, cjk)
    text(72, 419, copy["hero"][1], size, GREEN, 650, cjk)
    text(72, 479, copy["seo"]["cardSubtitle"], 28, MUTED, cjk=cjk)
    rule(525)
    text(72, 565, copy["seo"]["founderLabel"], 21, GREEN, cjk=cjk)
    text(72, 596, copy["seo"]["familyLabel"], 18, MUTED, cjk=cjk)
    text(1128, 565, "skycut.app", 24, GREEN, right=True)
    image = image.resize((1200, 630), Image.Resampling.LANCZOS)
    target = ROOT / f"public/media/og-card-{language}"
    image.save(target.with_suffix(".png"), optimize=True)
    svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">' + "".join(elements) + "</svg>\n"
    target.with_suffix(".svg").write_text(svg)
    if language == "en":
        (ROOT / "public/og-card.svg").write_text(svg)
    print(f"Created {target.name}.png 1200x630")


for language, copy in copies.items():
    render(language, copy)
