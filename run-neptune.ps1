# Neptune HyperEngine by Dolberth (VIctory Fork) — Generic Windows 10/11 Launcher
# Profile tuned for 8 GB NVIDIA GPUs + 6-core Ryzen CPUs + 16 GB RAM (100% standalone native FPS).
#
# Usage:
#   .\run-neptune.ps1 -Title 'D:\Titles\Example\title.exe'
#   .\run-neptune.ps1 -Title 'D:\Titles\Example\title.exe' -TextureMaxDim 2048
#   .\run-neptune.ps1 -Title 'D:\Titles\Example\title.exe' -Window '1600x900'
#   .\run-neptune.ps1 -Title 'D:\Titles\Example\title.exe' -SeriesX

param(
    [Parameter(Mandatory = $true)]
    [string]$Title,
    [string]$Resolution = '1920x1080',
    [string]$Window = 'fullscreen',
    [string]$Ambient = '',
    [switch]$SeriesX,
    [string]$TextureMaxDim = '0',
    [switch]$Taa,
    [switch]$NoThin,
    [switch]$SyncSubmit,
    [switch]$RawIndirect,
    [switch]$WarmShaders,
    [switch]$SkipWarm,
    [switch]$Dred,
    [switch]$BelowNormal,
    [switch]$NoGpuLog
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$exe = Join-Path $root 'target\release\victory.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Error "Binary not found: $exe (run: cargo build --release -p victory)"
    exit 1
}
if (-not (Test-Path -LiteralPath $Title)) {
    Write-Error "Title executable not found: $Title"
    exit 1
}
if (Get-Process -Name victory -ErrorAction SilentlyContinue) {
    Write-Error "victory.exe is already running. Close it before launching a new session."
    exit 1
}

# DirectX 12 Agility SDK 1.620.2 (D3D12\D3D12Core.dll beside victory.exe), needed on Windows 10 AND 11:
# victory.exe asks for SDK version 620, and without the file D3D12 fails with 0x887E0003. Installed from
# Microsoft's official NuGet package (SHA-512 and signature checked) when missing or of another version.
try {
    & (Join-Path $root 'tools\get-agility-sdk.ps1') -ExeDir (Split-Path $exe -Parent)
} catch {
    Write-Error "Could not put the D3D12 Agility SDK in place ($($_.Exception.Message)). See README.md, Requirements and Troubleshooting, to place D3D12\D3D12Core.dll (1.620.2, x64) by hand."
    exit 1
}

