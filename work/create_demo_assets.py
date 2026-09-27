"""Draw original, brand-neutral sample artwork for the built-in demo lists."""

from pathlib import Path
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent
WINDOWS = ROOT / "bonraffle_winui" / "Assets" / "Demo"
MAC = ROOT / "bonraffle_macos" / "Resources" / "Demo"
WINDOWS.mkdir(parents=True, exist_ok=True)
MAC.mkdir(parents=True, exist_ok=True)


def save(name, draw_image):
    image = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    pen = ImageDraw.Draw(image)
    draw_image(pen)
    image = image.resize((256, 256), Image.Resampling.LANCZOS)
    for folder in (WINDOWS, MAC):
        image.save(folder / name)


people = [
    ("demo-person-1.png", "#3A6A96", "#E7AC78", "#3E2C2B", "#D2691E"),
    ("demo-person-2.png", "#715E9D", "#BD855B", "#282A33", "#79A9C4"),
    ("demo-person-3.png", "#2E7D75", "#D99B71", "#593D2D", "#F0B776"),
    ("demo-person-4.png", "#A3526C", "#C58B62", "#29252A", "#3A6A96"),
]

for name, background, skin, hair, shirt in people:
    def portrait(pen):
        pen.rounded_rectangle((16, 16, 496, 496), radius=94, fill=background)
        pen.ellipse((100, 270, 412, 590), fill=shirt)
        pen.rounded_rectangle((205, 250, 307, 345), radius=35, fill=skin)
        pen.ellipse((150, 104, 362, 325), fill=skin)
        pen.pieslice((140, 72, 370, 320), 170, 370, fill=hair)
        pen.ellipse((214, 226, 228, 240), fill="#3C2F2A")
        pen.ellipse((286, 226, 300, 240), fill="#3C2F2A")
        pen.arc((232, 260, 280, 292), 10, 170, fill="#754C42", width=5)
    save(name, portrait)


def table(pen):
    pen.rounded_rectangle((16, 16, 496, 496), radius=94, fill="#3A6A96")
    pen.rounded_rectangle((95, 204, 417, 292), radius=18, fill="#D2691E")
    pen.rectangle((124, 287, 150, 422), fill="#D2691E")
    pen.rectangle((362, 287, 388, 422), fill="#D2691E")
    pen.rounded_rectangle((170, 90, 342, 200), radius=24, fill="#F0D28B")
    pen.rectangle((192, 195, 213, 260), fill="#F0D28B")
    pen.rectangle((299, 195, 320, 260), fill="#F0D28B")


save("demo-table.png", table)


def prize_card(pen):
    pen.rounded_rectangle((16, 16, 496, 496), radius=94, fill="#3A6A96")
    pen.rounded_rectangle((91, 149, 421, 366), radius=35, fill="#F4D18B")
    pen.rectangle((91, 214, 421, 250), fill="#D2691E")
    pen.ellipse((291, 278, 365, 344), fill="#D2691E")


def headphones(pen):
    pen.rounded_rectangle((16, 16, 496, 496), radius=94, fill="#715E9D")
    pen.arc((121, 85, 391, 397), 180, 360, fill="#F4D18B", width=40)
    pen.rounded_rectangle((92, 250, 163, 386), radius=25, fill="#D2691E")
    pen.rounded_rectangle((349, 250, 420, 386), radius=25, fill="#D2691E")


def lamp(pen):
    pen.rounded_rectangle((16, 16, 496, 496), radius=94, fill="#2E7D75")
    pen.polygon([(126, 156), (386, 156), (342, 286), (170, 286)], fill="#F4D18B")
    pen.rectangle((244, 285, 268, 401), fill="#D2691E")
    pen.rounded_rectangle((171, 395, 341, 427), radius=15, fill="#D2691E")


def cup(pen):
    pen.rounded_rectangle((16, 16, 496, 496), radius=94, fill="#A3526C")
    pen.rounded_rectangle((144, 115, 355, 415), radius=28, fill="#F4D18B")
    pen.rounded_rectangle((130, 96, 369, 144), radius=18, fill="#D2691E")
    pen.rectangle((160, 235, 339, 274), fill="#D2691E")


for name, drawing in [
    ("demo-prize-card.png", prize_card),
    ("demo-prize-headphones.png", headphones),
    ("demo-prize-lamp.png", lamp),
    ("demo-prize-cup.png", cup),
]:
    save(name, drawing)

print("Created 9 original demo images for Windows and macOS")
