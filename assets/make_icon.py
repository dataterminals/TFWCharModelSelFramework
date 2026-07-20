"""Generate the CMSF mod icon (SVG + PNG).

House style from the sibling TFW mods (AllWeaponsUnlockableFix/ScavgirlCarryPerks): a bold
wordmark inside a thin rule inset from the edge. Two differences here, both requested:

  * REVERSED palette. The others are a navy field with a gold rule and cream ink. This is
    the inverse — a gold field with a navy rule and navy ink ("all gold, the inlay is blue").
  * A wordmark PLUS a spelled-out subtitle, rather than two stacked acronyms. "CMSF" reads
    at thumbnail size; the subtitle is secondary, so it is measured to the largest size that
    still fits the rule and sits below.

    python assets/make_icon.py

Emits assets/icon.svg and assets/icon.png (1024x1024, RGB).
"""
from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
INSET = 50            # rule offset from the canvas edge
RULE = 5              # rule stroke width
SIDE_MARGIN = 62      # clear space between the rule and the widest line
GAP_WORD = 44         # wordmark -> subtitle
GAP_SUB = 14          # between subtitle lines

# Reversed palette: gold field, navy inlay (rule + ink).
GOLD = (200, 154, 71)
NAVY = (27, 37, 56)
BG, RULE_COLOR, INK = GOLD, NAVY, NAVY

FONT_PATH = r"C:\Windows\Fonts\arialbd.ttf"
FONT_SVG = "Arial, Helvetica, sans-serif"

WORD = "CMSF"
SUB = ["Character Model", "Selection Framework"]

max_width = SIZE - 2 * INSET - 2 * SIDE_MARGIN


def fit(texts, cap_pt):
    """Largest point size (<= cap_pt) at which every text fits max_width."""
    for pt in range(cap_pt, 20, -1):
        font = ImageFont.truetype(FONT_PATH, pt)
        if max(font.getbbox(t)[2] - font.getbbox(t)[0] for t in texts) <= max_width:
            return pt, font
    raise SystemExit("nothing fits")


# Wordmark: dominant, but capped so it leaves room for the subtitle.
word_pt, word_font = fit([WORD], 340)
# Subtitle: smaller; capped relative to the wordmark so the hierarchy is clear.
sub_pt, sub_font = fit(SUB, round(word_pt * 0.30))


def cap(font, text):
    t, b = font.getbbox(text)[1], font.getbbox(text)[3]
    return t, b, b - t


_, _, word_cap = cap(word_font, WORD)
sub_caps = [cap(sub_font, t) for t in SUB]
sub_cap = max(c for _, _, c in sub_caps)

# Total stacked height, centred on the canvas.
block = word_cap + GAP_WORD + len(SUB) * sub_cap + (len(SUB) - 1) * GAP_SUB
y = round((SIZE - block) / 2)

word_baseline = y + word_cap
y += word_cap + GAP_WORD
sub_baselines = []
for i in range(len(SUB)):
    sub_baselines.append(y + sub_cap)
    y += sub_cap + GAP_SUB

# ---- PNG ----
img = Image.new("RGB", (SIZE, SIZE), BG)
d = ImageDraw.Draw(img)
d.rectangle([INSET, INSET, SIZE - INSET, SIZE - INSET], outline=RULE_COLOR, width=RULE)
d.text((SIZE // 2, word_baseline), WORD, font=word_font, fill=INK, anchor="ms")
for text, base in zip(SUB, sub_baselines):
    d.text((SIZE // 2, base), text, font=sub_font, fill=INK, anchor="ms")
img.save("assets/icon.png")

# ---- SVG ----
sub_svg = "\n".join(
    f'  <text x="{SIZE // 2}" y="{base}" font-family="{FONT_SVG}" font-weight="bold" '
    f'font-size="{sub_pt}" fill="rgb{INK}" text-anchor="middle">{text}</text>'
    for text, base in zip(SUB, sub_baselines)
)
svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">
  <rect width="{SIZE}" height="{SIZE}" fill="rgb{BG}"/>
  <rect x="{INSET}" y="{INSET}" width="{SIZE - 2 * INSET}" height="{SIZE - 2 * INSET}"
        fill="none" stroke="rgb{RULE_COLOR}" stroke-width="{RULE}"/>
  <text x="{SIZE // 2}" y="{word_baseline}" font-family="{FONT_SVG}" font-weight="bold" font-size="{word_pt}" fill="rgb{INK}" text-anchor="middle">{WORD}</text>
{sub_svg}
</svg>
"""
with open("assets/icon.svg", "w", encoding="utf-8", newline="\n") as f:
    f.write(svg)

print(f"CMSF: wordmark {word_pt}px, subtitle {sub_pt}px -> assets/icon.{{svg,png}}")