$set = [ordered]@{
    # 8 GB VRAM & 16 GB RAM profile (Neptune VRAM Guardian + 8 GB optimizations)
    VICTORY_CARD_WINDOWS_MB          = '512'
    VICTORY_CARD_BUFFERS_MB          = '1024'
    VICTORY_CARD_ROOM_FOR_TARGETS_MB = '512'
    VICTORY_CARD_ROOM_FOR_BUFFERS    = '1'
    VICTORY_TEXTURE_ROOM_PERCENT     = '92'
    VICTORY_TEXTURE_HEAPS            = '1'
    VICTORY_SLOT_EVICT               = '1'
    VICTORY_SLOT_EVICT_PERCENT       = '90'
    VICTORY_SLOT_EVICT_MB            = '256'
    VICTORY_VRAM_EVICT               = '92'
    VICTORY_VRAM_IDLE_MS             = '15000,4000,1500'
    VICTORY_TEXTURE_MAX_DIM          = $TextureMaxDim
    VICTORY_CLAMP_WAITS              = '0'
    VICTORY_RAM_TRIM_MB              = '512'
    VICTORY_LIST_POOL_MB             = '384'
    VICTORY_LIST_POOL_MOST           = '768'
    VICTORY_LIST_POOL_IDLE_S         = '10'
    VICTORY_TEXTURE_STAGE_MB         = '256'
    VICTORY_DSTORAGE_STAGING_MB      = '64'
    VICTORY_LEVELS_ON_DEMAND         = '1'
    VICTORY_DROP_DXIL                = '1'

    # Neptune HyperEngine CPU/GPU pipeline optimizations (worker pools auto-scale by CPU cores inside victory.exe)
    VICTORY_PROCESS_PRIORITY         = 'normal'
    VICTORY_SHADER_META_CACHE        = '1'
    VICTORY_THIN                     = '1'
    VICTORY_WATCH_4K                 = '1'
    VICTORY_GUARD_REST               = '3000'
    VICTORY_RANGED                   = '1'
    VICTORY_INDIRECT_RAW             = $(if ($RawIndirect) { '2' } else { '3' })
    VICTORY_SWEEP_MS                 = '5000'
    VICTORY_INDIRECT_WINDOW          = '1'
    VICTORY_GROUPED_MESH_CLAMP       = '1'
    VICTORY_CLAMP_OVER_DRAWS         = '1'
    VICTORY_SMART_COPY_BACK          = '1'
    VICTORY_SMART_COPY_BACK_KB       = '4'
    VICTORY_RELAY_OWN_QUEUE          = '1'
    VICTORY_RELAY                    = '2'
    VICTORY_COPY_CHANGED             = '1'
    VICTORY_QUIET_BACK               = '1'
    VICTORY_UNDER_WRITES_WORDS       = '1'
    VICTORY_UNDER_WRITES_RUNS        = '4000000'
    VICTORY_UNDER_WRITES_MASKS       = '1'
    VICTORY_UNDER_WRITES_MASKS_LEAST = '1'
    VICTORY_WIDE_MERGE               = '1'
    VICTORY_WIDE_REFRESH             = '1'
    VICTORY_WIDE_BACK                = '1'
    VICTORY_ASK_ONCE                 = '1'
    VICTORY_ASK_QUIET                = '0'
    VICTORY_TEXTURE_NO_WAIT          = '1'
    VICTORY_TEXTURE_HASH_EVERY       = '32'
    VICTORY_CARD_REHASH_RUNS         = '1'
    VICTORY_CARD_REHASH_GAP          = '4'
    VICTORY_CARD_SYNC_BATCH          = '1'
    VICTORY_STEP_INDEX               = '1'
    VICTORY_REFRESH_STAMP            = '0'
    VICTORY_TAA                      = $(if ($Taa) { '1' } else { '0' })
    VICTORY_JOIN_COPIES              = '1'
    VICTORY_WINDOW_TAILS             = '1'
    VICTORY_WINDOW_KB                = '1024'
    VICTORY_WINDOW_REUSE             = '1'
    VICTORY_CARD_BUFFERS_MIN_KB      = '64'
    VICTORY_CARD_WINDOW_UPLOAD       = '1'
    VICTORY_LATE_WAIT_LISTS          = '1024'
    VICTORY_D3D12_BACKGROUND         = '0'
    VICTORY_WAVE_OWN_LDS_GROUPS      = '64,128'

    # Shader cache, visual correctness, streaming and stability
    VICTORY_NAN_GUARD                = '1'
    VICTORY_EARLY_DEPTH              = '1'
    VICTORY_BAKE_TEXTURES_MS         = '10000'
    VICTORY_EARLY_TEXTURES_MS        = '40'
    VICTORY_TEXTURE_BATCH            = '1'
    VICTORY_HEAP_SYNC                = '1'
    VICTORY_DESC_DATA                = '1'
    VICTORY_OCEAN_READBACK           = '1'
    VICTORY_RT_RESOLVE               = '0'
    VICTORY_ACTIVATE_RAYS            = '0'
    VICTORY_PIPELINE_WAIT_MS         = '200'
    VICTORY_TITLE_WATCHDOG           = '0'
    VICTORY_TEARING                  = '1'
    VICTORY_DISCORD                  = '0'
}

$amb = Join-Path $root 'ambient.txt'
if (-not (Test-Path $amb)) { Set-Content -Path $amb -Value '0.36 0.05 0.4 1.0 0.6 0.1 0.45 0.5' -Encoding ascii }
$set['VICTORY_AMBIENT_FILE'] = $amb
if ($Ambient -ne '') { $set['VICTORY_AMBIENT'] = $Ambient }
if ($NoThin) { $set.Remove('VICTORY_THIN') }
if ($Dred) { $set['VICTORY_D3D12_DRED'] = '1' }
if (-not $SyncSubmit) {
    $set['VICTORY_ASYNC_SUBMIT'] = '1'
    $set['VICTORY_ASYNC_PRESENT'] = '1'
}

$console = if ($SeriesX) { @('--console', 'series-x') } else { @('--console', 'series-s') }

