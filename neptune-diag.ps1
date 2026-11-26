# Neptune HyperEngine by Dolberth - Ferramenta de Diagnostico e Telemetria em Tempo Real / Pos-Sessao
# Uso:
#   .\neptune-diag.ps1                       (analisa o log mais novo: %TEMP%\neptune-ultimo.log.err ou %TEMP%\neptune-last.log.err)
#   .\neptune-diag.ps1 -Log 'caminho\log'    (analisa qualquer log)
#   .\neptune-diag.ps1 -AoVivo               (atualiza a cada 3 segundos enquanto voce joga)
#   .\neptune-diag.ps1 -Amostras 20          (media das ultimas 20 linhas do profiler; padrao 10)
# Le tambem %TEMP%\neptune-gpu.csv (uso real da GPU via nvidia-smi, gravado pelos launchers).
param(
    [string]$Log = '',
    [string]$GpuCsv = (Join-Path $env:TEMP 'neptune-gpu.csv'),
    [int]$Amostras = 10,
    [switch]$AoVivo
)

function Get-NewestLog {
    $candidates = @('neptune-ultimo.log.err', 'neptune-last.log.err') |
        ForEach-Object { Join-Path $env:TEMP $_ } |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object { Get-Item -LiteralPath $_ } |
        Sort-Object LastWriteTime -Descending
    if ($candidates) { return @($candidates)[0].FullName }
    return (Join-Path $env:TEMP 'neptune-ultimo.log.err')
}

# Media de cada chave das ultimas $N linhas "neptune profile ms/frame: k=v k=v ..." de frames de mundo.
function Get-Profile([string[]]$Lines, [int]$N) {
    $rows = @()
    foreach ($l in $Lines) {
        if ($l -match 'neptune profile ms/frame:(.*)$') {
            $row = @{}
            foreach ($m in [regex]::Matches($Matches[1], '([a-z_]+)=([0-9.]+)')) {
                $row[$m.Groups[1].Value] = [double]$m.Groups[2].Value
            }
            # Frames de mundo: varias submissoes por frame (menus e carregamento tem 1-5).
            if ($row.ContainsKey('submissions') -and $row['submissions'] -ge 8) { $rows += , $row }
        }
    }
    if ($rows.Count -eq 0) { return $null }
    $recent = @($rows | Select-Object -Last ([Math]::Min($N, $rows.Count)))
    $avg = @{}
    foreach ($k in @($recent[0].Keys)) {
        $avg[$k] = ($recent | ForEach-Object { $_[$k] } | Measure-Object -Average).Average
    }
    $avg['_samples'] = $recent.Count
    return $avg
}

function Write-Bar([string]$Label, [double]$Ms, [double]$Frame, [string]$Extra = '') {
    $width = 30
    $n = 0
    if ($Frame -gt 0) { $n = [int][Math]::Round($width * [Math]::Min(1.0, $Ms / $Frame)) }
    $bar = ('#' * $n).PadRight($width, '.')
    $pct = 0.0
    if ($Frame -gt 0) { $pct = 100.0 * $Ms / $Frame }
    Write-Host ("  {0,-26} {1,7:N1} ms {2,5:N0}%  {3} {4}" -f $Label, $Ms, $pct, $bar, $Extra)
}

