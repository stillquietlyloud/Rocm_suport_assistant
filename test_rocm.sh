#!/usr/bin/env bash
# =============================================================================
# test_rocm.sh – ROCm functional test suite
#
# Tests run in order of increasing complexity.  Each test reports PASS / FAIL
# and exits with the number of failed tests as its return code so the caller
# (rocm_setup.sh) can decide whether to keep or roll back a given ROCm version.
#
# Usage:
#   ./test_rocm.sh [--quick] [--log /path/to/log]
#
#   --quick   Skip time-consuming build / inference tests (GPU probe only)
#   --log     Append all output to the specified file in addition to stdout
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CLI options
# ---------------------------------------------------------------------------
QUICK=0
LOG_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)  QUICK=1 ;;
        --log)    LOG_FILE="$2"; shift ;;
        *)        echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log()  {
    local msg
    msg="[$(_ts)] $*"
    echo "$msg"
    if [[ -n "$LOG_FILE" ]]; then echo "$msg" >> "$LOG_FILE"; fi
}
pass() { log "  ✅ PASS – $*"; }
fail() { log "  ❌ FAIL – $*"; }
info() { log "  ℹ️  $*"; }
sep()  { log "$(printf '─%.0s' {1..70})"; }

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local name="$1"; shift
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    sep
    log "TEST: $name"
    # Capture output to a temp file so:
    #   1. The exit code of "$@" is reliably captured (no pipe-subshell ambiguity)
    #   2. Counter increments happen in the current shell, not a subshell
    local out_file test_rc
    out_file=$(mktemp)
    if "$@" > "$out_file" 2>&1; then
        test_rc=0
    else
        test_rc=$?
    fi
    while IFS= read -r line; do log "  | $line"; done < "$out_file"
    rm -f "$out_file"
    if [[ $test_rc -eq 0 ]]; then
        pass "$name"
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        return 0
    else
        fail "$name"
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Source environment
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/rocm_env.sh" ]]; then
    # shellcheck source=rocm_env.sh
    source "${SCRIPT_DIR}/rocm_env.sh" 2>/dev/null || true
fi

ROCM_PATH="${ROCM_PATH:-/opt/rocm}"

# =============================================================================
# T E S T   F U N C T I O N S
# =============================================================================

# ---------------------------------------------------------------------------
# T1 – ROCm installation sanity
# ---------------------------------------------------------------------------
test_rocm_installed() {
    [[ -d "$ROCM_PATH" ]] || { echo "ROCm path $ROCM_PATH does not exist"; return 1; }
    [[ -f "$ROCM_PATH/bin/rocm_agent_enumerator" ]] || { echo "rocm_agent_enumerator not found"; return 1; }
    echo "ROCm found at $ROCM_PATH"
    if [[ -f "$ROCM_PATH/.info/version" ]]; then
        echo "ROCm version: $(cat "$ROCM_PATH/.info/version")"
    fi
}

# ---------------------------------------------------------------------------
# T2 – GPU enumeration
# ---------------------------------------------------------------------------
test_gpu_enumeration() {
    local enum_bin="$ROCM_PATH/bin/rocm_agent_enumerator"
    [[ -x "$enum_bin" ]] || { echo "rocm_agent_enumerator not found or not executable"; return 1; }
    local agents
    agents=$("$enum_bin" 2>&1)
    echo "Agents: $agents"
    echo "$agents" | grep -qE 'gfx[0-9]' || { echo "No GPU agents found (gfxNNN expected)"; return 1; }
}

# ---------------------------------------------------------------------------
# T3 – rocm-smi
# ---------------------------------------------------------------------------
test_rocm_smi() {
    local smi_bin
    smi_bin=$(command -v rocm-smi 2>/dev/null || echo "$ROCM_PATH/bin/rocm-smi")
    [[ -x "$smi_bin" ]] || { echo "rocm-smi not found"; return 1; }
    "$smi_bin" --showid 2>&1
}

# ---------------------------------------------------------------------------
# T4 – clinfo (OpenCL)
# ---------------------------------------------------------------------------
test_clinfo() {
    command -v clinfo >/dev/null 2>&1 || { echo "clinfo not installed (skip)"; return 0; }
    local out
    out=$(clinfo 2>&1 | head -40)
    echo "$out"
    echo "$out" | grep -qi "number of platforms" || { echo "clinfo output unexpected"; return 1; }
}

# ---------------------------------------------------------------------------
# T5 – HIP hello-world (compiled at runtime)
# ---------------------------------------------------------------------------
test_hip_compile() {
    [[ $QUICK -eq 1 ]] && { info "Skipped in --quick mode"; return 0; }
    command -v hipcc >/dev/null 2>&1 || { echo "hipcc not in PATH – skipping HIP compile test"; return 0; }

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "$tmpdir/hello.hip" <<'HIP_EOF'
#include <hip/hip_runtime.h>
#include <stdio.h>
__global__ void hello_kernel() {
    printf("HIP kernel: block %d thread %d\n", blockIdx.x, threadIdx.x);
}
int main() {
    hipLaunchKernelGGL(hello_kernel, dim3(1), dim3(4), 0, 0);
    hipDeviceSynchronize();
    return 0;
}
HIP_EOF

    hipcc -o "$tmpdir/hello_hip" "$tmpdir/hello.hip" \
        --offload-arch=gfx906 2>&1 || { echo "HIP compilation failed"; return 1; }

    "$tmpdir/hello_hip" 2>&1 | grep -q "HIP kernel" || { echo "HIP kernel did not produce expected output"; return 1; }
    echo "HIP hello-world compiled and ran successfully"
}