Get-ChildItem Env:VICTORY_* -ErrorAction SilentlyContinue | Remove-Item
if ($Resolution -ne '' -and $console[1] -eq 'series-x') { $set['VICTORY_RESOLUTION'] = $Resolution }
if ($Window -ne '') { $set['VICTORY_WINDOW_SIZE'] = $Window }
foreach ($k in $set.Keys) { Set-Item -Path ("Env:$k") -Value $set[$k] }
$env:VICTORY_GAME_DIR = Split-Path -Parent (Resolve-Path -LiteralPath $Title)

# Automatic one-time offline shader warmer (prevents live shader compilation freezes on first launch)
if (-not $SkipWarm) {
    $shaderPack = Join-Path $env:VICTORY_GAME_DIR 'shaders.rpf'
    $cacheDir = Join-Path $env:LOCALAPPDATA 'victory\cache\shaders'
    $stampFile = Join-Path $cacheDir '.warmed-neptune-stamp'
    $packItem = Get-Item -LiteralPath $shaderPack -ErrorAction SilentlyContinue
    $wantStamp = if ($packItem) {
        "neptune-v3-nan-ez:$($packItem.Length):$($packItem.LastWriteTimeUtc.Ticks)"
    } else {
        'neptune-v3-nan-ez:generic'
    }
    $hasStamp = (-not $WarmShaders) -and (Test-Path -LiteralPath $stampFile) -and `
        ((Get-Content -LiteralPath $stampFile -Raw -ErrorAction SilentlyContinue).Trim() -eq $wantStamp)
    if (-not $hasStamp) {
        Write-Output "Warming shader cache offline (first launch only, ~3-5 min; prevents live stutter)..."
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $exe warm
        $warmCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($warmCode -eq 0) {
            New-Item -ItemType Directory -Force $cacheDir | Out-Null
            Set-Content -LiteralPath $stampFile -Value $wantStamp -NoNewline
        } else {
            Write-Warning "Shader warm exited with code $warmCode; continuing to launch."
        }
    } else {
        Write-Output "Shader cache already warmed (use -WarmShaders to force re-warm)."
    }
}

$log = Join-Path $env:TEMP 'neptune-last.log'
$prev = Join-Path $env:TEMP 'neptune-prev.log'
if (Test-Path $log) { Move-Item -Force $log $prev }
if (Test-Path "$log.err") { Move-Item -Force "$log.err" "$prev.err" }

# Real GPU utilization for neptune-diag.ps1 (NVIDIA only: nvidia-smi from PATH, 1 sample/s,
# hidden window, stopped when the session ends). The frame line's "gpu %" is only the time
# the CPU waited for the card. -NoGpuLog skips it.
$gpuCsv = Join-Path $env:TEMP 'neptune-gpu.csv'
$gpuPid = Join-Path $env:TEMP 'neptune-gpu.pid'
if (Test-Path $gpuPid) {
    $old = Get-Content $gpuPid -ErrorAction SilentlyContinue
    if ($old) { Get-Process -Id $old -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'nvidia-smi' } | Stop-Process -Force -ErrorAction SilentlyContinue }
}
$gpuMon = $null
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi -and -not $NoGpuLog) {
    Remove-Item $gpuCsv -ErrorAction SilentlyContinue
    $gpuMon = Start-Process -FilePath $smi.Source -WindowStyle Hidden -PassThru -ArgumentList @(
        '--query-gpu=timestamp,utilization.gpu,utilization.memory,memory.used,memory.total,clocks.sm,power.draw',
        '--format=csv,noheader,nounits', '-lms', '1000', '-f', "`"$gpuCsv`"")
    if ($gpuMon) { Set-Content -Path $gpuPid -Value $gpuMon.Id }
}

$argv = @('run', "`"$Title`"", '--execute') + $console
$p = Start-Process -FilePath $exe -ArgumentList $argv `
    -WorkingDirectory (Split-Path $exe -Parent) `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
    -WindowStyle Normal -PassThru
if ($BelowNormal) { $p.PriorityClass = 'BelowNormal' }
Write-Output "Neptune HyperEngine by Dolberth started (PID $($p.Id), profile=$($console[1]), log=$log.err)"
$p.WaitForExit()
if ($gpuMon -and -not $gpuMon.HasExited) { Stop-Process -Id $gpuMon.Id -Force -ErrorAction SilentlyContinue }
Remove-Item $gpuPid -ErrorAction SilentlyContinue
Write-Output "Neptune HyperEngine by Dolberth exited (code $($p.ExitCode)). Diagnostics: .\neptune-diag.ps1"
