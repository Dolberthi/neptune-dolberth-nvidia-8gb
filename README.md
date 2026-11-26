<h1 align="center">Neptune HyperEngine by Dolberth (VIctory Fork)</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Windows%2010%20%26%2011-0b0a15?style=flat-square&logo=windows11&logoColor=white" alt="Windows 10 & 11">
  <img src="https://img.shields.io/badge/NVIDIA%208GB%20%2B%2016GB%20RAM-0b0a15?style=flat-square&logo=nvidia&logoColor=76b900" alt="NVIDIA 8GB + 16GB RAM">
  <img src="https://img.shields.io/badge/AMD%20Ryzen%20Zen%202%2F3%2F4%2F5-0b0a15?style=flat-square&logo=amd&logoColor=ed1c24" alt="AMD Ryzen">
  <img src="https://img.shields.io/badge/D3D12%20%2B%20Agility%20SDK%201.620-0b0a15?style=flat-square" alt="D3D12 Agility SDK">
  <img src="https://img.shields.io/badge/GPL--3.0--or--later-0b0a15?style=flat-square&logo=gnu&logoColor=white" alt="GPL-3.0-or-later">
</p>

<p align="center">
  A performance-focused fork of the <b>VIctory / Neptune</b> Xbox Series (Scarlett) PE loader, RDNA2-to-DXIL shader translator, and D3D12 compatibility layer for Windows 10 &amp; Windows 11 — tuned for <b>8 GB NVIDIA GPUs</b>, <b>6-core CPUs</b>, and <b>16 GB RAM</b> without external upscaler DLLs.
</p>

> [!IMPORTANT]
> **Loader and compatibility layer source code only.**
> This repository contains **zero** third-party software, proprietary binaries, keys, or assets. Users must supply their own legally obtained executable at runtime. Not affiliated with or endorsed by any hardware or software vendor.

---

## ◆ Highlights of this fork

This fork unifies community CPU/VRAM/NVIDIA improvements from **Neptune-VE**, **`ad3lre/victory-nvidia-8gb`**, and **`proneonn/Vertex`** together with custom runtime subsystems (**Neptune HyperEngine**, **Clear-TAA**, and **VRAM Guardian**):

### 1. Neptune HyperEngine (CPU, Hashing & Streaming Pipeline)
- **Persistent Zero-Spawn Worker Pool (`turbo.rs`)**: Eliminates per-frame `std::thread::scope` thread creation overhead across texture refreshes (`texture.rs`), descriptor heap synchronization (`descriptor.rs`), and write-watch flushes (`host.rs`).
- **Zero-Dependency `FxHasher` (`FastMap` / `FastSet`)**: Replaces SipHash-1-3 across hot submission, shadow-range, and draw-state hash tables (`shadow.rs`, `draw.rs`, `host.rs`).
- **AVX2 256-bit Vector Hasher & Zero-Page Early Skip**: High-throughput descriptor and texture change hashing, plus instant skip of untouched zeroed descriptor pages.
- **Shader Metadata Sidecar Cache (`neptune-meta.bin`)**: Persists RDNA2 container metadata (`stores`, `walks`, `used`) alongside `%LOCALAPPDATA%\victory\cache\shaders` (~97% hit rate), skipping redundant `Container::parse` + `native_programs()` disassembly on warm launches.
- **Zero-Allocation SIMD Texture Detiler (`victory-formats/src/texture.rs`)**: Thread-local reused run buffers + unchecked 16/32/64-byte chunk detiling for Scarlett XOR-swizzled textures.
- **Parallel Draw Translation (`VICTORY_THIN=1`) & Smart Copy-Back v2 (`smart_back.rs`)**: Parallel command translation combined with size-filtered GPU-to-CPU copy-backs (`VICTORY_SMART_COPY_BACK_KB=4`) and CPU-validated indirect draw arguments (`VICTORY_INDIRECT_RAW=3`).

### 2. Built-in Clear-TAA Resolve Pass (100% Standalone)
- **Native HLSL Compute Upscaler (`upscale.rs` + `host.rs`)**: No external upscaler DLLs or Frame Generation required.
- **Sub-Pixel Unjitter + Compressed-HDR Anti-Crumb Suppression**: Suppresses dithered highlight/edge noise on jittered lower-resolution render targets.
- **FXAA 3.11 + Motion-Vector TAA-U (`VICTORY_TAA=1`)**: Edge-directed anti-aliasing paired with motion-vector temporal accumulation and YCoCg variance AABB neighborhood clipping (`VICTORY_TAA=0` uses spatial anti-crumb + FXAA only).

