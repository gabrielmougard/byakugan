#!/bin/sh
# Fills src/data with what the engine loads and git does not keep: the GGUF
# files of two Model2Vec models (minishlab, MIT), potion-base-32M for English
# pages and potion-multilingual-128M for the rest, and of SigLIP 2's vision
# tower (Google, Apache-2.0). Licences and changes: data/NOTICE.
#
#   fetch-data.sh                the GGUF files from the GitHub release
#                                $BYAKUGAN_MODELS_TAG (default models-v1),
#                                checked against the sums below
#   fetch-data.sh --from-source  the published originals from Hugging Face,
#                                for convert-models.sh and the Docker build
#
# Without the release, the default falls back to --from-source.
set -eu
cd "$(dirname "$0")/data"

repo=https://github.com/gabrielmougard/byakugan
tag=${BYAKUGAN_MODELS_TAG:-models-v1}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

from_release() {
  while read -r sum f; do
    if [ -f "$f" ] && [ "$(sha256 "$f")" = "$sum" ]; then
      echo "$f: up to date"
      continue
    fi
    curl -fL -o "$f.part" "$repo/releases/download/$tag/$f" || { rm -f "$f.part"; return 1; }
    if [ "$(sha256 "$f.part")" != "$sum" ]; then
      rm -f "$f.part"
      echo "$f: checksum mismatch in release $tag" >&2
      exit 1
    fi
    mv "$f.part" "$f"
  done <<EOF
38abd74ec76ed03c14832e10cd18e76e89def7793881b80b75378802857353cb potion-base-32M.gguf
a9ca5e907272ddcf498776e33dcc3a202b5d6fe8c9dbc6371b92dc2979981d48 potion-multilingual-128M.gguf
5ccc2f54231775b7ae9003edaac5d60f68f5c74739d4750434cf0e8613d8fc20 siglip2-base-patch16-naflex.gguf
EOF
}

from_source() {
  for model in potion-base-32M potion-multilingual-128M; do
    for f in model.safetensors tokenizer.json config.json; do
      curl -fL -o "$model.$f" "https://huggingface.co/minishlab/$model/resolve/main/$f"
    done
  done
  # Pinned: data/siglip2_prototypes.gguf holds this revision's text embeddings.
  siglip=https://huggingface.co/google/siglip2-base-patch16-naflex/resolve/b53b807d3a2d5e2b3911292f2d69e5341cdc064c
  curl -fL -o siglip2-base-patch16-naflex.model.safetensors "$siglip/model.safetensors"
  echo "now run src/convert-models.sh to write the GGUF files" >&2
}

case "${1:-}" in
  "") from_release || { echo "no release $tag at $repo: downloading the sources instead" >&2; from_source; } ;;
  --from-source) from_source ;;
  *) echo "usage: $0 [--from-source]" >&2; exit 2 ;;
esac