# ---------------------------------------------------------------------------
# T6 – Python / PyTorch GPU availability
# ---------------------------------------------------------------------------
test_pytorch_gpu() {
    [[ $QUICK -eq 1 ]] && { info "Skipped in --quick mode"; return 0; }
    local python_bin
    python_bin=$(command -v python3 2>/dev/null) || { echo "python3 not found"; return 0; }

    "$python_bin" - <<'PY_EOF'
import sys
try:
    import torch
except ImportError:
    print("PyTorch not installed – skipping")
    sys.exit(0)

print(f"PyTorch version : {torch.__version__}")
print(f"ROCm available  : {torch.cuda.is_available()}")
if not torch.cuda.is_available():
    print("WARN: torch.cuda.is_available() returned False")
    sys.exit(1)
n = torch.cuda.device_count()
print(f"GPU count       : {n}")
for i in range(n):
    print(f"  GPU {i}: {torch.cuda.get_device_name(i)}")
# Quick tensor operation
x = torch.randn(128, 128, device="cuda")
y = torch.randn(128, 128, device="cuda")
z = torch.mm(x, y)
print(f"Matrix multiply result shape: {z.shape}")
print("PyTorch GPU test PASSED")
PY_EOF
}

# ---------------------------------------------------------------------------
# T7 – llama.cpp GPU availability (if installed)
# ---------------------------------------------------------------------------
test_llama_cpp() {
    [[ $QUICK -eq 1 ]] && { info "Skipped in --quick mode"; return 0; }

    # Look for the main llama.cpp binary in common locations
    local llama_bin=""
    for candidate in \
        /usr/local/bin/llama-cli \
        /usr/local/bin/llama-server \
        /opt/llama.cpp/llama-cli \
        /opt/llama.cpp/llama-server \
        "$(command -v llama-cli 2>/dev/null)" \
        "$(command -v llama-server 2>/dev/null)"; do
        [[ -x "$candidate" ]] && { llama_bin="$candidate"; break; }
    done

    if [[ -z "$llama_bin" ]]; then
        echo "llama.cpp not installed – skipping"
        return 0
    fi

    echo "Found llama.cpp binary: $llama_bin"
    # Run version / help check (no model needed)
    "$llama_bin" --version 2>&1 || "$llama_bin" --help 2>&1 | head -10
    echo "llama.cpp binary responds"
}

# ---------------------------------------------------------------------------
# T8 – Stable Diffusion (check Python packages)
# ---------------------------------------------------------------------------
test_stable_diffusion_pkgs() {
    [[ $QUICK -eq 1 ]] && { info "Skipped in --quick mode"; return 0; }
    local python_bin
    python_bin=$(command -v python3 2>/dev/null) || { echo "python3 not found"; return 0; }

    "$python_bin" - <<'PY_EOF'
import sys, importlib
missing = []
for pkg in ["diffusers", "transformers", "accelerate"]:
    try:
        m = importlib.import_module(pkg)
        print(f"  {pkg}: {getattr(m, '__version__', 'ok')}")
    except ImportError:
        missing.append(pkg)

if missing:
    print(f"Missing packages (not fatal): {missing}")
else:
    print("All core Stable Diffusion packages found")
PY_EOF
}

# ---------------------------------------------------------------------------
# T9 – Coqui TTS (check Python packages)
# ---------------------------------------------------------------------------
test_coqui_tts_pkgs() {
    [[ $QUICK -eq 1 ]] && { info "Skipped in --quick mode"; return 0; }
    local python_bin
    python_bin=$(command -v python3 2>/dev/null) || { echo "python3 not found"; return 0; }

    "$python_bin" - <<'PY_EOF'
import sys, importlib
for pkg in ["TTS", "torchaudio"]:
    try:
        m = importlib.import_module(pkg)
        print(f"  {pkg}: {getattr(m, '__version__', 'ok')}")
    except ImportError:
        print(f"  {pkg}: not installed (not fatal)")
PY_EOF
}

# ---------------------------------------------------------------------------
# T10 – Memory bandwidth smoke test (rocm-bandwidth-test if available)
# ---------------------------------------------------------------------------
test_memory_bandwidth() {
    [[ $QUICK -eq 1 ]] && { info "Skipped in --quick mode"; return 0; }
    local bw_bin
    bw_bin=$(command -v rocm-bandwidth-test 2>/dev/null || echo "")
    if [[ -z "$bw_bin" ]]; then
        echo "rocm-bandwidth-test not installed – skipping"
        return 0
    fi
    "$bw_bin" 2>&1 | head -30
}

# =============================================================================
# M A I N
# =============================================================================
sep
log "ROCm Test Suite starting"
log "ROCM_PATH            = ${ROCM_PATH}"
log "HSA_OVERRIDE_GFX_VERSION = ${HSA_OVERRIDE_GFX_VERSION:-unset}"
log "QUICK                = ${QUICK}"
sep

run_test "ROCm installation sanity"          test_rocm_installed       || true
run_test "GPU enumeration (rocm_agent_enumerator)" test_gpu_enumeration || true
run_test "rocm-smi"                          test_rocm_smi             || true
run_test "OpenCL / clinfo"                   test_clinfo               || true
run_test "HIP hello-world (compile+run)"     test_hip_compile          || true
run_test "PyTorch GPU"                       test_pytorch_gpu          || true
run_test "llama.cpp binary"                  test_llama_cpp            || true
run_test "Stable Diffusion packages"         test_stable_diffusion_pkgs || true
run_test "Coqui TTS packages"               test_coqui_tts_pkgs       || true
run_test "Memory bandwidth test"             test_memory_bandwidth      || true

sep
log "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
sep

exit "$TESTS_FAILED"
