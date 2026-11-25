<div align="center">

# Neptune VI

**The Neptune runtime for GTA VI, ported to an AMD Ryzen + NVIDIA PC.**

A port of *Neptune (VIctory Edit.)* by **Traffic** and **imgone**, built and tested on a Ryzen 7 9800X3D.

![platform](https://img.shields.io/badge/platform-Windows%2011-0b0b0b?style=flat-square)
![cpu](https://img.shields.io/badge/CPU-Ryzen%207%209800X3D-ed1c24?style=flat-square)
![gpu](https://img.shields.io/badge/GPU-RTX%205070%20Ti-76b900?style=flat-square)
![license](https://img.shields.io/badge/license-GPL--3.0-1f6feb?style=flat-square)
![status](https://img.shields.io/badge/status-work%20in%20progress-8a8a8a?style=flat-square)

</div>

---

## What this is

Neptune runs the Xbox Series executable of GTA VI on a Windows PC. It translates the console's graphics calls to Direct3D 12, its shaders to DXIL, and emulates the console's unified memory on top of separate RAM and VRAM.

This repository is a port of Neptune for one specific setup: an AMD Ryzen CPU with an NVIDIA RTX card. Upstream's build hung the GPU at the first gameplay scene on this machine. The fix is in here, along with a launcher tuned for 32 GB of RAM.

> **No game files are included.** You need your own copy of the game. Shaders are translated on your PC from that copy.

## What changed in this port

| | |
|---|---|
| **GPU hang fixed** | Upstream runs the game's indirect draw arguments unchecked (`VICTORY_INDIRECT_RAW=2`). Some of those records hold garbage, and on this PC one of them hung the GPU before the first gameplay scene. The new mode `VICTORY_INDIRECT_RAW=3` checks each record on the CPU first. Sane records still run directly. Garbage records, and records the GPU writes itself, go through the safe clamp path. This mode is the default here. |
| **32 GB profile** | `-Ram32` shrinks the list pool, the texture staging and the draw data kept on the card. Upstream's switch set was tuned on a 64 GB machine. |
| **GPU hang reports** | `VICTORY_D3D12_DRED=1` (launcher `-Dred`) works in the normal release build. When the GPU fails, the log names the command list, the command it stopped at, and the shaders involved. |
| **Logging** | `-Stats -Tag <name>` writes the log and a memory curve straight to files, without PowerShell in between. |

## Quick start

Requirements: Windows 11, a current GPU driver, a 16 GB graphics card, your own copy of the game.

```powershell
# first run: translates the shaders (about 7 minutes), then starts the game
.\play-zm.ps1 -Game 'D:\path\to\game_scarlett_master.exe' -SeriesX -Ram32 -Warm

# after that
.\play-zm.ps1 -Game 'D:\path\to\game_scarlett_master.exe' -SeriesX -Ram32
```

| Switch | Does |
|---|---|
| `-SeriesX` | the 4K Series X path |
| `-Ram32` | the profile for 32 GB of RAM |
| `-Stats -Tag x` | log and memory samples as `statsx.log` and `memwatchx.csv` |
| `-Dred` | names the failing GPU command when the GPU hangs |
| `-RawIndirect` | upstream's unchecked indirect draws (hung the GPU here) |
| `-Env 'NAME=value;...'` | any extra `VICTORY_*` setting |

Upstream's own launcher is still there as `tools/play.ps1`, with its options for the Series S path, OptiScaler and frame generation.

**Controls:** click the picture or press F9 for mouse look. WASD to move, Enter/Backspace/X/Y for A/B/X/Y. F10 hides the overlay, F12 saves a screenshot.

## Building

Needs Git, the Visual Studio Build Tools (MSVC C++ and a Windows SDK) and [rustup](https://rustup.rs).

```powershell
cargo build --release -p victory
```

The executable lands in `target\release\victory.exe`. Put it in one folder together with `tools\play-zm.ps1` and start the game from there.

## Known limits

- **Lighting:** the game lights rooms and reflections with ray tracing, which no build of this runtime runs yet. An ambient pass stands in for it, so ceilings can stay dark and water can look off.
- **Frame rate:** frames drop while the game streams the world, and frame time jumps while moving fast.
- **Hardware:** tested on one PC only (Ryzen 7 9800X3D, RTX 5070 Ti 16 GB, 32 GB RAM, Windows 11).

## Credits

This port stands entirely on other people's work:

- **Traffic** and **imgone**: Neptune (VIctory Edit.), the base of this port
- **Marvisak/VIctory**: the original runtime
- **myokex/victory-amd**, **fxceless/victory-fork**: the base Neptune builds on
- **soldsawn/victory-nvidia-8gb**: the shader translator
- **Belobug**, **reddxd-byte/ShakiraRED-dt**: the ambient light pass
- **ZSlayerHQ**, **JoshuuDev**, **skornuta**, **Trexies**, and everyone listed in [`docs/NEPTUNE-README.txt`](docs/NEPTUNE-README.txt)
- **zm0kie**: this port

The upstream readmes are kept in [`docs/`](docs/).

## License

GPL-3.0-or-later, see [`LICENSE`](LICENSE). If you pass this on, pass on the source with it.

<div align="center">
<sub>Not affiliated with Rockstar Games, Take-Two Interactive or Microsoft.</sub>
</div>
