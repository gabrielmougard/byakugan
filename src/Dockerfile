# syntax=docker/dockerfile:1
# The Placement Lab's two services, from one build stage:
#   docker build --target crawler --build-context models=src/data -t contextual/crawler src
#   docker build --target online  --build-context models=src/data -t contextual/online  src
# The taxonomy and the model sources come from the "models" context, the
# src/data that fetch-data.sh --from-source filled once: a build never downloads them.
# The image's architecture is the build host's (linux/arm64 on Apple silicon).
# deploy/deploy.sh builds, pushes and deploys both.

FROM ocaml/opam:debian-13-ocaml-5.5 AS build
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends libcurl4-gnutls-dev libzstd-dev libgmp-dev protobuf-compiler libprotobuf-dev \
      cmake pkg-config g++ nodejs npm curl ca-certificates libturbojpeg0-dev libpng-dev libwebp-dev \
 && rm -rf /var/lib/apt/lists/*
USER opam
# Rust for FastWARC (stubs/warc_ffi, crates vendored in vendor/rust): the
# crates need 1.89, Debian 13 ships 1.85. Pinned to the toolchain they were
# vendored and tested with.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --default-toolchain 1.95.0
ENV PATH=/home/opam/.cargo/bin:$PATH
# The versions the development switch builds and tests with.
RUN opam install -y \
      dune.3.24.2 re.1.14.0 yojson.3.0.0 uri.4.4.0 domainslib.0.5.2 lwt.6.1.2 \
      cohttp-lwt-unix.6.3.0 curl.0.10.0 curl_lwt.0.10.0 digestif.1.3.1 ocaml-protoc-plugin.6.3.0 \
      tls-lwt.2.1.3 x509.1.2.0 mirage-crypto-rng.2.4.1 ptime.1.2.0 domain-name.0.5.0 \
      melange.7.0.1-55 reason.3.18.0 reason-react.0.17.0 reason-react-ppx.0.17.0
WORKDIR /home/opam/src
# The taxonomy and the three models (about 2.1 GB): a layer of their own, so a
# source change does not copy them again. .dockerignore keeps them out of the
# main build context.
COPY --chown=opam:opam --from=models / data/
COPY --chown=opam:opam frontend/package.json frontend/package-lock.json frontend/
RUN npm --prefix frontend ci --no-audit --no-fund
COPY --chown=opam:opam . .
# The models become GGUF with the converters just built; the tests then check
# them against Hugging Face (token ids, image embeddings).
RUN opam exec -- dune build --profile release @default @frontend \
 && opam exec -- ./convert-models.sh \
 && opam exec -- dune test --profile release \
 && npm --prefix frontend run build

FROM debian:trixie-slim AS runtime
# netbase: /etc/services, which Cohttp's resolver needs to map http:// to a port.
# libzstd1 and libgmp10 (zarith, under the TLS stack) come with the base image.
# libturbojpeg0, libpng16-16t64, libwebp7: the image decoders behind T3.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libcurl3t64-gnutls ca-certificates netbase \
      libturbojpeg0 libpng16-16t64 libwebp7 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /app app
WORKDIR /app
COPY --from=build /home/opam/src/data/content_taxonomy_3.1.tsv /home/opam/src/data/lexicon.tsv data/
COPY --from=build /home/opam/src/data/potion-base-32M.gguf /home/opam/src/data/potion-multilingual-128M.gguf data/
USER 10001

FROM runtime AS crawler
COPY --from=build /home/opam/src/data/siglip2-base-patch16-naflex.gguf /home/opam/src/data/siglip2_prototypes.gguf data/
COPY --from=build /home/opam/src/_build/default/crawler/crawler.exe /usr/local/bin/crawler
# The image benchmark, to time SigLIP 2 on the crawler's own hardware.
COPY --from=build /home/opam/src/_build/default/bench/image_bench.exe /usr/local/bin/image_bench
EXPOSE 8081
ENTRYPOINT ["crawler", "--data", "/app/data"]

FROM runtime AS online
COPY --from=build /home/opam/src/_build/default/online/online.exe /usr/local/bin/online
COPY --from=build /home/opam/src/frontend/index.html /home/opam/src/frontend/style.css frontend/
COPY --from=build /home/opam/src/frontend/dist/app.js frontend/dist/
EXPOSE 8080
ENTRYPOINT ["online", "--data", "/app/data", "--web", "/app/frontend"]
