"""Generate a deterministic synthetic screenshot; no patient or CamAPS assets.

Requires Pillow on macOS. CI consumes the committed PNG, not this generator.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "InsulinOCRUITests/Fixtures/SyntheticTherapy12Hours.png"
FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"


def generate():
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
    draw.line((left + 1, 700, end, 700), fill=(0, 122, 255), width=5)
    for index in range(144):
        x = left + (index + 0.5) * (end - left) / 144
        draw.ellipse((x - 6, 774, x + 6, 786), fill="black")
    draw.text((1311, 1158), "Synthetic fixture: basal 0.8 IE/h; glucose 6 mmol/L; no events",
              font=small, fill="black", anchor="mm")
    exif = Image.Exif()
    exif[306] = "2026:01:02 12:00:00"
    exif[34665] = {36867: "2026:01:02 12:00:00", 36868: "2026:01:02 12:00:00"}
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    image.save(TARGET, exif=exif)
    print(TARGET)


if __name__ == "__main__":
    generate()
