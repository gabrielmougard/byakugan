"""Expected SigLIP 2 image embeddings from Hugging Face, for src/test/test_siglip.ml.

    python siglip_fixtures.py HF_SNAPSHOT_DIR IMAGES_DIR OUT_TSV [PIXELS_DIR]

HF_SNAPSHOT_DIR holds google/siglip2-base-patch16-naflex at revision
b53b807d (config, preprocessor config, model.safetensors). IMAGES_DIR holds
three CC0 photos from Wikimedia Commons (soccer.jpg, car.jpg, pasta.jpg); the
first run also derives the other formats and shapes the C decoder and
preprocessing must handle. Writes name<TAB>n_h<TAB>n_w<TAB>embedding per
image (L2-normalised, as the C runtime returns it). With PIXELS_DIR, also
saves each image's pixel values as .npy, to debug the preprocessing."""
import os
import sys

import numpy as np
import torch
from PIL import Image
from transformers import AutoModel, AutoProcessor


def derive(images):
    pasta = Image.open(os.path.join(images, "pasta.jpg")).convert("RGB")
    car = Image.open(os.path.join(images, "car.jpg")).convert("RGB")
    soccer = Image.open(os.path.join(images, "soccer.jpg")).convert("RGB")
    out = {
        "pasta_alpha.png": lambda p: _alpha(pasta.resize((200, 144))).save(p),
        "car.webp": lambda p: car.save(p, quality=80),
        "soccer_gray.jpg": lambda p: soccer.convert("L").save(p, quality=90),
        "tiny.jpg": lambda p: pasta.resize((40, 29)).save(p, quality=90),
        "panorama.jpg": lambda p: soccer.crop((0, 150, 500, 210)).save(p, quality=90),
    }
    for name, save in out.items():
        path = os.path.join(images, name)
        if not os.path.exists(path):
            save(path)


def _alpha(img):
    rgba = img.convert("RGBA")
    a = np.tile(np.linspace(0, 255, img.width, dtype=np.uint8), (img.height, 1))
    rgba.putalpha(Image.fromarray(a))
    return rgba


def main():
    snapshot, images, out = sys.argv[1:4]
    pixels_dir = sys.argv[4] if len(sys.argv) > 4 else None
    derive(images)
    model = AutoModel.from_pretrained(snapshot).eval()
    processor = AutoProcessor.from_pretrained(snapshot)
    with open(out, "w") as f:
        for name in sorted(n for n in os.listdir(images) if n.endswith((".jpg", ".png", ".webp"))):
            img = Image.open(os.path.join(images, name)).convert("RGB")
            inputs = processor(images=[img], return_tensors="pt", max_num_patches=256)
            n_h, n_w = (int(x) for x in inputs["spatial_shapes"][0])
            with torch.no_grad():
                e = model.get_image_features(**inputs)
            e = getattr(e, "pooler_output", e)[0]
            e = (e / e.norm()).numpy()
            f.write(f"{name}\t{n_h}\t{n_w}\t{','.join(f'{x:.6f}' for x in e)}\n")
            if pixels_dir:
                np.save(os.path.join(pixels_dir, name + ".npy"), inputs["pixel_values"][0, : n_h * n_w].numpy())
            print(name, n_h, n_w, file=sys.stderr)


main()
