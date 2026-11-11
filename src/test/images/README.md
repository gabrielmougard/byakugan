Test images for `src/test/test_siglip.ml`. Three photos from Wikimedia Commons,
all CC0 (public domain dedication), as the 500 px thumbnails Commons serves:

- `soccer.jpg`: File:2021-08-21 - FIFA Beach Soccer World Cup - Match 11 - Tahiti v Spain - Photo 011.jpg
- `car.jpg`: File:Avenue Roosevelt à Bruxelles, Zen Car en recharge.jpg
- `pasta.jpg`: File:Pasta alla Norma - Wiki Loves Sicilia.jpg

The other five are derived from them by `src/stubs/tools/siglip_fixtures.py`
(other formats and shapes the decoders and preprocessing must handle):
`car.webp`, `pasta_alpha.png` (RGBA), `soccer_gray.jpg`, `tiny.jpg` (40×29,
upscaled) and `panorama.jpg` (500×60).
