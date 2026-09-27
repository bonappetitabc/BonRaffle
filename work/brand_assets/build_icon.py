"""Build Windows icon formats from the user's unchanged Bon Raffle images."""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "work" / "bonraffle_winui" / "Assets"
icon_source = ASSETS / "ApplIcation-bon-raffle.png"

icon = Image.open(icon_source).convert("RGBA")
icon.save(
    ASSETS / "AppIcon.ico", format="ICO",
    sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
           (64, 64), (128, 128), (256, 256)],
)

for filename, size in {
    "Square150x150Logo.scale-200.png": (300, 300),
    "Square44x44Logo.scale-200.png": (88, 88),
    "Square44x44Logo.targetsize-24_altform-unplated.png": (24, 24),
    "Square44x44Logo.targetsize-48_altform-lightunplated.png": (48, 48),
    "StoreLogo.png": (100, 100),
    "LockScreenLogo.scale-200.png": (48, 48),
}.items():
    icon.resize(size, Image.Resampling.LANCZOS).save(ASSETS / filename)

print(f"Built Windows icons from {icon_source.name}")
