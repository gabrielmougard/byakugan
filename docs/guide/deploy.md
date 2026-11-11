---
slug: /guide/deploy
sidebar_label: Deploy to the Pi cluster
---

# Deploy to the Pi cluster

The `pi` cluster is k3s on three Raspberry Pi 4 boards (8 GB each, Debian 13, arm64). It runs:
- the Placement Lab: 3 crawler and 2 online replicas, sharing state through Valkey;
- a small registry, so the nodes can pull images built on a workstation.

```bash
deploy/deploy.sh
```

That one command does the following, in order:
1. Installs the `registry` chart (namespace `registry`).
2. Creates a buildx builder named `contextual` that may push to that registry over plain HTTP. It is created once, and leaves Docker Desktop's own settings untouched.
3. Builds the `crawler` and `online` images from `src/Dockerfile` and pushes them, tagged with the git commit. If `src/` has uncommitted changes, the tag also gets `-dirty-<time>`.
4. Creates the `openrouter` Secret from `src/.env`. Without that file, the crawler runs without T4.
5. Installs the `contextual` chart (namespace `contextual`) with that tag.

Then open `http://<any node IP>/`, for example `http://10.5.16.101/`.

| Variable | Default | Meaning |
|---|---|---|
| `KUBE_CONTEXT` | `pi` | kubectl / helm context |
| `REGISTRY_NODE` | `10.5.16.101` | the node IP this machine pushes to (any node works). If you change it, run `docker buildx rm contextual` first so the builder is recreated for the new address |
| `TAG` | git commit | image tag |

## Images

`src/Dockerfile` has one build stage and two targets, `crawler` and `online`.

**Build stage** (`ocaml/opam:debian-13-ocaml-5.5`):
- installs the exact opam versions of the development switch, plus Node for the front-end bundle;
- copies the taxonomy and the model sources from this machine's `src/data/` (`--build-context models=src/data`), which `fetch-data.sh --from-source` filled once: a build never downloads them, so Hugging Face's per-IP limit on anonymous downloads cannot fail it. `deploy.sh` stops early if a file is missing;
- builds in release mode;
- installs a pinned Rust toolchain (1.95.0, rustup) for FastWARC: its crates are vendored (`src/vendor/rust`), so the build itself fetches no crate;
- runs the test suite, so a failing test stops the image;
- bundles the front end.

**Runtime images** (`debian:trixie-slim`):
- each holds one binary, `src/data/`, and, for `online`, the front end;
- they run as uid 10001 with a read-only root filesystem.

Docker on Apple silicon builds `linux/arm64` natively, the Pi 4's architecture (Cortex-A72, ARMv8-A). Nothing is compiled with `-march=native`, so binaries built on an M-series Mac run on the Pis unchanged.

## How the nodes pull images

The `registry` chart runs `registry:3` with a 10 Gi local-path volume, behind a NodePort, 30500, that exists on every node.

| Who | Address used | Why it works over plain HTTP |
|---|---|---|
| This machine (push) | `10.5.16.101:30500` | the buildx builder's config marks that address as HTTP |
| Each node's containerd (pull) | `localhost:30500` | containerd treats `localhost` registries as HTTP by default, so the nodes need no `registries.yaml` |

Verified on 2026-11-05: a test image pushed from the Mac was pulled from `localhost:30500` on pi01, pi02 and pi03.

```bash
curl http://10.5.16.101:30500/v2/_catalog                       # what is in the registry
curl http://10.5.16.101:30500/v2/contextual/crawler/tags/list
```

## What runs

| Object | Namespace | Notes |
|---|---|---|
| `registry` Deployment, Service (NodePort 30500), PVC | `registry` | |
| `valkey` StatefulSet (3 pods, Valkey + Sentinel each), `valkey-headless`, `valkey-sentinel` Services, a 4 Gi local-path volume per pod | `contextual` | one pod per Pi; see below |
| `crawler` StatefulSet (3 replicas, `crawler-N`), Services `crawler` :8081 and `crawler-headless`, a 10 Gi local-path volume per pod for its WARC files | `contextual` | `--llm` and the key come from chart values and the Secret; the online server reaches the replica holding a page's record as `crawler-N.crawler-headless` |
| `online` Deployment (2 replicas), Service :8080, Ingress | `contextual` | Traefik routes every host on port 80 to it (`online.ingress.host` narrows that) |

Chart values are in `deploy/contextual/values.yaml`. Override them with `--set`, as `deploy.sh` does for `image.tag`.

```bash
kubectl --context pi -n contextual get pods -o wide
kubectl --context pi -n contextual logs deploy/crawler
helm --kube-context pi -n contextual history contextual
```

## Throughput on the Pis

Measured 2026-11-09 with the chart's defaults (3 crawler replicas × 4 workers, T4 off, SigLIP 2 at 128 patches) on 3,198 pages, 274 hosts: **1.9 pages/s** end to end (about 160,000 a day), 78% stored, in 28 minutes.

The image tier alone, on pi01: 3.46 s per image at 128 patches on one thread (what the crawler uses per image) and 0.94 s with four. The crawler image carries `image_bench`; its `/dev/shm` is the writable place in the pod:

```bash
kubectl --context pi -n contextual cp src/test/images/soccer.jpg <crawler-pod>:/dev/shm/ -c crawler
kubectl --context pi -n contextual exec <crawler-pod> -c crawler -- image_bench --data /app/data --time /dev/shm/soccer.jpg
```

## Valkey: shared state for every replica

