"""The taxonomy's SigLIP 2 text embeddings, for zero-shot image labels.

    python siglip_prototypes.py HF_SNAPSHOT_DIR TAXONOMY_TSV OUT_GGUF

HF_SNAPSHOT_DIR holds google/siglip2-base-patch16-naflex at revision b53b807d,
the one src/fetch-data.sh downloads (config, tokenizer, model.safetensors).
For each node of IAB Content Taxonomy 3.1, a few prompts are embedded with
the text tower and their normalised mean kept: the C runtime only needs the
vision tower, and these rows change only with the taxonomy or the prompts.
Writes a GGUF with "siglip2.labels" (node ids) and a "prototypes" tensor
(f16, one row per id); src/data/siglip2_prototypes.gguf is committed."""
import sys

import gguf
import numpy as np
import torch
from transformers import AutoModel, AutoProcessor

REVISION = "b53b807d3a2d5e2b3911292f2d69e5341cdc064c"
TEMPLATES = ["This is a photo of {}.", "a photo about {}.", "an image related to {}."]


def nodes(path):
    rows = [line.rstrip("\n").split("\t") for line in open(path, encoding="utf-8")][2:]
    names = {r[0].strip(): r[2].strip() for r in rows if len(r) > 2 and r[0].strip()}
    parents = {r[0].strip(): r[1].strip() for r in rows if len(r) > 2 and r[0].strip()}
    out = []
    for node, name in names.items():
        parent = names.get(parents[node])
        out.append((node, f"{name} ({parent})" if parent else name))
    return out


def main():
    snapshot, taxonomy, out = sys.argv[1:4]
    model = AutoModel.from_pretrained(snapshot).eval()
    processor = AutoProcessor.from_pretrained(snapshot)
    labels = nodes(taxonomy)
    rows = []
    for node, text in labels:
        prompts = [t.format(text) for t in TEMPLATES]
        inputs = processor(text=prompts, padding="max_length", max_length=64, return_tensors="pt")
        with torch.no_grad():
            e = model.get_text_features(**inputs)
        e = getattr(e, "pooler_output", e)
        e = e / e.norm(dim=-1, keepdim=True)
        m = e.mean(dim=0)
        rows.append((m / m.norm()).numpy())
    w = gguf.GGUFWriter(out, "siglip2")
    w.add_string("general.name", "siglip2-base-patch16-naflex text prototypes")
    w.add_string("siglip2.revision", REVISION)
    w.add_array("siglip2.templates", TEMPLATES)
    w.add_array("siglip2.labels", [node for node, _ in labels])
    w.add_tensor("prototypes", np.stack(rows).astype(np.float16))
    w.write_header_to_file()
    w.write_kv_data_to_file()
    w.write_tensors_to_file()
    w.close()
    print(f"{out}: {len(rows)} nodes x {rows[0].shape[0]}", file=sys.stderr)


main()
