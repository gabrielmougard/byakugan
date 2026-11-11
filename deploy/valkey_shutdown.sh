#!/usr/bin/env bash
# Does Valkey keep its data across a staggered full shutdown? On a local kind
# cluster with three workers, one per Valkey pod, the chart's Valkey only:
#   deploy/valkey_shutdown.sh a   # valkey-0 is a replica and its node stops first
#   deploy/valkey_shutdown.sh b   # valkey-0 is the primary and its node stops first
# Writes keys, stops valkey-0's node, writes more on the primary, stops every
# node, starts them again, and fails if the later keys are gone. Needs kind,
# helm, docker. KIND_IMAGE / VALKEY_IMAGE override the images (a mirror when
# Docker Hub is unreachable).
set -u
cd "$(dirname "$0")/.."
scenario=${1:-a}
name=valkey-shutdown
C=kind-$name
kk() { kubectl --context $C -n contextual "$@"; }
cli() { local pod=$1; shift; kk exec "$pod" -c valkey -- valkey-cli --tls --cacert /tls/ca.crt --no-auth-warning "$@" 2>/dev/null; }
sentinel() { kk exec "$1" -c sentinel -- valkey-cli --tls --cacert /tls/ca.crt --no-auth-warning -p 26379 "${@:2}" 2>/dev/null; }
primary() { for i in 0 1 2; do p=$(sentinel valkey-$i --raw SENTINEL get-master-addr-by-name contextual | head -1); [ -n "$p" ] && { echo "${p%%.*}"; return; }; done; }
count() { cli "$1" EVAL "return #redis.call('KEYS', ARGV[1])" 0 "$2*"; }
write() { cli "$1" EVAL "for i=1,1000 do redis.call('SET', ARGV[1]..i, i) end return 1" 0 "$2" >/dev/null; }
report() { for i in 0 1 2; do echo "  valkey-$i $(cli valkey-$i ROLE | head -1) before=$(count valkey-$i "a$R:") after=$(count valkey-$i "b$R:")"; done; }
ready() { for _ in $(seq 1 120); do [ "$(kk get pods --no-headers 2>/dev/null | awk '$2=="2/2"' | wc -l)" -eq 3 ] && return; sleep 5; done; }

if ! kind get clusters | grep -qx $name; then
  printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes: [{role: control-plane}, {role: worker}, {role: worker}, {role: worker}]\n' |
    kind create cluster --name $name ${KIND_IMAGE:+--image "$KIND_IMAGE"} --config -
  kubectl --context $C create namespace contextual
fi
# Outside Helm the chart's lookup finds nothing, so it would make a new
# password and CA: the Secrets are applied only the first time.
keep=$(kk get secret valkey-auth >/dev/null 2>&1 && echo 1 || echo 0)
helm template contextual deploy/contextual -n contextual -s templates/valkey.yaml \
  --set valkey.storage.storageClass=standard ${VALKEY_IMAGE:+--set valkey.image="$VALKEY_IMAGE"} |
  python3 -c 'import sys; keep = sys.argv[1] == "1"; print("\n---\n".join(d for d in sys.stdin.read().split("\n---\n") if not (keep and "\nkind: Secret\n" in d)))' "$keep" |
  kk apply -f - >/dev/null
kk rollout status statefulset/valkey --timeout=10m >/dev/null; ready; sleep 15

R=$RANDOM
want=$([ "$scenario" = b ] && echo valkey-0)
for _ in $(seq 1 8); do # a: the primary must not be valkey-0; b: it must be
  p=$(primary)
  { [ "$scenario" = b ] && [ "$p" = valkey-0 ]; } || { [ "$scenario" != b ] && [ "$p" != valkey-0 ]; } && break
  sentinel valkey-0 SENTINEL FAILOVER contextual >/dev/null; sleep 12
done
P=$(primary); echo "scenario $scenario, primary $P"; write "$P" "a$R:"
node=$(kk get pod valkey-0 -o jsonpath='{.spec.nodeName}'); echo "stopping $node, valkey-0's node"; docker stop "$node" >/dev/null
for _ in $(seq 1 60); do P=$(primary); [ -n "$P" ] && [ "$P" != valkey-0 ] && [ "$(cli "$P" ROLE | head -1)" = master ] && break; sleep 2; done
[ "$P" = valkey-0 ] && { echo "no failover without valkey-0: nothing to test"; exit 2; }
write "$P" "b$R:"; cli "$P" WAIT 1 5000 >/dev/null; echo "wrote on $P:"; report
echo "stopping every node, then starting them"; docker stop $(docker ps --filter "name=$name-" --format '{{.Names}}') >/dev/null
docker start $name-control-plane >/dev/null; sleep 10; docker start $(docker ps -a --filter "name=$name-worker" --format '{{.Names}}') >/dev/null
ready; sleep 60 # Sentinel turns a stale primary into a replica within about 30 s
P=$(primary); echo "after the restart, primary $P:"; report
[ "$(count "$P" "b$R:")" = 1000 ] && echo "kept" || { echo "LOST the keys written after valkey-0's node stopped"; exit 1; }
