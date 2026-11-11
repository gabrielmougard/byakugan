#!/usr/bin/env bash
# Build the Placement Lab images on this machine, push them to the registry
# running in the cluster, and install the Helm charts.
#
#   deploy/deploy.sh            # everything
#   TAG=x deploy/deploy.sh      # choose the image tag
#
# Images are linux/arm64, what the cluster's nodes run; on Apple silicon they
# build natively.

set -euo pipefail
cd "$(dirname "$0")/.."

CONTEXT=${KUBE_CONTEXT:-pi}
REGISTRY_NODE=${REGISTRY_NODE:-10.5.16.101} # any node: the registry is a NodePort
REGISTRY_PORT=30500
PUSH=$REGISTRY_NODE:$REGISTRY_PORT # how this machine reaches the registry
BUILDER=contextual

# The commit, plus a timestamp when src/ has uncommitted changes, so a node
# never runs a stale image cached under the same tag.
TAG=${TAG:-$(git rev-parse --short HEAD)$([ -z "$(git status --porcelain src)" ] || echo "-dirty-$(date +%s)")}

kube() { kubectl --context "$CONTEXT" "$@"; }
chart() { helm --kube-context "$CONTEXT" upgrade --install "$@" --wait --timeout 5m; }

echo "== registry"
chart registry deploy/registry --namespace registry --create-namespace

echo "== builder ($BUILDER), allowed to push over plain HTTP to $PUSH"
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  config=$(mktemp)
  printf '[registry."%s"]\n  http = true\n  insecure = true\n' "$PUSH" >"$config"
  docker buildx create --name "$BUILDER" --driver docker-container --config "$config"
  rm -f "$config"
fi

# The taxonomy and model sources go in from src/data, never downloaded by the
# build: Hugging Face throttles anonymous downloads per IP.
for f in content_taxonomy_3.1.tsv siglip2-base-patch16-naflex.model.safetensors \
  potion-{base-32M,multilingual-128M}.{model.safetensors,tokenizer.json,config.json}; do
  [ -f "src/data/$f" ] || { echo "src/data/$f is missing: run src/fetch-data.sh --from-source once" >&2; exit 1; }
done

for target in crawler online; do
  echo "== image $target:$TAG"
  docker buildx build --builder "$BUILDER" --platform linux/arm64 --target "$target" \
    --build-context models=src/data \
    --tag "$PUSH/contextual/$target:$TAG" --push src
done

echo "== OpenRouter key"
kube create namespace contextual --dry-run=client -o yaml | kube apply -f - >/dev/null
llm=()
if [ -f src/.env ]; then
  kube -n contextual create secret generic openrouter --from-env-file=src/.env \
    --dry-run=client -o yaml | kube apply -f - >/dev/null
else
  echo "no src/.env: deploying without T4"
  llm=(--set crawler.llmModel=)
fi

echo "== contextual"
# ${llm[@]+...}: macOS ships bash 3.2, where an empty array trips set -u.
chart contextual deploy/contextual --namespace contextual --set image.tag="$TAG" ${llm[@]+"${llm[@]}"}