### 3. VRAM Guardian & 8 GB GPU / 16 GB RAM Optimizations (fused with `ad3lre/victory-nvidia-8gb`)
- **Texture Mip Dimension Cap (`VICTORY_TEXTURE_MAX_DIM=1024`)**: Caps highest mip levels on 8 GB GPUs to reclaim ~1.5–2 GB of VRAM and prevent `0x887A0006` OOM/TDR crashes (set `2048` for higher detail or `0` to disable).
- **2-Tier Tight Placed-Resource Slab Allocator (`placement.rs`)**: Packs `<= 128 KiB` resources into `2 MiB` heaps and `128–512 KiB` into `4 MiB` heaps with automatic trimming at `78%` VRAM pressure to minimize slab fragmentation.
- **Shared-RAM & VRAM Pressure Trim (`VICTORY_RAM_TRIM_MB=2048`)**: Drains spare upload staging pools, idle staging buffers, and stale shadows when shared GPU memory or VRAM crosses pressure thresholds.
- **Batched Card Sync & Indexed Submission Steps**: Integrates `VICTORY_CARD_REHASH_GAP=4`, `VICTORY_CARD_SYNC_BATCH=1`, and `VICTORY_STEP_INDEX=1` (backed by `FastMap`/`FastSet`).

### 4. Refresh Stamp (fused with `proneonn/Vertex`)
- **Monotonic Refresh Stamp (`stamp.rs`, `VICTORY_REFRESH_STAMP=1` opt-in)**: Skips redundant CPU shadow-buffer refreshes when title memory has not been written since the last upload stamp.

