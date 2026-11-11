#!/bin/sh
# Writes data/<model>.gguf from what fetch-data.sh downloaded: the Model2Vec
# models (token table as Q8_0, plus the tokenizer) with m2vgguf/, SigLIP 2's
# vision tower (matrices as Q8_0) with siggguf/.
set -eu
cd "$(dirname "$0")"
dune build --profile release ./m2vgguf/m2vgguf.exe ./siggguf/siggguf.exe
for model in potion-base-32M potion-multilingual-128M; do
  ./_build/default/m2vgguf/m2vgguf.exe --name "$model" -o "data/$model.gguf" \
    --tokenizer "data/$model.tokenizer.json" --model "data/$model.model.safetensors" --config "data/$model.config.json"
done
./_build/default/siggguf/siggguf.exe --model data/siglip2-base-patch16-naflex.model.safetensors \
  -o data/siglip2-base-patch16-naflex.gguf
