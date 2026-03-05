#!/usr/bin/env bash
# =============================================================================
# rocm_env.sh – ROCm environment variables for AMD Instinct MI50 (gfx906)
#
# Source this file or add it to /etc/profile.d/rocm_env.sh so that every
# shell session automatically picks up the right settings.
#
# Usage:
#   source /opt/rocm_assistant/rocm_env.sh
#   # or, to install system-wide:
#   sudo cp rocm_env.sh /etc/profile.d/rocm_env.sh
# =============================================================================

# ---------------------------------------------------------------------------
# ROCm installation prefix (adjust if you used a custom --prefix at build time)
# ---------------------------------------------------------------------------
export ROCM_PATH="${ROCM_PATH:-/opt/rocm}"

# ---------------------------------------------------------------------------
# MI50 = Vega 20 = gfx906.  Newer ROCm releases (≥6.0) dropped official
# gfx906 support, but many operations still work when we tell the runtime
# which GFX version to emulate.
#   HSA_OVERRIDE_GFX_VERSION – used by the HIP/HSA stack
#   ROC_ENABLE_PRE_VEGA       – kept for older ROCm 5.x releases
# ---------------------------------------------------------------------------
export HSA_OVERRIDE_GFX_VERSION="9.0.6"
export ROC_ENABLE_PRE_VEGA=1

# GPU selection: if you have multiple GPUs set this to the index of the MI50
# (0-based).  Leave empty to let ROCm pick automatically.
# export HIP_VISIBLE_DEVICES=0
# export CUDA_VISIBLE_DEVICES=0   # used by some CUDA-compatibility layers

# ---------------------------------------------------------------------------
# PATH / library search
# ---------------------------------------------------------------------------
if [[ -d "${ROCM_PATH}/bin" ]]; then
    export PATH="${ROCM_PATH}/bin:${ROCM_PATH}/llvm/bin:${PATH}"
fi
if [[ -d "${ROCM_PATH}/lib" ]]; then
    export LD_LIBRARY_PATH="${ROCM_PATH}/lib:${ROCM_PATH}/lib64:${LD_LIBRARY_PATH:-}"
fi
if [[ -d "${ROCM_PATH}/lib/cmake" ]]; then
    export CMAKE_PREFIX_PATH="${ROCM_PATH}:${CMAKE_PREFIX_PATH:-}"
fi

# ---------------------------------------------------------------------------
# PyTorch / Torch helpers
# ---------------------------------------------------------------------------
# Tell PyTorch which AMD GPU architecture to target at JIT-compile time.
export PYTORCH_ROCM_ARCH="gfx906"

# Avoid the "no kernel image" crash when a pre-compiled wheel does not include
# gfx906 by requesting hiprtc to recompile on-the-fly.
export PYTORCH_HIP_ALLOC_CONF="garbage_collection_threshold:0.8,max_split_size_mb:512"

# ---------------------------------------------------------------------------
# llama.cpp / GGML helpers
# ---------------------------------------------------------------------------
export GGML_ROCM=1
export GGML_HIP_UMA=1        # unified memory – useful on APUs; harmless on MI50

# ---------------------------------------------------------------------------
# Stable Diffusion / Automatic1111 / ComfyUI
# ---------------------------------------------------------------------------
# The webui sets PYTORCH_CUDA_ALLOC_CONF; honour the ROCm equivalent.
export TORCH_ROCM_AMDGPU_TARGETS="gfx906"

# ---------------------------------------------------------------------------
# Coqui TTS
# ---------------------------------------------------------------------------
# Nothing GPU-specific required beyond the PyTorch settings above.

# ---------------------------------------------------------------------------
# Misc performance tweaks
# ---------------------------------------------------------------------------
# Reduce IPC latency
export HSA_ENABLE_SDMA=0
# Reduce large-chunk mmap overhead.  Note: glibc uses a trailing underscore
# in this tunable env var name (MALLOC_MMAP_THRESHOLD_ is correct).
export MALLOC_MMAP_THRESHOLD_=134217728

echo "[rocm_env] ROCm environment loaded (ROCM_PATH=${ROCM_PATH}, gfx=${HSA_OVERRIDE_GFX_VERSION})"
