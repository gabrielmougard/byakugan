# ggml (vendored subset)

Tensor library behind llama.cpp and whisper.cpp. Here it gives us:
- GGUF, the model file format;
- SIMD maths on the CPU.

It is used for the Model2Vec tables and T2 similarity (`src/stubs/m2v/`), and later for T3 (parakeet, SigLIP 2).

- Upstream: https://github.com/ggml-org/ggml
- Version: v0.29.0 (release of 2026-11-04)
- License: MIT (`LICENSE`)

Copied unmodified:
- the top-level `CMakeLists.txt`, `cmake/`, `include/`, `ggml.pc.in`, `LICENSE`;
- from `src/`, the core files and `ggml-cpu/`.

The other backends (CUDA, Metal, Vulkan…) are left out; their CMake options are off.

`src/stubs/build-ggml.sh` builds it with ggml's own CMake:
- static libraries, CPU backend only;
- `GGML_NATIVE=OFF`, so a build on an Apple M-series Mac also runs on a Raspberry Pi 4 (plain ARMv8-A with NEON);
- no OpenMP, Accelerate, Metal or BLAS.

To update, copy the same paths from a newer release and change the version above.
