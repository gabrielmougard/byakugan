#!/bin/sh
# Fills src/data with what the engine loads and git does not keep: two
# Model2Vec models (minishlab, MIT), potion-base-32M for English pages and
# potion-multilingual-128M for the rest, and SigLIP 2's vision tower (Google,
# Apache-2.0). Licences and changes: data/NOTICE.
#
#   fetch-data.sh                the three GGUF files the engine loads
#   fetch-data.sh --from-source  the published originals (safetensors and
#                                JSON), for convert-models.sh and the Docker
#                                build, which converts them itself
#
# Every file comes from the GitHub release $BYAKUGAN_MODELS_TAG (default
# models-v1), else from Hugging Face at a pinned revision, and is checked
# against its SHA-256 below. A GGUF missing from the release makes the default
# fall back to --from-source.
set -eu
cd "$(dirname "$0")/data"

repo=gabrielmougard/byakugan
tag=${BYAKUGAN_MODELS_TAG:-models-v1}
hf=https://huggingface.co
base32=minishlab/potion-base-32M/resolve/1e5a03f8eeb2c98b928fbbd846f22f816360919f
multi=minishlab/potion-multilingual-128M/resolve/73908c3438cf03b6a01bcb9611d62b23d0726f08
siglip=google/siglip2-base-patch16-naflex/resolve/b53b807d3a2d5e2b3911292f2d69e5341cdc064c

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# The release's copy of FILE into FILE.part: anonymously, else through an
# authenticated gh while the repository is private.
from_release() {
  curl -fsSL -o "$1.part" "https://github.com/$repo/releases/download/$tag/$1" 2>/dev/null ||
    { command -v gh >/dev/null 2>&1 &&
      gh release download "$tag" -R "$repo" -p "$1" -O "$1.part" --clobber 2>/dev/null; }
}

# get SUM FILE [HF_PATH]: the release's copy, else Hugging Face's; fails
# without leaving a partial file if neither has it.
get() {
  if [ -f "$2" ] && [ "$(sha256 "$2")" = "$1" ]; then
    echo "$2: up to date"
    return 0
  fi
  if ! from_release "$2"; then
    [ -n "${3:-}" ] && curl -fL -o "$2.part" "$hf/$3" || { rm -f "$2.part"; return 1; }
  fi
  if [ "$(sha256 "$2.part")" != "$1" ]; then
    rm -f "$2.part"
    echo "$2: checksum mismatch" >&2
    exit 1
  fi
  mv "$2.part" "$2"
  echo "$2: fetched"
}

ggufs() {
  get 38abd74ec76ed03c14832e10cd18e76e89def7793881b80b75378802857353cb potion-base-32M.gguf &&
  get a9ca5e907272ddcf498776e33dcc3a202b5d6fe8c9dbc6371b92dc2979981d48 potion-multilingual-128M.gguf &&
  get 5ccc2f54231775b7ae9003edaac5d60f68f5c74739d4750434cf0e8613d8fc20 siglip2-base-patch16-naflex.gguf
}

sources() {
  get 99f6c33204c9231a7391871b7a3c91409b532c8f587a9ea44fc282303d8dec28 potion-base-32M.model.safetensors "$base32/model.safetensors"
  get 7d75cbc54318138807c401b0f0c9721117c628b39de8e8e0edb6cb17e0ee7d18 potion-base-32M.tokenizer.json "$base32/tokenizer.json"
  get 63c00d90824c832c04ec1d02b6a983fb90489bf049f29fbff15ba481b8a432ee potion-base-32M.config.json "$base32/config.json"
  get 14b5eb39cb4ce5666da8ad1f3dc6be4346e9b2d601c073302fa0a31bf7943397 potion-multilingual-128M.model.safetensors "$multi/model.safetensors"
  get 19f1909063da3cfe3bd83a782381f040dccea475f4816de11116444a73e1b6a1 potion-multilingual-128M.tokenizer.json "$multi/tokenizer.json"
  get 595e4cab2093732efd5dbe084fd5c1826b5eea693b73b4c1fd971672867d2e54 potion-multilingual-128M.config.json "$multi/config.json"
  # data/siglip2_prototypes.gguf holds this revision's text embeddings.
  get ac5f28bbdf92c0c1696ccbd3ce716426049cd67ad8045b66d0d938b0f9c8bbec siglip2-base-patch16-naflex.model.safetensors "$siglip/model.safetensors"
}

case "${1:-}" in
  "") ggufs || {
        echo "GGUF files not in the release: fetching the originals; then run src/convert-models.sh" >&2
        sources
      } ;;
  --from-source) sources ;;
  *) echo "usage: $0 [--from-source]" >&2; exit 2 ;;
esac