function Show-Gpu([string]$Csv) {
    if (-not (Test-Path -LiteralPath $Csv)) {
        Write-Host "  (sem $Csv - abra o jogo por um launcher atualizado para medir a GPU com nvidia-smi)" -ForegroundColor DarkGray
        return
    }
    $rows = @()
    foreach ($line in (Get-Content -LiteralPath $Csv -ErrorAction SilentlyContinue)) {
        $f = $line -split ','
        if ($f.Count -ge 4) {
            $u = 0.0; $mem = 0.0
            if ([double]::TryParse($f[1].Trim(), [ref]$u) -and [double]::TryParse($f[3].Trim(), [ref]$mem)) {
                $rows += [pscustomobject]@{ Util = $u; MemMB = $mem }
            }
        }
    }
    if ($rows.Count -lt 3) { Write-Host "  (amostras de GPU insuficientes ainda)" -ForegroundColor DarkGray; return }
    # A ultima metade da sessao (o mundo), sem o carregamento.
    $tail = @($rows | Select-Object -Last ([Math]::Max(3, [int]($rows.Count / 2))))
    $sorted = @($tail | ForEach-Object { $_.Util } | Sort-Object)
    $p95 = $sorted[[Math]::Min($sorted.Count - 1, [int][Math]::Floor(0.95 * $sorted.Count))]
    $avg = ($tail | ForEach-Object { $_.Util } | Measure-Object -Average).Average
    $memMax = ($tail | ForEach-Object { $_.MemMB } | Measure-Object -Maximum).Maximum
    Write-Host ("  Uso real da GPU (nvidia-smi, {0} amostras): media {1:N0}% | p95 {2:N0}% | VRAM usada max {3:N0} MB" -f $tail.Count, $avg, $p95, $memMax)
    if ($avg -ge 70) {
        Write-Host "  >> GPU quase cheia: cortar CPU sozinho nao sobe muito o FPS; reduza trabalho de GPU (resolucao, VRAM)." -ForegroundColor Yellow
    } elseif ($avg -le 35) {
        Write-Host "  >> GPU ociosa a maior parte do tempo: o limite e a CPU (thread victory-submit) ou esperas/paginacao." -ForegroundColor Yellow
    }
}

# Medidores do Neptune Turbo (neptune-turbo.ps1 -Acao Telemetria): PCIe, RAM/paginacao, GPU por programa, frames.
function Get-Pctl([double[]]$v, [double]$q) {
    if ($v.Count -eq 0) { return 0.0 }
    $s = @($v | Sort-Object)
    $s[[Math]::Min($s.Count - 1, [int][Math]::Floor($q * $s.Count))]
}

