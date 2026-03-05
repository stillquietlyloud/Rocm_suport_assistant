# ROCm Support Assistant

> **Automated ROCm installer, tester, and version manager for AMD Instinct MI50 (and other Radeon / Instinct GPUs) on Ubuntu.**

---

## Table of Contents

1. [Overview](#overview)
2. [Hardware & Software Compatibility](#hardware--software-compatibility)
3. [Repository Structure](#repository-structure)
4. [How It Works](#how-it-works)
5. [Prerequisites](#prerequisites)
6. [Quick Start](#quick-start)
7. [Detailed Usage](#detailed-usage)
8. [Script Reference](#script-reference)
9. [Environment Variables Reference](#environment-variables-reference)
10. [Supported AI Workloads](#supported-ai-workloads)
11. [Troubleshooting](#troubleshooting)
12. [Known Limitations](#known-limitations)
13. [Contributing](#contributing)
14. [License](#license)

---

## Overview

This project solves a common problem: AMD discontinued official ROCm support for older-but-capable GPUs such as the **Instinct MI50 (gfx906)** while these cards remain excellent AI accelerators. The scripts here:

- Detect your GPU and Ubuntu version automatically.
- Iterate through ROCm versions (5.2 → latest) **from oldest to newest**.
- Install each version, run a functional test suite, then **keep it if tests pass or roll it back if they fail**.
- Use direct `.deb` binary downloads from AMD (`repo.radeon.com/amdgpu-install/`) as the primary fallback when the AMD APT repository is unreachable – this method is the most reliable across ROCm releases.
- Emit structured logs and a final summary report so you always know exactly what happened.
- Configure the system environment (groups, `ld.so`, `profile.d`) so that **llama.cpp, Stable Diffusion, Coqui TTS, PyTorch, and other GPU workloads** work out of the box.
- Clean up installer meta-packages after use – only the ROCm runtime libraries remain on the system.

A CI pipeline (`.github/workflows/ci.yml`) validates all scripts on every push without requiring AMD GPU hardware, using the `--ci` mode of `test_rocm.sh`.

---

## Hardware & Software Compatibility

### Tested GPU

| GPU Model | Architecture | VRAM | gfx Target |
|---|---|---|---|
| AMD Instinct MI50 | Vega 20 | 32 GB HBM2 | `gfx906` |

### Other potentially compatible GPUs

| GPU | Architecture | gfx Target | Notes |
|---|---|---|---|
| Radeon VII | Vega 20 | `gfx906` | Consumer counterpart to MI50 |
| Instinct MI60 | Vega 20 | `gfx906` | Same arch |
| RX 5700 / 5700 XT | Navi 10 | `gfx1010` | Adjust `HSA_OVERRIDE_GFX_VERSION` |
| RX 6000 series | RDNA 2 | `gfx1030` | Supported by ROCm 5.0+ |
| RX 7000 series | RDNA 3 | `gfx1100` | ROCm 6.0+ |

### ROCm version support matrix for MI50 (gfx906)

| ROCm Version | Official MI50 Support | Workaround (HSA_OVERRIDE) | Notes |
|---|---|---|---|
| 5.2.x | ✅ | Not needed | Stable baseline |
| 5.3.x | ✅ | Not needed | |
| 5.4.x | ✅ | Not needed | |
| 5.5.x | ✅ | Not needed | |
| 5.6.x | ✅ | Not needed | |
| 5.7.x | ✅ | Not needed | Last official release |
| 6.0.x | ⚠️ Unofficial | `9.0.6` | Many ops work |
| 6.1.x | ⚠️ Unofficial | `9.0.6` | |
| 6.2.x | ⚠️ Unofficial | `9.0.6` | |
| 6.3.x | ⚠️ Unofficial | `9.0.6` | Newest at time of writing |

### Operating System

| Distro | Status |
|---|---|
| Ubuntu 24.04 LTS (Noble) | ✅ Primary target |
| Ubuntu 22.04 LTS (Jammy) | ✅ Tested |
| Ubuntu 20.04 LTS (Focal) | ⚠️ Best-effort |
| Other Debian derivatives | ⚠️ May work |

### Deployment targets

The script works identically on:

- **LXC containers** (ensure the host kernel exposes `/dev/kfd` and `/dev/dri` to the container)
- **KVM / QEMU virtual machines** (GPU passthrough required)
- **Bare-metal servers or workstations**

---

## Repository Structure

```
Rocm_suport_assistant/
├── .github/
│   └── workflows/
│       └── ci.yml         # CI pipeline: lint + ShellCheck + CI-mode tests
├── rocm_setup.sh      # Main installer / version-iterator script
├── test_rocm.sh       # Functional test suite
├── rocm_env.sh        # Environment variable definitions
├── rocm_report.sh     # Log parser and human-readable reporter
├── QUICKSTART.md      # 5-minute quick-start guide
├── README.md          # This file
├── LICENSE
└── logs/              # Created at runtime
    ├── rocm_setup_<timestamp>.log
    ├── apt_<version>.log
    ├── test_<version>.log
    └── summary_<timestamp>.txt
```

---

## How It Works

### Flowchart

```
Start
  │
  ▼
Pre-flight checks (root, OS, GPU detection)
  │
  ▼
Install base OS dependencies (curl, cmake, python3, …)
  │
  ▼
For each ROCm version in catalogue (5.2 → 6.3):
  │
  ├─► Add AMD APT repository
  │     └─► (on failure) download .deb installer directly
  │
  ├─► Install ROCm packages
  │     └─► (on failure) skip this version
  │
  ├─► Configure environment (profile.d, ldconfig, groups)
  │
  ├─► Run test suite (test_rocm.sh)
  │     ├─► PASS → record best_version, continue to next
  │     └─► FAIL → remove ROCm, continue to next
  │
  └─► Stop at --target-version or end of catalogue
  │
  ▼
Re-install best_version if it was rolled back
  │
  ▼
Write summary report to logs/summary_<timestamp>.txt
  │
  ▼
Exit 0 (success) or 1 (no working version found)
```

### Error handling strategy

| Failure type | Action |
|---|---|
| APT repo unreachable | Fall back to direct `.deb` download (preferred method) |
| Package install failure | Skip version, try next |
| Test suite failure | Remove installed packages, try next version |
| No passing version found | Exit 1 with full log path |

### Direct `.deb` download URL format

AMD hosts `amdgpu-install` bootstrap packages at:

```
https://repo.radeon.com/amdgpu-install/<version>/ubuntu/<codename>/<package>
```

where `<package>` follows the pattern `amdgpu-install_<major>.<minor>.<buildnum>-1_all.deb`
and `<buildnum>` = `major * 10000 + minor * 100 + patch` (minor and patch are each
zero-padded to two digits).  For example:

| ROCm version | codename | package |
|---|---|---|
| 6.3.1 | noble | `amdgpu-install_6.3.60301-1_all.deb` |
| 6.2.4 | noble | `amdgpu-install_6.2.60204-1_all.deb` |
| 5.7.3 | jammy | `amdgpu-install_5.7.50703-1_all.deb` |
| 5.6.1 | jammy | `amdgpu-install_5.6.50601-1_all.deb` |

The `amdgpu-install` meta-package is automatically removed after ROCm is
installed so that only the ROCm runtime libraries remain on the system.

---

## Prerequisites

### System

- Ubuntu 22.04 or 24.04 (headless is fine; no GUI needed)
- `sudo` / root access
- Internet connection (or pre-downloaded packages)
- At least **10 GB free disk space** (ROCm is ~4–8 GB per version)

### LXC-specific requirements

The host must expose the GPU device nodes to the container.  Add these lines to the LXC container configuration (usually `/etc/pve/lxc/<ID>.conf` on Proxmox):

```
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 232:0 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
```

Verify from inside the container:

```bash
ls -la /dev/kfd /dev/dri/
```

---

## Quick Start

See [QUICKSTART.md](QUICKSTART.md) for a concise 5-minute guide.

```bash
# 1. Clone and enter the repo
git clone https://github.com/stillquietlyloud/Rocm_suport_assistant.git
cd Rocm_suport_assistant

# 2. Make scripts executable
chmod +x rocm_setup.sh test_rocm.sh rocm_env.sh rocm_report.sh

# 3. Run the installer (root required)
sudo ./rocm_setup.sh

# 4. Load the environment
source /etc/profile.d/rocm_env.sh

# 5. Verify
rocm-smi
```

---

## Detailed Usage

### `rocm_setup.sh`

```
sudo ./rocm_setup.sh [OPTIONS]

Options:
  --start-version VER   Begin at this ROCm version (e.g. 5.7)
  --target-version VER  Stop at this version (default: newest in list)
  --skip-tests          Install without running functional tests
  --quick-tests         Run only fast probe tests (no compile/inference)
  --log-dir DIR         Directory for log files (default: ./logs)
  --no-cleanup          Keep intermediate ROCm packages after failure
  --dry-run             Print what would be done without making changes
  --help                Show help and exit
```

#### Examples

```bash
# Full run – find and keep the newest working version
sudo ./rocm_setup.sh

# Start from ROCm 5.7 (skip older versions)
sudo ./rocm_setup.sh --start-version 5.7

# Target a specific version only
sudo ./rocm_setup.sh --start-version 6.1 --target-version 6.1

# Quick test mode (GPU probe only, no compile)
sudo ./rocm_setup.sh --quick-tests

# Dry run to see what would happen
sudo ./rocm_setup.sh --dry-run

# Custom log directory
sudo ./rocm_setup.sh --log-dir /var/log/rocm_setup
```

### `test_rocm.sh`

Run the test suite independently against the currently installed ROCm:

```bash
# Full tests
sudo bash test_rocm.sh

# Quick tests (GPU probe only)
sudo bash test_rocm.sh --quick

# CI mode – hardware tests (T1–T3) skip gracefully when no GPU is present
bash test_rocm.sh --ci --quick

# Append output to a log file
sudo bash test_rocm.sh --log /tmp/my_rocm_test.log
```

Test IDs and what they check:

| ID | Name | Notes |
|---|---|---|
| T1 | ROCm installation sanity | Checks `/opt/rocm` and version file; skips in `--ci` mode |
| T2 | GPU enumeration | `rocm_agent_enumerator` finds GPU; skips in `--ci` mode |
| T3 | rocm-smi | GPU details visible via SMI; skips in `--ci` mode |
| T4 | OpenCL / clinfo | (skipped if clinfo not installed) |
| T5 | HIP hello-world | Compiles and runs a small HIP kernel |
| T6 | PyTorch GPU | `torch.cuda.is_available()` + matrix multiply |
| T7 | llama.cpp binary | Binary responds (no model needed) |
| T8 | Stable Diffusion packages | diffusers / transformers / accelerate |
| T9 | Coqui TTS packages | TTS / torchaudio |
| T10 | Memory bandwidth | `rocm-bandwidth-test` (if installed) |

Tests T5–T10 are skipped in `--quick` mode.
Tests T1–T3 return SKIP (not FAIL) in `--ci` mode when hardware is absent.

### `rocm_env.sh`

Source manually or install system-wide:

```bash
# Manual (current session only)
source ./rocm_env.sh

# System-wide (persists across reboots)
sudo cp rocm_env.sh /etc/profile.d/rocm_env.sh
```

### `rocm_report.sh`

Parse logs and print a summary:

```bash
./rocm_report.sh           # reads ./logs/
./rocm_report.sh /var/log/rocm_setup
```

---

## Script Reference

### `rocm_setup.sh` internals

| Function | Purpose |
|---|---|
| `preflight_check()` | Root, OS, GPU, disk space checks |
| `detect_gpu()` | Identifies GPU via lspci and rocm_agent_enumerator |
| `install_base_deps()` | Installs curl, cmake, python3, etc. |
| `_add_amd_repo()` | Adds AMD APT repo + GPG key |
| `_remove_amd_repo()` | Removes AMD APT repo |
| `install_rocm_via_repo()` | APT-based ROCm install |
| `install_rocm_direct()` | `.deb`-based fallback install |
| `remove_rocm()` | Full ROCm uninstall + cleanup |
| `configure_environment()` | profile.d, ldconfig, groups |
| `run_tests()` | Delegates to test_rocm.sh |
| `write_summary()` | Writes human-readable report |
| `main()` | Version iteration loop |

---

## Environment Variables Reference

These variables are set by `rocm_env.sh` and are essential for correct operation:

| Variable | Default | Purpose |
|---|---|---|
| `ROCM_PATH` | `/opt/rocm` | ROCm installation root |
| `HSA_OVERRIDE_GFX_VERSION` | `9.0.6` | Forces MI50/gfx906 for ROCm ≥6.0 |
| `ROC_ENABLE_PRE_VEGA` | `1` | Enables pre-Vega GPU support in older ROCm |
| `PYTORCH_ROCM_ARCH` | `gfx906` | PyTorch JIT compile target |
| `PYTORCH_HIP_ALLOC_CONF` | (see file) | PyTorch memory allocator tuning |
| `GGML_ROCM` | `1` | Enables ROCm backend in llama.cpp |
| `GGML_HIP_UMA` | `1` | Unified memory hint for llama.cpp |
| `TORCH_ROCM_AMDGPU_TARGETS` | `gfx906` | ROCm target for SD/ComfyUI |
| `HSA_ENABLE_SDMA` | `0` | Disables SDMA for IPC latency reduction |

---

## Supported AI Workloads

### llama.cpp

Build with ROCm support:

```bash
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp
cmake -B build \
  -DGGML_HIPBLAS=ON \
  -DAMDGPU_TARGETS=gfx906 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j$(nproc)
```

Run (example with a GGUF model):

```bash
source /etc/profile.d/rocm_env.sh
./build/bin/llama-cli -m /models/your-model.Q4_K_M.gguf \
  -ngl 99 -n 512 -p "Hello, world!"
```

### PyTorch

Install the ROCm-enabled wheel:

```bash
pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/rocm6.0
```

Verify:

```python
import torch
print(torch.cuda.is_available())   # Should print: True
print(torch.cuda.get_device_name(0))
```

### Stable Diffusion (Automatic1111 / ComfyUI)

```bash
source /etc/profile.d/rocm_env.sh
git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui
cd stable-diffusion-webui
# The installer detects ROCm automatically
./webui.sh --skip-torch-cuda-test --precision full --no-half
```

### Coqui TTS

```bash
pip install TTS
source /etc/profile.d/rocm_env.sh
tts --text "Hello from your MI50!" \
    --model_name tts_models/en/ljspeech/tacotron2-DDC \
    --out_path output.wav
```

---

## Troubleshooting

### `torch.cuda.is_available()` returns `False`

1. Ensure `rocm_env.sh` is sourced.
2. Verify the user is in the `render` group: `groups $USER`.
3. Check device nodes: `ls -la /dev/kfd /dev/dri/`.
4. Re-run `sudo ./rocm_setup.sh --quick-tests` to check install state.

### `No GPU agents found` in rocm_agent_enumerator

- In LXC: verify `/dev/kfd` is accessible (see [LXC requirements](#lxc-specific-requirements)).
- On bare metal: check `dmesg | grep -i amdgpu` for driver errors.

### APT repo 404 errors

The AMD repo URL occasionally changes.  The script automatically falls back to direct `.deb` downloads.  If both fail:

```bash
# Download the amdgpu-install meta-package manually (example: ROCm 6.2.4 on noble)
wget https://repo.radeon.com/amdgpu-install/6.2.4/ubuntu/noble/amdgpu-install_6.2.60204-1_all.deb
sudo apt install ./amdgpu-install_6.2.60204-1_all.deb
sudo amdgpu-install --usecase=rocm,hip,opencl --no-dkms --accept-eula
# Remove the meta-package after installation (ROCm packages stay)
sudo apt remove --purge amdgpu-install
```

See the [Direct `.deb` download URL format](#direct-deb-download-url-format) section for the
correct URL pattern for other ROCm versions.

### `HSA_STATUS_ERROR_INVALID_ISA` or kernel image errors with PyTorch

This means the compiled wheel does not include gfx906.  Set:

```bash
export HSA_OVERRIDE_GFX_VERSION=9.0.6
```

and restart your Python process.

### Out-of-memory (OOM) errors with large models

Tune the allocator:

```bash
export PYTORCH_HIP_ALLOC_CONF="garbage_collection_threshold:0.8,max_split_size_mb:256"
```

For llama.cpp, reduce the context window (`-c 2048`) or quantize to Q4_K_S.

---

## Known Limitations

1. **ROCm ≥ 6.0 on MI50 is unofficial.**  AMD does not ship pre-compiled kernels for gfx906 in ROCm 6.x.  `HSA_OVERRIDE_GFX_VERSION` makes many things work, but some operations (e.g., certain MIOpen kernels) may fall back to CPU.

2. **DKMS / kernel module not installed.**  The `--no-dkms` flag is used by default because LXC containers share the host kernel and cannot load kernel modules.  On bare-metal or VMs, remove `--no-dkms` if you need AMDGPU kernel driver updates.

3. **Multi-GPU is not tested.**  The scripts assume a single MI50.  Set `HIP_VISIBLE_DEVICES` / `CUDA_VISIBLE_DEVICES` if you have multiple GPUs.

4. **Internet required.**  The fallback binary download also needs internet access.  Offline installs require pre-staging packages.

---

## Contributing

Pull requests welcome!  Please:

- Test on at least one AMD GPU before submitting.
- Follow the existing logging style in the Bash scripts.
- Update this README and QUICKSTART.md with any user-facing changes.

---

## License

MIT – see [LICENSE](LICENSE).
