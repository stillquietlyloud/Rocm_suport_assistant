# Quick Start – ROCm Support Assistant

> Get your AMD Instinct MI50 (or other Radeon GPU) running AI workloads in minutes.

---

## Step 1 – Clone the repository

```bash
git clone https://github.com/stillquietlyloud/Rocm_suport_assistant.git
cd Rocm_suport_assistant
```

---

## Step 2 – Make scripts executable

```bash
chmod +x rocm_setup.sh test_rocm.sh rocm_env.sh rocm_report.sh
```

---

## Step 3 – (LXC only) Expose GPU to the container

On the **Proxmox host**, add to `/etc/pve/lxc/<CONTAINER_ID>.conf`:

```
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 232:0 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
```

Then restart the container and verify inside it:

```bash
ls -la /dev/kfd /dev/dri/
```

Skip this step for bare-metal or full VMs with GPU passthrough already configured.

---

## Step 4 – Run the installer

```bash
sudo ./rocm_setup.sh
```

The script will:

1. Detect your GPU (MI50 → gfx906).
2. Install system dependencies (curl, cmake, python3, …).
3. Try ROCm versions **5.2 → 6.3**, one at a time:
   - Install via APT repo (falls back to direct download on failure).
   - Run the test suite.
   - Keep the version if tests pass; roll back if they fail.
4. Leave the **newest passing version** installed.
5. Write logs to `./logs/` and a summary report.

Typical run time: **20–60 minutes** depending on your internet speed and how many versions need to be tested.

> **Tip:** If you already know which version you want, use:
> ```bash
> sudo ./rocm_setup.sh --start-version 5.7 --target-version 5.7
> ```

---

## Step 5 – Load the environment

```bash
source /etc/profile.d/rocm_env.sh
```

To load automatically in every new shell, this file is installed system-wide by the setup script.  Just open a new terminal and the variables will be active.

---

## Step 6 – Verify

```bash
rocm-smi          # Should show your MI50 with temperature, VRAM usage, etc.
clinfo | head -20 # OpenCL platform info
```

Expected `rocm-smi` output (abbreviated):

```
========================= ROCm System Management Interface =========================
==================== Version ====================
ROCM-SMI version: X.X.X | ROCm version: 5.7.3
==================== Concise Info ====================
GPU  Temp   AvgPwr  SCLK    MCLK    Fan     Perf    PwrCap  VRAM%  GPU%
0    35.0c  40.0W   800Mhz  800Mhz  0%      auto    300.0W   1%    0%
```

---

## Step 7 – Install AI workloads

### PyTorch (ROCm wheel)

```bash
pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/rocm5.7
# Quick verify:
python3 -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

### llama.cpp

```bash
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp
cmake -B build -DGGML_HIPBLAS=ON -DAMDGPU_TARGETS=gfx906 -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j$(nproc)
# Run a model:
./build/bin/llama-cli -m /path/to/model.gguf -ngl 99 -p "Tell me about AMD GPUs"
```

### Stable Diffusion (Automatic1111)

```bash
git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui
cd stable-diffusion-webui
./webui.sh --skip-torch-cuda-test --precision full --no-half --listen
```

### Coqui TTS

```bash
pip install TTS
tts --text "Hello from the MI50!" \
    --model_name tts_models/en/ljspeech/tacotron2-DDC \
    --out_path hello.wav
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `torch.cuda.is_available()` → False | `source /etc/profile.d/rocm_env.sh` and check `/dev/kfd` |
| APT 404 errors | Script auto-falls back to direct download; check logs |
| `HSA_STATUS_ERROR_INVALID_ISA` | `export HSA_OVERRIDE_GFX_VERSION=9.0.6` |
| OOM with large models | Reduce context / use Q4_K_S quantization |
| Container can't see GPU | Re-check Proxmox LXC config (Step 3) |

Full troubleshooting guide: [README.md](README.md#troubleshooting)

---

## View the setup report

```bash
./rocm_report.sh
```

Logs are in `./logs/`.  The newest `summary_*.txt` file shows which versions passed and which failed.

---

## Need to re-run or upgrade?

```bash
sudo ./rocm_setup.sh --start-version 6.0   # try newer versions only
sudo ./rocm_setup.sh --dry-run             # preview without changes
```
