"""Generate deterministic synthetic screenshots; no patient or CamAPS assets.

Requires Pillow. CI consumes the committed PNGs, not this generator. The base
fixture was rendered on macOS with Arial; the events fixture was rendered with
the metric-compatible Liberation Sans. Pass the fixture names to regenerate
(`base`, `events`); a different font changes the PNG bytes.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "InsulinOCRUITests/Fixtures"
TARGET = FIXTURES / "SyntheticTherapy12Hours.png"
EVENTS_TARGET = FIXTURES / "SyntheticTherapyEvents12Hours.png"
FONTS = ("/System/Library/Fonts/Supplemental/Arial.ttf",
         "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf")
FONT = next((path for path in FONTS if Path(path).exists()), FONTS[0])
BLUE, ORANGE = (0, 122, 255), (255, 149, 0)
# (hour on the time axis, label, stem colour). Whole odd hours avoid the
# two-hourly grid; one hour is wider than the engine's pill crop.
EVENTS = ((3, "24 g", ORANGE), (7, "4 U", BLUE))


def draw_event(draw, x, top, label, colour, font):
    """A pale-bordered pill above the chart with a coloured stem into it."""
    pill_top, pill_bottom, stem_bottom = top - 98, top - 52, top + 70
    draw.rounded_rectangle((x - 62, pill_top, x + 62, pill_bottom), radius=23,
                           fill="white", outline=(215, 215, 215), width=2)
    draw.text((x, (pill_top + pill_bottom) / 2), label, font=font,
              fill="black", anchor="mm")
    draw.rectangle((x - 2, pill_bottom, x + 2, stem_bottom), fill=colour)


def generate(events=False):
    image = Image.new("RGB", (2622, 1206), "white")
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype(FONT, 32)
    small = ImageFont.truetype(FONT, 26)
    left, right, top, bottom, end = 180, 2380, 220, 1020, 2280
    grey = (150, 150, 150)
    draw.text((1311, 65), "SYNTHETIC QA - NO PATIENT DATA", font=font,
              fill="black", anchor="mm")
    draw.rectangle((end, top, right, bottom), fill=(215, 215, 215))
    for value in (0, 0.5, 1, 1.5, 2):
        y = bottom - value * 400
        draw.line((left - 15, y, right + 15, y), fill=grey, width=2)
        draw.text((125, y), f"{value:g}", font=font, fill="black", anchor="mm")
    for value in (5, 10, 15, 20):
        y = bottom - value * 40
        draw.text((2445, y), str(value), font=font, fill="black", anchor="mm")
    for hour in range(0, 13, 2):
        x = left + (end - left) * hour / 12
        draw.line((x, top, x, bottom), fill=grey, width=2)
        draw.text((x, bottom + 55), f"{hour:02}:00", font=font,
                  fill="black", anchor="mm")
    draw.line((left, top, left, bottom), fill=grey, width=2)
    draw.line((right, top, right, bottom), fill=grey, width=2)
    # Constant 0.8 IE/h for twelve hours; 144 five-minute samples at 6 mmol/L.
    draw.line((left + 1, 700, end, 700), fill=BLUE, width=5)
    for index in range(144):
        x = left + (index + 0.5) * (end - left) / 144
        draw.ellipse((x - 6, 774, x + 6, 786), fill="black")
    caption = "no events"
    if events:
        caption = "carbohydrates 24 g at 03:00; bolus 4 U at 07:00"
        for hour, label, colour in EVENTS:
            draw_event(draw, left + (end - left) * hour // 12, top, label,
                       colour, ImageFont.truetype(FONT, 34))
    draw.text((1311, 1158), f"Synthetic fixture: basal 0.8 IE/h; glucose 6 mmol/L; {caption}",
              font=small, fill="black", anchor="mm")
    exif = Image.Exif()
    exif[306] = "2026:01:02 12:00:00"
    exif[34665] = {36867: "2026:01:02 12:00:00", 36868: "2026:01:02 12:00:00"}
    target = EVENTS_TARGET if events else TARGET
    target.parent.mkdir(parents=True, exist_ok=True)
    image.save(target, exif=exif)
    print(target)


if __name__ == "__main__":
    names = sys.argv[1:] or ["base", "events"]
    if set(names) - {"base", "events"}:
        sys.exit("usage: generate_ui_fixture.py [base] [events]")
    for name in names:
        generate(events=name == "events")