[Valkey](https://valkey.io) (BSD-licensed, Redis-compatible) holds everything the crawler and online replicas share. The key layout and scripts are in `src/serve/lab.ml`.

| What | Keys | Why it lets replicas cooperate |
|---|---|---|
| Frontier | `ctx:frontier:<origin>` (one queue per origin, busiest page first), `ctx:hosts` (when each origin may be fetched next) | a worker claims, in one Lua script, the due origin whose next page has the most bid-log traffic, and that page, so two replicas never fetch the same URL or the same origin at once |
| Politeness | `ctx:hosts` scores | after each fetch the origin becomes due again only after max(1 s, Crawl-delay), whichever replica fetched it |
| Seen-set | `ctx:seen` | a URL is queued once, cluster-wide (`"force": true` re-queues) |
| Claims | `ctx:inflight` | a claim older than 2 minutes belongs to a crawler that died; any replica's housekeeping puts it back in the queue |
| Profiles | `ctx:profile:<key>` (zstd), `ctx:profiles`, `ctx:summary` | the online replicas read new or re-crawled profiles every 3 s |
| Serving profiles | `contextual:<sha256>` (protobuf, 30 days) | what the bidder would read, keyed by its own URL normalisation ([Code map](code-map.md#the-serving-profile)) |
| Caches | `ctx:robots:<origin>` (24 h), `ctx:license:<url>` (the license's max-age, default 30 days) | one fetch serves every replica |
| Stats | `ctx:stats`, `ctx:recent`, `ctx:replicas`, `ctx:crawled_by` | `/crawler/status` gives the same answer from any replica, including which replicas are alive and what each crawled |

**High availability.**
- Each `valkey` pod runs Valkey plus a Sentinel. On a first start `valkey-0` is the primary and the others replicate from it.
- When the primary has been unreachable for 5 s, two Sentinels agree and promote a replica.
- A pod that restarts asks the Sentinels who the primary is, and comes back as its replica.
- Each Sentinel keeps its config, which it rewrites on every failover, on the pod's data volume (`/data/sentinel`). After a full shutdown no Sentinel answers yet, so a pod takes the primary its own Sentinel last knew. Falling back to `valkey-0`, as before 2026-11-11, lost data: after a staggered shutdown `valkey-0` may hold the oldest copy, and the others resynced from it. `deploy/valkey_shutdown.sh a|b` replays both orders on a local kind cluster.
- The crawler and online server connect through Sentinel (`sentinel://valkey-sentinel:26379/contextual`). They re-resolve the primary when a connection breaks or the server answers `READONLY`.
- Valkey runs with append-only persistence and `noeviction`, so the frontier is never evicted.

**Tested on 2026-11-05:**
- 3 crawler replicas crawled 15 pages from 3 sites: each page once, and per-origin fetches stayed at least 1.07 s apart across the Pis.
- Deleting the primary mid-crawl: Sentinel promoted `valkey-2` within about 10 s, the crawl finished with nothing lost, and `valkey-0` rejoined as a replica.

```bash
kubectl --context pi -n contextual exec valkey-1 -c sentinel -- valkey-cli -p 26379 SENTINEL get-master-addr-by-name contextual
kubectl --context pi -n contextual exec valkey-0 -c valkey -- valkey-cli info replication
curl -s http://10.5.16.101/crawler/status | jq .replicas
```

### Password and TLS

Every connection to Valkey and Sentinel uses TLS and the password, including replication and Sentinel-to-Sentinel traffic.
- **First install.** The chart generates the password (`valkey-auth`) and a CA with one server certificate (`valkey-tls`, valid 10 years). Upgrades keep both; `helm uninstall` leaves them (`helm.sh/resource-policy: keep`).
- **The certificate** covers `valkey-sentinel`, `*.valkey-headless.<namespace>.svc.cluster.local` and `localhost`. Clients verify it against the CA.
- **Valkey and Sentinel** listen on TLS only (`port 0`). A plain connection, or a wrong password, is refused.
- **The crawler and online pods** get `VALKEY_PASSWORD` and `VALKEY_CA_CERT` ([Configuration](configuration.md#valkey-connection-environment)).

```bash
kubectl --context pi -n contextual exec valkey-0 -c valkey -- valkey-cli --tls --cacert /tls/ca.crt info replication
```

`REDISCLI_AUTH` in the containers holds the password, so `valkey-cli` needs no `-a`.

**Switching an existing release to TLS.** In a rolling update, the old and new pods cannot talk to each other: one side speaks TLS, the other does not. After `helm upgrade`, restart all three pods at once:

```bash
kubectl --context pi -n contextual delete pod valkey-0 valkey-1 valkey-2
```

They come back in order. valkey-0 finds no Sentinel and starts as the primary with its data on disk; the others replicate from it.

## Bid-log traffic: what to crawl, and what it covers

Three scripts take pages from your own bid logs and talk to the crawler (`CRAWLER`, default `http://localhost:8081`, or the online server's proxy at `/crawler`). Each `.example` script is a template: copy it without `.example` (the copy is gitignored) and write its one function against your logs, whatever stores them. The script documents the lines that function must print.

| Script | What it does |
|---|---|
| `deploy/traffic.example.sh` | queues the pages with the most bid requests, busiest first: `pages()` prints `url<TAB>requests per day` lines |
| `deploy/coverage.example.sh` | the share of a day's impressions on pages with a stored profile: `pages()` prints `url<TAB>impressions` lines, `total()` the day's impressions |
| `deploy/golden.example.sh > sample.tsv` | a golden-set sample, one URL per line. Queue it with `curl --data-binary @sample.tsv $CRAWLER/traffic`, on a crawler started with `--audit` so the `deep` level the golden report reads is stored |

Section and site profiles are kept up to date as pages are saved. Pages stored before they existed are added once with `curl -X POST $CRAWLER/sections`.