### 5. Windows 10 & Windows 11 Support + Diagnostics
- **DirectX 12 Agility SDK Exports (`apps/victory/src/main.rs`)**: Exports `D3D12SDKVersion` (`620`) and `D3D12SDKPath` (`.\D3D12\`) in `victory.exe` so Windows 10 (19045+) can load modern D3D12 features when `D3D12\D3D12Core.dll` (Agility SDK `1.620.2`) is placed next to `victory.exe`.
- **Host-Friendly Scheduling**: Runs at `VICTORY_PROCESS_PRIORITY=normal` to keep Windows DWM responsive on 6-core CPUs.
- **Live Telemetry Script ([neptune-diag.ps1](neptune-diag.ps1))**: Parses frame times, VRAM/shared-RAM usage, copy-back buckets, shader cache hit rates, and runtime warnings.

---

## ◆ Requirements

Check every line before reporting a crash: most startup failures come from one of these.

| | Needed | Notes |
|---|---|---|
| **OS** | Windows 10 22H2 (19045+) or Windows 11, x64 | Keep Windows Update current. |
| **GPU** | DirectX 12 Ultimate: Shader Model 6.6 + mesh shaders, **8 GB+ VRAM** | NVIDIA RTX 20 series or newer (tested: RTX 4060 8 GB). Current driver. Resizable BAR on in the BIOS helps. |
| **D3D12 Agility SDK** | `D3D12\D3D12Core.dll` **1.620.2 (x64)** beside `victory.exe` | **Included** (`redist/D3D12`) and copied by `cargo build` to `target\release\D3D12\`. Needed on Windows 10 *and* 11. Missing or another version → `0x887E0003`. See [Troubleshooting](#-troubleshooting). |
| **CPU** | x64 with **AVX2**, 6+ cores recommended | Tested: Ryzen 5 5500 (6C/12T). |
| **RAM** | 16 GB minimum, **32 GB recommended** | The process reaches 18–21 GB private memory in the open world: keep the Windows page file **system-managed on an SSD** (or at least 32 GB). |
| **Disk** | ~10 GB free on the system drive | Shader cache (`%LOCALAPPDATA%\victory\cache`, grows to ~7 GB) + build output. |
| **Runtime libraries** | Microsoft Visual C++ 2015–2022 Redistributable (x64) | Usually already installed; get it from Microsoft if `VCRUNTIME140.dll` is reported missing. |
| **Build tools** | [rustup](https://rustup.rs) (toolchain pinned by `rust-toolchain.toml`) + Visual Studio Build Tools (MSVC + Windows SDK) | Only to build from source. |
| **Your own title** | A complete, lawfully obtained copy of the title you run | No title files, code or assets are provided here. |

### ◆ Troubleshooting

| Log line / symptom | Cause | Fix |
|---|---|---|
| `no host D3D12 device ... The D3D12 SDK version configuration of the host exe is invalid. (0x887E0003)`, then `D3D12SerializeVersionedRootSignature` | `D3D12\D3D12Core.dll` beside `victory.exe` is missing, not **1.620.2**, not the **x64** build, or sits in a subfolder | Run `.\tools\get-agility-sdk.ps1` (or `-ExeDir <folder>` for a `victory.exe` you moved). It copies the repository's file or downloads Microsoft's package and checks hash, version and signature. Check by hand: `Get-FileHash .\target\release\D3D12\D3D12Core.dll` must print `70A6D47D335B4A15180544C01A35B84474522A369DC582D85FE057313A3AEAA0`. |
| `victory.exe is already running` | A previous session is still open | Close it (Task Manager) and launch again. |
| Very slow first launch | Shader cache being built | Let it finish once; later launches reuse it. |

---

## ◆ Build

```powershell
cargo build --release -p victory
```

This produces `target\release\victory.exe` and copies the Agility SDK runtime to `target\release\D3D12\D3D12Core.dll`.

> [!NOTE]
> `D3D12Core.dll` is Microsoft's redistributable file (Agility SDK 1.620.2, unmodified, signed by Microsoft), kept in `redist/D3D12` under Microsoft's own license (`redist/D3D12/LICENSE-Microsoft-Agility-SDK.txt`), not this repository's GPL. If you copy `victory.exe` to another folder, copy the `D3D12` folder with it or run `.\tools\get-agility-sdk.ps1 -ExeDir <folder>`.

---

## ◆ Usage

```powershell
# Launch with the 8 GB NVIDIA / 16 GB RAM profile.
# First launch automatically warms the shader cache offline once (~3-5 min) to prevent
# live compilation stutter; all subsequent launches start immediately.
.\run-neptune.ps1 -Title 'D:\Path\To\Your\title.exe'

# Force re-warming shaders (or skip auto-warm with -SkipWarm)
.\run-neptune.ps1 -Title 'D:\Path\To\Your\title.exe' -WarmShaders

# Higher texture cap (12 GB+ VRAM) or windowed mode
.\run-neptune.ps1 -Title 'D:\Path\To\Your\title.exe' -TextureMaxDim 2048 -Window '1600x900'

# Inspect runtime telemetry / logs
.\neptune-diag.ps1
```

**Hotkeys:** `F9` mouse look · `F10` toggle overlay · `F11` / `Alt+Enter` toggle borderless fullscreen ↔ windowed · `F12` screenshot

---

## ◆ Key Environment Switches

| Switch | Default (`run-neptune.ps1`) | Description |
|:--|:--|:--|
| `VICTORY_TEXTURE_MAX_DIM` | `0` | Optional texture mip cap (`1024`/`2048` to reduce non-XOR mip memory; `0` default for highest FPS) |
| `VICTORY_RAM_TRIM_MB` | `512` | Emergency idle-pool trim only when free physical RAM drops below threshold (avoids buffer thrashing) |
| `VICTORY_TAA` | `0` | Spatial Anti-Crumb + FXAA 3.11 by default (zero ghosting); set `1` / `-Taa` to enable temporal resolve |
| `VICTORY_REFRESH_STAMP` | `0` | Optional monotonic shadow-refresh stamp (experimental opt-in `1`) |
| `VICTORY_STEP_INDEX` | `1` | O(1) indexed submission step tracking (`FastMap`/`FastSet`) |
| `VICTORY_CARD_REHASH_GAP` | `4` | Joins nearby dirty buffer sub-ranges before rehashing |
| `VICTORY_CARD_SYNC_BATCH` | `1` | Coalesces card buffer sync + rehash passes |
| `VICTORY_TURBO_THREADS` | `5` | Persistent worker pool thread count |
| `VICTORY_SHADER_META_CACHE` | `1` | Enables `neptune-meta.bin` RDNA2 metadata sidecar cache |
| `VICTORY_SMART_COPY_BACK` / `_KB` | `1` / `4` | Filters small unnecessary GPU-to-CPU copy-backs |
| `VICTORY_THIN` / `_THREADS` | `1` / `6` | Parallel command list draw translation |
| `VICTORY_INDIRECT_RAW` | `3` | CPU-validated indirect draw arguments |
| `VICTORY_PROCESS_PRIORITY` | `normal` | Keeps host desktop/DWM responsive on 6-core CPUs |
| `VICTORY_NAN_GUARD` | `0` | Keeps compiled shader cache valid (`-WarmShaders` required if changed) |

---

## ◆ Credits & Upstream Attribution

Licensed under **GPL-3.0-or-later**. Built upon the work of the VIctory / Neptune open-source community:

- **[Marvisak/VIctory](https://github.com/Marvisak/VIctory)** — original loader and emulator architecture
- **fxceless & myokex** — core runtime, levels on demand, heap sync (with PRs by Jonirulah, Flyander, AscilCH)
- **soldsawn** — RDNA2-to-DXIL shader translator
- **Neptune (VIctory Edit.) — Traffic, imgone & zm0kie** — Neptune-VE base, thin lists, overlay, ambient pass, indirect validation (`RAW3`)
- **[ad3lre/victory-nvidia-8gb](https://github.com/ad3lre/victory-nvidia-8gb)** — `VICTORY_TEXTURE_MAX_DIM`, `VICTORY_RAM_TRIM_MB`, AVX2 zero-page skip, `VICTORY_CARD_REHASH_GAP`, `VICTORY_CARD_SYNC_BATCH`, and `VICTORY_STEP_INDEX`
- **[proneonn/Vertex](https://github.com/proneonn/Vertex)** & **tippythetaidum (PR #927)** — monotonic refresh stamp (`stamp.rs`) and NVIDIA 16-bit `d16` typed buffer fix (`halves.rs` / `half_views`)
- **avatarmanz (`VIctory-7900XTX`)** — `list_views` and descriptor optimizations
- **Belobug & ShakiraRED-dt** — ambient pass
- **ZSlayerHQ, JoshuuDev, skornuta, Trexies, clankenjoyer, rorodev6, PalmVI, and DexNom** — upstream fixes and research

<p align="center">
  <sub>GPL-3.0-or-later · Compatibility layer &amp; loader research · No proprietary files included</sub>
</p>