function Show-Pc {
    $dir = $env:TEMP
    Write-Host "`n--- PC e barramento (Neptune Turbo) ---" -ForegroundColor Cyan
    $any = $false
    $pcie = Join-Path $dir 'neptune-pcie.csv'
    if (Test-Path -LiteralPath $pcie) {
        $rx = @(); $tx = @()
        foreach ($line in (Get-Content -LiteralPath $pcie -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
            $f = @($line.Trim() -split '\s+')
            if ($f.Count -ge 4) {
                $a = 0.0; $b = 0.0
                if ([double]::TryParse($f[2], [ref]$a) -and [double]::TryParse($f[3], [ref]$b)) { $rx += $a; $tx += $b }
            }
        }
        if ($rx.Count -ge 5) {
            $any = $true
            $half = [Math]::Max(5, [int]($rx.Count / 2))
            $r = @($rx | Select-Object -Last $half); $t = @($tx | Select-Object -Last $half)
            $avg = ($r | Measure-Object -Average).Average
            # PCIe 3.0 x8 (Ryzen 5 5500 + RTX 4060): ~7.880 MB/s por sentido no maximo.
            Write-Host ("  PCIe para a placa: media {0:N0} MB/s | p95 {1:N0} MB/s ({2:N0}% de 7.880 do PCIe 3.0 x8) | da placa: media {3:N0} MB/s" -f $avg, (Get-Pctl $r 0.95), (100 * (Get-Pctl $r 0.95) / 7880), (($t | Measure-Object -Average).Average))
            if ((Get-Pctl $r 0.95) -ge 4000) {
                Write-Host "  >> Barramento cheio: a GPU le geometria/constantes da RAM do PC. Mais janelas na VRAM = mais FPS." -ForegroundColor Yellow
            }
        }
    }
    $sis = Join-Path $dir 'neptune-sistema.csv'
    if (Test-Path -LiteralPath $sis) {
        $rows = @(Import-Csv -LiteralPath $sis -ErrorAction SilentlyContinue)
        if ($rows.Count -ge 5) {
            $any = $true
            $cols = @($rows[0].PSObject.Properties.Name)
            $col = { param($pat) $cols | Where-Object { $_ -like $pat } | Select-Object -First 1 }
            $num = { param($row, $name) $x = 0.0; if ($name -and [double]::TryParse(("" + $row.$name).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { $x } else { $null } }
            $cAvail = & $col '*Available MBytes'; $cIn = & $col '*Pages Input/sec'; $cCpu = & $col '*Processor(_Total)*'; $cGame = & $col '*Process(victory)\% Processor Time'
            $tail = @($rows | Select-Object -Last ([Math]::Max(5, [int]($rows.Count / 2))))
            $avail = @($tail | ForEach-Object { & $num $_ $cAvail } | Where-Object { $null -ne $_ })
            $pin = @($tail | ForEach-Object { & $num $_ $cIn } | Where-Object { $null -ne $_ })
            $cpu = @($tail | ForEach-Object { & $num $_ $cCpu } | Where-Object { $null -ne $_ })
            $game = @($tail | ForEach-Object { & $num $_ $cGame } | Where-Object { $null -ne $_ })
            $cores = [Environment]::ProcessorCount
            if ($avail.Count -gt 0) {
                Write-Host ("  RAM livre: minima {0:N0} MB, media {1:N0} MB | paginas lidas do disco: media {2:N0}/s, pico {3:N0}/s" -f ($avail | Measure-Object -Minimum).Minimum, ($avail | Measure-Object -Average).Average, ($pin | Measure-Object -Average).Average, ($pin | Measure-Object -Maximum).Maximum)
                if (($pin | Measure-Object -Average).Average -ge 500) {
                    Write-Host "  >> Paginacao alta: o jogo espera o disco. Feche programas ou reduza RAM (texturas/janelas)." -ForegroundColor Yellow
                }
            }
            if ($cpu.Count -gt 0) {
                Write-Host ("  CPU: PC {0:N0}% | jogo {1:N1} de {2} threads" -f ($cpu | Measure-Object -Average).Average, ((($game | Measure-Object -Average).Average) / 100), $cores)
            }
        }
    }
    $gp = Join-Path $dir 'neptune-gpu-proc.csv'
    if (Test-Path -LiteralPath $gp) {
        $rows = @(Import-Csv -LiteralPath $gp -ErrorAction SilentlyContinue)
        if ($rows.Count -gt 0) {
            $any = $true
            $amostras = @($rows | Select-Object -ExpandProperty tempo -Unique).Count
            $por = $rows | Group-Object programa | ForEach-Object {
                $s3 = 0.0; $so = 0.0
                foreach ($r in $_.Group) { $s3 += [double]::Parse($r.gpu3d, [Globalization.CultureInfo]::InvariantCulture); $so += [double]::Parse($r.gpuoutros, [Globalization.CultureInfo]::InvariantCulture) }
                [pscustomobject]@{ Programa = $_.Name; Gpu3D = $s3 / [Math]::Max(1, $amostras); Outros = $so / [Math]::Max(1, $amostras) }
            } | Sort-Object { $_.Gpu3D + $_.Outros } -Descending | Select-Object -First 5
            $txt = ($por | ForEach-Object { "{0} {1:N0}%+{2:N0}%" -f $_.Programa, $_.Gpu3D, $_.Outros }) -join ' | '
            Write-Host "  GPU por programa (3D + outros motores, media): $txt"
        }
    }
    $pm = Join-Path $dir 'neptune-presentmon.csv'
    if (Test-Path -LiteralPath $pm) {
        $rows = @(Import-Csv -LiteralPath $pm -ErrorAction SilentlyContinue)
        if ($rows.Count -ge 10) {
            $any = $true
            $cols = @($rows[0].PSObject.Properties.Name)
            $cFrame = $cols | Where-Object { $_ -in @('MsBetweenPresents', 'FrameTime') } | Select-Object -First 1
            $cBusy = $cols | Where-Object { $_ -in @('MsGPUBusy', 'GPUBusy', 'MsGPUActive') } | Select-Object -First 1
            $tail = @($rows | Select-Object -Last ([Math]::Max(10, [int]($rows.Count / 2))))
            $ft = @($tail | ForEach-Object { $x = 0.0; if ([double]::TryParse($_.$cFrame, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { $x } } | Where-Object { $_ -gt 0 })
            if ($ft.Count -gt 0) {
                $avgFt = ($ft | Measure-Object -Average).Average
                $line = "  Frames (PresentMon): {0:N1} FPS medio | frame {1:N1} ms | 1% pior {2:N1} ms" -f (1000 / $avgFt), $avgFt, (Get-Pctl $ft 0.99)
                if ($cBusy) {
                    $gb = @($tail | ForEach-Object { $x = 0.0; if ([double]::TryParse($_.$cBusy, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { $x } })
                    if ($gb.Count -gt 0) { $line += " | GPU ocupada {0:N1} ms/frame" -f ($gb | Measure-Object -Average).Average }
                }
                Write-Host $line
            }
        }
    }
    if (-not $any) { Write-Host "  (sem medidores - abra o jogo pelo jogar-neptune.ps1 com o Neptune Turbo)" -ForegroundColor DarkGray }
}

function Show-Report([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Log nao encontrado: $Path" -ForegroundColor Red
        return
    }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { Write-Host "Log vazio."; return }
    $esc = [char]27
    $clean = [regex]::Replace($raw, "$esc\[[0-9;]*m", '')
    $lines = $clean -split "`r?`n"

    $world = @()
    foreach ($l in $lines) {
        if ($l -match '([0-9.]+) fps, ([0-9.]+) ms/frame \(([0-9.]+) preparing: copies ([0-9.]+) ms ([0-9.]+) MB, textures ([0-9.]+) ms ([0-9.]+) MB; ([0-9.]+) on the GPU; ([0-9.]+) copying back ([0-9.]+) MB\), ([0-9]+) draws/frame') {
            $draws = [int]$Matches[11]
            if ($draws -ge 300) {
                $world += [pscustomobject]@{
                    Fps = [double]$Matches[1]; FrameMs = [double]$Matches[2]
                    PrepMs = [double]$Matches[3]; CopyMs = [double]$Matches[4]; CopyMB = [double]$Matches[5]
                    TexMs = [double]$Matches[6]; TexMB = [double]$Matches[7]
                    GpuMs = [double]$Matches[8]; BackMs = [double]$Matches[9]; BackMB = [double]$Matches[10]
                    Draws = $draws
                }
            }
        }
    }

    $lastRam   = ($lines | Where-Object { $_ -match 'ram line:' } | Select-Object -Last 1)
    $lastTurbo = ($lines | Where-Object { $_ -match 'Neptune HyperEngine:' } | Select-Object -Last 1)
    $lastSmart = ($lines | Where-Object { $_ -match 'smart copy-back' } | Select-Object -Last 1)
    $lastThin  = ($lines | Where-Object { $_ -match 'list calls translated' } | Select-Object -Last 1)
    $lastHeap  = ($lines | Where-Object { $_ -match 'the pass over the heap per frame' } | Select-Object -Last 1)
    $lastClock = ($lines | Where-Object { $_ -match "the card's clock per frame" } | Select-Object -Last 1)
    $lastBig   = ($lines | Where-Object { $_ -match 'big textures the title fills' } | Select-Object -Last 1)
    $lastClamp = ($lines | Where-Object { $_ -match 'indirect records per frame:' } | Select-Object -Last 1)
    $lastRaw   = ($lines | Where-Object { $_ -match 'single draws per frame:' } | Select-Object -Last 1)
    $lastSweep = ($lines | Where-Object { $_ -match 'of the waiting for the card in settles' } | Select-Object -Last 1)
    $lastWinRef = ($lines | Where-Object { $_ -match 'windows outside buffers turned down for the card' } | Select-Object -Last 1)
    $lastCards = ($lines | Where-Object { $_ -match "host copies in the card's memory: [0-9]+ copies" } | Select-Object -Last 1)
    $ooms      = ($lines | Where-Object { $_ -match '0x8007000E|out of memory|device removed|0x887A0006' }).Count
    $shaders   = ($lines | Where-Object { $_ -match 'shader translated' }).Count

    Clear-Host
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "   NEPTUNE HYPERENGINE - DIAGNOSTICO DE FPS, SHADERS & TEXTURAS   " -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "Log: $Path ($($lines.Count) linhas) | Shaders traduzidos: $shaders | Erros criticos/OOM: $ooms"

    $rMs = 0.0
    if ($world.Count -eq 0) {
        Write-Host "`nAinda carregando (nenhum frame de mundo >300 draws registrado ainda)." -ForegroundColor Yellow
        $lastFps = ($lines | Where-Object { $_ -match 'host: [0-9.]+ fps,' } | Select-Object -Last 1)
        if ($lastFps) { Write-Host ("Ultimo frame: " + ($lastFps -replace '.*host: ', '')) }
    } else {
        $avgFps  = ($world.Fps | Measure-Object -Average).Average
        $maxFps  = ($world.Fps | Measure-Object -Maximum).Maximum
        $minFps  = ($world.Fps | Measure-Object -Minimum).Minimum
        $recent  = @($world | Select-Object -Last ([Math]::Min(10, $world.Count)))
        $rMs     = ($recent.FrameMs | Measure-Object -Average).Average
        $rPrep   = ($recent.PrepMs | Measure-Object -Average).Average
        $rCopy   = ($recent.CopyMs | Measure-Object -Average).Average
        $rCopyMB = ($recent.CopyMB | Measure-Object -Average).Average
        $rTex    = ($recent.TexMs | Measure-Object -Average).Average
        $rTexMB  = ($recent.TexMB | Measure-Object -Average).Average
        $rBack   = ($recent.BackMs | Measure-Object -Average).Average
        $rBackMB = ($recent.BackMB | Measure-Object -Average).Average
        $rDraws  = ($recent.Draws | Measure-Object -Average).Average

        Write-Host ("`nFPS NO MUNDO ({0} amostras):  Media {1:N1} FPS  |  Pico {2:N1} FPS  |  Min {3:N1} FPS" -f $world.Count, $avgFps, $maxFps, $minFps) -ForegroundColor Green
        Write-Host ("Frame medio recente: {0:N1} ms  ({1:N0} draws/frame)" -f $rMs, $rDraws)
        Write-Host ("  - Preparing (CPU):  {0,6:N1} ms  (copies {1:N1} ms / {2:N1} MB | textures {3:N1} ms / {4:N1} MB)" -f $rPrep, $rCopy, $rCopyMB, $rTex, $rTexMB)
        Write-Host ("  - Copy-back:        {0,6:N1} ms  ({1:N1} MB, thread propria: sobrepoe o frame)" -f $rBack, $rBackMB)
        if ($lastClock -and $lastClock -match 'nothing of ours queued ([0-9.]+) ms \(the card about ([0-9]+)% busy') {
            Write-Host ("  - Fila da GPU:      ocupada ~{0}% do frame (relogio da placa; o 'gpu %' da linha de frame e so a espera da CPU)" -f $Matches[2])
        }
    }

    $prof = Get-Profile $lines $Amostras
    if ($prof) {
        $g = { param($k) if ($prof.ContainsKey($k)) { [double]$prof[$k] } else { 0.0 } }
        $frame = $rMs
        if ($frame -le 0) { $frame = (& $g 'lines') + (& $g 'idle') }
        $steps = (& $g 'step_copy') + (& $g 'step_fill') + (& $g 'step_run') + (& $g 'step_host') + (& $g 'step_gpu_write') + (& $g 'step_texture') + (& $g 'step_loop')
        $prep = (& $g 'ask_once') + $steps + (& $g 'refresh') + (& $g 'snapshots') + (& $g 'card_before') + (& $g 'execute') + (& $g 'tail')
        Write-Host ("`n--- Caminho critico: thread victory-submit, ms/frame (media de {0} linhas do profiler) ---" -f $prof['_samples']) -ForegroundColor Cyan
        Write-Host ("  ocupada {0:N1} ms | ociosa {1:N1} ms | {2:N1} submissoes/frame | {3:N0} passos/frame" -f (& $g 'lines'), (& $g 'idle'), (& $g 'submissions'), (& $g 'steps'))
        $syncExtra = "(watch {0:N1} | paginas {1:N1} | espelho {2:N1} CPU; {3:N0} registros)" -f (& $g 'sync_watch'), (& $g 'sync_pages'), (& $g 'sync_mirror'), (& $g 'sync_mirrored')
        $parts = @(
            , @('espera do passe ahead', (& $g 'wait_ahead'), '')
            , @('sync_heaps', (& $g 'sync_heaps'), $syncExtra)
            , @('preparing (soma)', $prep, '')
            , @('  ask_once', (& $g 'ask_once'), '')
            , @('  refresh (copias)', (& $g 'refresh'), '')
            , @('  passos: copy', (& $g 'step_copy'), '')
            , @('  passos: fill', (& $g 'step_fill'), '')
            , @('  passos: run', (& $g 'step_run'), '')
            , @('  passos: host', (& $g 'step_host'), '')
            , @('  passos: gpu_write', (& $g 'step_gpu_write'), '')
            , @('  passos: texturas', (& $g 'step_texture'), '')
            , @('  passos: laco', (& $g 'step_loop'), '')
            , @('  snapshots', (& $g 'snapshots'), '')
            , @('  card_before', (& $g 'card_before'), '')
            , @('  execute+tail', ((& $g 'execute') + (& $g 'tail')), '')
            , @('settles (antes+meio)', ((& $g 'settle') + (& $g 'settle_mid')), '')
            , @('sweep+make_waiting+misc', ((& $g 'sweep') + (& $g 'make_waiting') + (& $g 'pre_misc')), '')
            , @('late_tail (fila/relay)', (& $g 'late_tail'), '')
            , @('submissoes sincronas', (& $g 'sync_wait'), '')
            , @('present', (& $g 'present'), '')
            , @('espera traducoes (THIN)', (& $g 'wait_translations'), '')
        )
        foreach ($p in $parts) { Write-Bar $p[0] $p[1] $frame $p[2] }
        Write-Host "--- Thread victory-ahead (passe sobre as views do heap) ---" -ForegroundColor Cyan
        Write-Host ("  plano {0:N1} | slots {1:N1} ({2:N0} slots) | spans+refresh {3:N1} | texturas {4:N1} ms/frame" -f (& $g 'ahead_plan'), (& $g 'ahead_slots'), (& $g 'ahead_due'), (& $g 'ahead_spans'), (& $g 'ahead_textures'))
        $top = @($parts | Where-Object { $_[0] -notlike '  *' -and $_[0] -ne 'preparing (soma)' } | Sort-Object { $_[1] } -Descending)[0]
        $topPrep = @($parts | Where-Object { $_[0] -like '  *' } | Sort-Object { $_[1] } -Descending)[0]
        Write-Host ("`n>> MAIOR OFENSOR: {0} ({1:N1} ms) | dentro do preparing: {2} ({3:N1} ms)" -f $top[0], $top[1], $topPrep[0].Trim(), $topPrep[1]) -ForegroundColor Yellow
    } elseif ($world.Count -gt 0) {
        Write-Host "`n(sem linhas 'neptune profile' - executavel anterior ao profiler de sub-etapas)" -ForegroundColor DarkGray
    }

    Write-Host "`n--- GPU ---" -ForegroundColor Cyan
    Show-Gpu $GpuCsv
    Show-Pc

    Write-Host "`n--- Motores Neptune HyperEngine ---" -ForegroundColor Cyan
    if ($lastTurbo) { Write-Host ("  " + ($lastTurbo -replace '.*turbo: ', '')) }
    if ($lastSmart) { Write-Host ("  " + ($lastSmart -replace '.*smart_back: ', '')) }
    if ($lastThin)  { Write-Host ("  " + ($lastThin  -replace '.*thin: ', '')) }
    if ($lastHeap)  { $h = ($lastHeap -replace '.*host: ', ''); Write-Host ("  " + $h.Substring(0, [Math]::Min(160, $h.Length))) }
    if ($lastClamp -and $lastClamp -match '([0-9]+) clamped ahead.*?([0-9]+) clamped in place.*?([0-9]+) drawn as the title wrote them') {
        $clampText = "  Draws indiretos/frame: {0} clamp no preludio | {1} clamp no meio da lista | {2} desenhados crus" -f $Matches[1], $Matches[2], $Matches[3]
        if ($lastClamp -match 'clamp passes in the middle of lists per frame: ([0-9.]+), grouped mesh clamp batches ([0-9.]+)') {
            $clampText += " | passes de clamp {0} + lotes mesh {1} (cada um = 2 esperas da GPU)" -f $Matches[1], $Matches[2]
        }
        if ($lastClamp -match 'stayed open over ([0-9.]+)') {
            $clampText += " | draws diretos sem fechar o lote {0} (VICTORY_CLAMP_OVER_DRAWS)" -f $Matches[1]
        }
        Write-Host $clampText
    }
    if ($lastRaw -and $lastRaw -match '([0-9]+) raw \(record checked on the CPU\), ([0-9]+) clamped \(shaders may write') {
        Write-Host ("  Draws simples (RAW=3/4): {0} crus checados na CPU | {1} com registro escrito por shader (crus so com -Rapido)" -f $Matches[1], $Matches[2])
    }
    if ($lastCards -and $lastCards -match "card's memory: ([0-9]+) copies ([0-9]+) MB") {
        $cardText = "  Copias na VRAM (buffers + janelas): {0} copias, {1} MB" -f $Matches[1], $Matches[2]
        if ($lastWinRef -and $lastWinRef -match 'so far \(.*?\): ([0-9]+) \(([0-9]+) MB\)') {
            $cardText += " | janelas que ficaram na RAM (lidas pelo PCIe): {0} ({1} MB)" -f $Matches[1], $Matches[2]
        }
        Write-Host $cardText
    }
    if ($lastSweep -and $lastSweep -match 'a synchronous submission or present ([0-9.]+) ms') {
        Write-Host ("  GPU esvaziada para a limpeza (sweep) / sincrono: {0} ms/frame em media (VICTORY_SWEEP_MS)" -f $Matches[1])
    }

    if ($lastRam) {
        Write-Host "`n--- Memoria (RAM & VRAM) ---" -ForegroundColor Cyan
        if ($lastRam -match 'process working set ([0-9]+) MB, private ([0-9]+) MB; PC free ([0-9]+) MB') {
            Write-Host ("  RAM: processo {0} MB (privado/commit {1} MB) | Livre no PC: {2} MB" -f $Matches[1], $Matches[2], $Matches[3])
        }
        if ($lastRam -match 'card \(VRAM\) ([0-9]+) MB in use of ([0-9]+) MB budget, shared ([0-9]+) MB in use') {
            Write-Host ("  VRAM: {0} / {1} MB | Compartilhada (RAM do sistema usada pela GPU): {2} MB" -f $Matches[1], $Matches[2], $Matches[3])
        }
        if ($lastRam -match 'evicted under pressure ([0-9]+) ([0-9]+) MB') {
            Write-Host ("  Evictions por pressao VRAM: {0} texturas ({1} MB)" -f $Matches[1], $Matches[2])
        }
        if ($lastRam -match 'windows outside buffers ([0-9]+) ([0-9]+) MB') {
            Write-Host ("  Janelas fora de buffers (copias da memoria do jogo): {0} ({1} MB)" -f $Matches[1], $Matches[2])
        }
    }
    if ($lastBig -and $lastBig -match ': ([0-9]+) textures ([0-9]+) MB, their first levels ([0-9]+) MB.*XOR mode ([0-9]+) textures ([0-9]+) MB') {
        Write-Host ("  Texturas grandes (>=2048, inteiras na VRAM): {0} ({1} MB); mip 0 delas = {2} MB (economia maxima de um corte do mip 0); XOR: {3} ({4} MB)" -f $Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5])
    }
    Write-Host "==================================================================" -ForegroundColor Cyan
}

if ($Log -eq '') { $Log = Get-NewestLog }
if ($AoVivo) {
    while ($true) {
        Show-Report $Log
        Write-Host "(Atualizando a cada 3s - Ctrl+C para sair)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
    }
} else {
    Show-Report $Log
}
