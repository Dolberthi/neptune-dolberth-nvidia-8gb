# Neptune Turbo - deixa o PC leve para o Neptune_VI e mede a sessao inteira (CPU, RAM, GPU, PCIe, frames).
#
# Uso:
#   .\neptune-turbo.ps1                          Status: o que esta pesando no PC agora (CPU, RAM, GPU por programa)
#   .\neptune-turbo.ps1 -Acao Preparar           Antes do jogo: plano de energia de alto desempenho, fecha programas
#                                                pesados (NVIDIA Broadcast), rebaixa a prioridade de CPU/memoria dos
#                                                programas de fundo e devolve a RAM deles ao Windows
#   .\neptune-turbo.ps1 -Acao Restaurar          Depois do jogo: desfaz tudo e reabre o que foi fechado
#   .\neptune-turbo.ps1 -Acao Telemetria -JogoPid <pid>   Liga os medidores (PCIe, RAM/paginacao, GPU por programa, frames)
#   .\neptune-turbo.ps1 -Acao Telemetria -JogoPid <pid> -Leve   So RAM/paginacao/CPU (typeperf), quase sem custo
#   .\neptune-turbo.ps1 -Acao PararTelemetria
#
# Tudo o que e mudado fica anotado em %TEMP%\neptune-turbo-estado.json e e desfeito pelo Restaurar.
# Nada e mudado no jogo (o processo do jogo fica na prioridade normal) nem em servicos do sistema.
param(
    [ValidateSet('Status', 'Preparar', 'Restaurar', 'Telemetria', 'PararTelemetria')]
    [string]$Acao = 'Status',
    [int]$JogoPid = 0,
    [string[]]$Fechar = @('NVIDIA Broadcast', 'NVIDIA Broadcast UI'),
    [switch]$NaoFechar,
    [switch]$NaoReabrir,
    [switch]$NaoRebaixar,
    [switch]$NaoLimparRam,
    [switch]$NaoEnergia,
    [switch]$NaoGameDvr,
    [switch]$Leve
)

$ErrorActionPreference = 'Continue'
$estadoPath = Join-Path $env:TEMP 'neptune-turbo-estado.json'
$telePath = Join-Path $env:TEMP 'neptune-telemetria.json'

# Programas que nunca sao tocados: sistema, janela/compositor, audio, shell, consoles, o jogo e os medidores.
$protegidos = @(
    'idle', 'system', 'registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'lsaiso', 'svchost',
    'fontdrvhost', 'dwm', 'audiodg', 'explorer', 'sihost', 'ctfmon', 'taskhostw', 'runtimebroker',
    'shellexperiencehost', 'startmenuexperiencehost', 'searchapp', 'searchui', 'searchhost', 'textinputhost',
    'applicationframehost', 'lockapp', 'securityhealthsystray', 'securityhealthservice', 'msmpeng', 'conhost',
    'openconsole', 'windowsterminal', 'powershell', 'pwsh', 'cmd', 'victory', 'nvidia-smi', 'presentmon',
    'typeperf', 'nvdisplay.container', 'nvcontainer', 'wudfhost', 'dllhost', 'wmiprvse', 'spoolsv', 'sunshine'
)

# Os processos acima deste script (o atalho/lancador que abriu o jogo) tambem ficam como estao.
function Get-Ancestrais {
    $pais = @{}
    Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue |
        ForEach-Object { $pais[[int]$_.ProcessId] = [int]$_.ParentProcessId }
    $cadeia = @()
    $atual = $PID
    for ($i = 0; $i -lt 16 -and $pais.ContainsKey($atual); $i++) {
        $atual = $pais[$atual]
        if ($atual -le 4 -or $cadeia -contains $atual) { break }
        $cadeia += $atual
    }
    $cadeia
}

if (-not ('NeptuneTurboNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NeptuneTurboNative {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetProcessInformation(IntPtr h, int cls, ref uint info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessInformation(IntPtr h, int cls, ref uint info, uint size);
    [DllImport("psapi.dll", SetLastError = true)] static extern bool EmptyWorkingSet(IntPtr h);
    const uint SET_INFORMATION = 0x0200, QUERY_LIMITED = 0x1000, SET_QUOTA = 0x0100, QUERY_INFORMATION = 0x0400;
    const int ProcessMemoryPriority = 0;
    // Memory priority of a process (1 very low .. 5 normal), -1 when it cannot be read.
    public static int GetMemoryPriority(int pid) {
        IntPtr h = OpenProcess(QUERY_LIMITED, false, pid);
        if (h == IntPtr.Zero) return -1;
        try { uint p = 0; return GetProcessInformation(h, ProcessMemoryPriority, ref p, 4) ? (int)p : -1; }
        finally { CloseHandle(h); }
    }
    public static bool SetMemoryPriority(int pid, uint priority) {
        IntPtr h = OpenProcess(SET_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return false;
        try { uint p = priority; return SetProcessInformation(h, ProcessMemoryPriority, ref p, 4); }
        finally { CloseHandle(h); }
    }
    // Gives the process' working set back to the system (its pages go to the standby list).
    public static bool Trim(int pid) {
        IntPtr h = OpenProcess(SET_QUOTA | QUERY_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return false;
        try { return EmptyWorkingSet(h); }
        finally { CloseHandle(h); }
    }
}
'@
}

function Get-RamLivreMB {
    [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
}

function Get-PlanoAtivo {
    $linha = (powercfg /getactivescheme) 2>$null | Select-Object -First 1
    if ($linha -match '([0-9a-fA-F-]{36})') { $Matches[1].ToLower() } else { $null }
}

function Test-Protegido([System.Diagnostics.Process]$p, [int]$sessao, [int[]]$ancestrais = @()) {
    if ($p.Id -eq $PID -or $p.Id -eq $JogoPid -or $p.Id -le 4 -or $ancestrais -contains $p.Id) { return $true }
    if ($p.SessionId -ne $sessao) { return $true }
    return $protegidos -contains $p.ProcessName.ToLower()
}

# Uso de GPU por programa (motor 3D e os outros motores), uma amostra.
function Get-GpuPorPrograma {
    $amostra = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue
    if (-not $amostra) { return @() }
    $porPid = @{}
    foreach ($s in $amostra.CounterSamples) {
        if ($s.InstanceName -match 'pid_(\d+)_.*engtype_(\w+)') {
            $id = [int]$Matches[1]
            if (-not $porPid.ContainsKey($id)) { $porPid[$id] = @{ '3d' = 0.0; 'outros' = 0.0 } }
            if ($Matches[2] -eq '3d') { $porPid[$id]['3d'] += $s.CookedValue } else { $porPid[$id]['outros'] += $s.CookedValue }
        }
    }
    $porPid.GetEnumerator() | ForEach-Object {
        $nome = (Get-Process -Id $_.Key -ErrorAction SilentlyContinue).ProcessName
        [pscustomobject]@{ Programa = $(if ($nome) { $nome } else { "pid $($_.Key)" }); Pid = $_.Key
            Gpu3D = [math]::Round($_.Value['3d'], 1); GpuOutros = [math]::Round($_.Value['outros'], 1) }
    } | Where-Object { $_.Gpu3D + $_.GpuOutros -ge 0.5 } | Sort-Object { $_.Gpu3D + $_.GpuOutros } -Descending
}

function Show-Status {
    $os = Get-CimInstance Win32_OperatingSystem
    $livre = [math]::Round($os.FreePhysicalMemory / 1KB)
    $total = [math]::Round($os.TotalVisibleMemorySize / 1KB)
    $commit = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1KB)
    Write-Host "=== Neptune Turbo: estado do PC ===" -ForegroundColor Cyan
    Write-Host ("RAM livre {0:N0} MB de {1:N0} MB | memoria comprometida {2:N0} MB" -f $livre, $total, $commit)
    $plano = Get-PlanoAtivo
    $nomePlano = ((powercfg /getactivescheme) 2>$null | Select-Object -First 1) -replace '.*\(|\).*', ''
    Write-Host "Plano de energia: $nomePlano ($plano)"
    # CPU por programa: tempo de CPU em 1 s
    $antes = @{}
    Get-Process | ForEach-Object { try { $antes[$_.Id] = $_.TotalProcessorTime.TotalMilliseconds } catch { } }
    Start-Sleep -Milliseconds 1000
    $cpu = Get-Process | ForEach-Object {
        try {
            if ($antes.ContainsKey($_.Id)) {
                [pscustomobject]@{ Programa = $_.ProcessName; Pid = $_.Id
                    Nucleos = [math]::Round(($_.TotalProcessorTime.TotalMilliseconds - $antes[$_.Id]) / 1000, 2)
                    RamMB = [math]::Round($_.WorkingSet64 / 1MB) }
            }
        } catch { }
    } | Sort-Object Nucleos -Descending | Select-Object -First 8
    Write-Host "`nCPU (nucleos usados no ultimo segundo):" -ForegroundColor Cyan
    $cpu | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "RAM (maiores working sets):" -ForegroundColor Cyan
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 |
        ForEach-Object { "  {0,-28} {1,7:N0} MB" -f $_.ProcessName, ($_.WorkingSet64 / 1MB) } | Write-Host
    Write-Host "`nGPU por programa (% de motor, uma amostra):" -ForegroundColor Cyan
    $gpu = @(Get-GpuPorPrograma | Select-Object -First 8)
    if ($gpu.Count -eq 0) { Write-Host "  (nenhum uso de GPU visivel)" } else { $gpu | Format-Table -AutoSize | Out-String | Write-Host }
    $pesados = Get-Process -Name $Fechar -ErrorAction SilentlyContinue
    if ($pesados) { Write-Host ("Pesados abertos (o Preparar fecha): " + (($pesados | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')) -ForegroundColor Yellow }
}

function Invoke-Preparar {
    $sessao = (Get-Process -Id $PID).SessionId
    $estado = [ordered]@{ quando = (Get-Date).ToString('s'); ramAntes = Get-RamLivreMB; plano = $null
        fechados = @(); reabrir = @(); processos = @(); dvr = @(); aparados = 0 }

    if (-not $NaoEnergia) {
        $atual = Get-PlanoAtivo
        $lista = (powercfg /list) 2>$null
        $alvo = $null
        foreach ($g in @('e9a42b02-d5df-448d-aa00-03f14749eb61', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')) {
            if (-not $alvo -and ($lista -match $g)) { $alvo = $g }
        }
        # So troca planos de economia (Equilibrado / Economia de energia); um plano proprio fica.
        $economia = @('381b4222-f694-41f0-9685-ff5bb260df2e', 'a1841308-3541-4fab-bc81-f71556f20b4a')
        if ($alvo -and $atual -and ($economia -contains $atual)) {
            powercfg /setactive $alvo 2>$null | Out-Null
            if ((Get-PlanoAtivo) -eq $alvo) { $estado.plano = $atual; Write-Host "Energia: plano de alto desempenho ligado (volta ao anterior depois)." }
        }
    }

    if (-not $NaoFechar) {
        foreach ($p in @(Get-Process -Name $Fechar -ErrorAction SilentlyContinue)) {
            $caminho = $null
            try { $caminho = $p.Path } catch { }
            if ($caminho -and ($estado.reabrir -notcontains $caminho) -and ($p.ProcessName -notmatch ' UI$')) { $estado.reabrir += $caminho }
            $estado.fechados += $p.ProcessName
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        if ($estado.fechados.Count -gt 0) { Write-Host ("Fechados durante o jogo: " + (($estado.fechados | Select-Object -Unique) -join ', ')) }
    }

    if (-not $NaoGameDvr) {
        $chaves = @(
            @('HKCU:\System\GameConfigStore', 'GameDVR_Enabled'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled'),
            @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'HistoricalCaptureEnabled')
        )
        foreach ($c in $chaves) {
            $v = (Get-ItemProperty -Path $c[0] -Name $c[1] -ErrorAction SilentlyContinue).($c[1])
            if ($v -eq 1) {
                Set-ItemProperty -Path $c[0] -Name $c[1] -Value 0 -ErrorAction SilentlyContinue
                $estado.dvr += [ordered]@{ chave = $c[0]; nome = $c[1]; valor = 1 }
            }
        }
        if ($estado.dvr.Count -gt 0) { Write-Host "Gravacao em segundo plano do Windows (Game DVR) desligada durante o jogo." }
    }

    if (-not $NaoRebaixar) {
        $ancestrais = @(Get-Ancestrais)
        foreach ($p in Get-Process) {
            if (Test-Protegido $p $sessao $ancestrais) { continue }
            $classe = $null
            try { $classe = $p.PriorityClass } catch { continue }
            if ($null -eq $classe) { continue }
            $mem = [NeptuneTurboNative]::GetMemoryPriority($p.Id)
            $registro = [ordered]@{ pid = $p.Id; nome = $p.ProcessName; inicio = $null; classe = "$classe"; memoria = $mem }
            # Ticks (numero): o ConvertFrom-Json do PowerShell 5.1 transforma texto de data em DateTime.
            try { $registro.inicio = $p.StartTime.Ticks } catch { }
            $mudou = $false
            if ($classe -eq 'Normal' -or $classe -eq 'AboveNormal') {
                try { $p.PriorityClass = 'BelowNormal'; $mudou = $true } catch { }
            }
            if ($mem -gt 2 -and [NeptuneTurboNative]::SetMemoryPriority($p.Id, 2)) { $mudou = $true }
            if ($mudou) { $estado.processos += $registro }
            if (-not $NaoLimparRam -and [NeptuneTurboNative]::Trim($p.Id)) { $estado.aparados++ }
        }
        Write-Host ("Programas de fundo rebaixados (CPU abaixo do normal, memoria baixa): {0}; working sets devolvidos: {1}" -f $estado.processos.Count, $estado.aparados)
    }

    $estado.ramDepois = Get-RamLivreMB
    Write-Host ("RAM livre: {0:N0} MB -> {1:N0} MB" -f $estado.ramAntes, $estado.ramDepois)
    $estado | ConvertTo-Json -Depth 5 | Set-Content -Path $estadoPath -Encoding UTF8
}

function Invoke-Restaurar {
    if (-not (Test-Path $estadoPath)) { Write-Host "Neptune Turbo: nada para restaurar."; return }
    $estado = Get-Content $estadoPath -Raw | ConvertFrom-Json
    if ($estado.plano) { powercfg /setactive $estado.plano 2>$null | Out-Null; Write-Host "Energia: plano anterior de volta." }
    $voltaram = 0
    foreach ($r in @($estado.processos)) {
        if (-not $r) { continue }
        $p = Get-Process -Id $r.pid -ErrorAction SilentlyContinue
        if (-not $p -or $p.ProcessName -ne $r.nome) { continue }
        try { if ($r.inicio -and $p.StartTime.Ticks -ne [long]$r.inicio) { continue } } catch { }
        try { if ($r.classe -and $p.PriorityClass -eq 'BelowNormal') { $p.PriorityClass = $r.classe } } catch { }
        if ($r.memoria -ge 1) { [void][NeptuneTurboNative]::SetMemoryPriority($r.pid, [uint32]$r.memoria) }
        $voltaram++
    }
    Write-Host "Prioridades restauradas: $voltaram programas."
    foreach ($d in @($estado.dvr)) { if ($d) { Set-ItemProperty -Path $d.chave -Name $d.nome -Value $d.valor -ErrorAction SilentlyContinue } }
    if (-not $NaoReabrir) {
        foreach ($c in @($estado.reabrir)) {
            if (-not $c -or -not (Test-Path -LiteralPath $c)) { continue }
            $aberto = Get-Process | Where-Object { try { $_.Path -eq $c } catch { $false } }
            if (-not $aberto) {
                Start-Process -FilePath $c -WindowStyle Minimized -ErrorAction SilentlyContinue
                Write-Host "Reaberto: $c"
            }
        }
    }
    Move-Item -Force $estadoPath "$estadoPath.bak" -ErrorAction SilentlyContinue
}

function Invoke-PararTelemetria([switch]$Silencioso) {
    if (Test-Path $telePath) {
        $t = Get-Content $telePath -Raw | ConvertFrom-Json
        foreach ($id in @($t.pids)) {
            $p = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -match '^(nvidia-smi|typeperf|powershell|presentmon)') { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item $telePath -ErrorAction SilentlyContinue
        if (-not $Silencioso) { Write-Host "Telemetria parada." }
    }
}

function Start-Telemetria {
    if ($JogoPid -le 0) { Write-Host "Telemetria: falta -JogoPid"; return }
    Invoke-PararTelemetria -Silencioso
    $t = [ordered]@{ pids = @() }
    $pcie = Join-Path $env:TEMP 'neptune-pcie.csv'
    $sis = Join-Path $env:TEMP 'neptune-sistema.csv'
    $gpuProc = Join-Path $env:TEMP 'neptune-gpu-proc.csv'
    $pm = Join-Path $env:TEMP 'neptune-presentmon.csv'
    Remove-Item $pcie, $sis, $gpuProc, $pm -ErrorAction SilentlyContinue

    # 1. Trafego PCIe da placa (MB/s recebidos/enviados), 1 amostra/s, gravado pelo amostrador do item 3
    #    (nvidia-smi dmon guarda a saida em buffer e a perde se for encerrado: roda em blocos de 5 s).
    # 2. RAM livre, paginacao (paginas lidas do disco/s), CPU total e do jogo, a cada 2 s.
    $contadores = @('\Memory\Available MBytes', '\Memory\Pages Input/sec', '\Memory\Committed Bytes',
        '\Processor(_Total)\% Processor Time', '\Process(victory)\% Processor Time', '\Process(victory)\Working Set')
    $argsTp = @($contadores | ForEach-Object { "`"$_`"" }) + @('-si', '2', '-f', 'CSV', '-o', "`"$sis`"", '-y')
    $p = Start-Process -FilePath 'typeperf.exe' -WindowStyle Hidden -PassThru -ArgumentList $argsTp
    if ($p) { $t.pids += $p.Id }
    if ($Leve) {
        $t | ConvertTo-Json | Set-Content -Path $telePath -Encoding UTF8
        Write-Host "Telemetria leve ligada: RAM/paginacao/CPU."
        return
    }
    # 3. GPU por programa a cada ~5 s (quem mais usa a placa alem do jogo) e o PCIe do item 1.
    $amostrador = Join-Path $env:TEMP 'neptune-gpu-proc.ps1'
    @'
param([string]$Out, [int]$JogoPid, [string]$Pcie)
"tempo,programa,pid,gpu3d,gpuoutros" | Set-Content -Path $Out -Encoding ASCII
$smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
while (Get-Process -Id $JogoPid -ErrorAction SilentlyContinue) {
    $a = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue
    if ($a) {
        $por = @{}
        foreach ($s in $a.CounterSamples) {
            if ($s.InstanceName -match 'pid_(\d+)_.*engtype_(\w+)') {
                $id = [int]$Matches[1]
                if (-not $por.ContainsKey($id)) { $por[$id] = @(0.0, 0.0) }
                if ($Matches[2] -eq '3d') { $por[$id][0] += $s.CookedValue } else { $por[$id][1] += $s.CookedValue }
            }
        }
        $agora = (Get-Date).ToString('HH:mm:ss')
        $linhas = foreach ($k in $por.Keys) {
            if ($por[$k][0] + $por[$k][1] -ge 0.5) {
                $n = (Get-Process -Id $k -ErrorAction SilentlyContinue).ProcessName
                [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0},{1},{2},{3:F1},{4:F1}', $agora, $n, $k, $por[$k][0], $por[$k][1])
            }
        }
        if ($linhas) { Add-Content -Path $Out -Value $linhas -Encoding ASCII }
    }
    if ($smi) {
        # 5 amostras de 1 s do trafego PCIe (rxpci = para a placa, txpci = da placa), sem os cabecalhos.
        $pc = & $smi dmon -s t -c 5 -o T 2>$null | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }
        if ($pc) { Add-Content -Path $Pcie -Value $pc -Encoding ASCII }
    } else {
        Start-Sleep -Seconds 5
    }
}
'@ | Set-Content -Path $amostrador -Encoding ASCII
    $p = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$amostrador`"", '-Out', "`"$gpuProc`"", '-JogoPid', $JogoPid, '-Pcie', "`"$pcie`"")
    if ($p) { $t.pids += $p.Id }
    # 4. Frames pela swap chain (PresentMon): fps real e quanto do frame a GPU ficou ocupada. Precisa de admin.
    $pmExe = Get-Command presentmon -ErrorAction SilentlyContinue
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $comPm = $false
    if ($pmExe -and $admin) {
        $p = Start-Process -FilePath $pmExe.Source -WindowStyle Hidden -PassThru -ArgumentList @(
            '--process_id', $JogoPid, '--output_file', "`"$pm`"", '--terminate_on_proc_exit', '--no_console_stats',
            '--stop_existing_session', '--session_name', 'NeptuneTurbo')
        if ($p) { $t.pids += $p.Id; $comPm = $true }
    } elseif ($pmExe) {
        Write-Host "Telemetria: o PresentMon precisa de PowerShell como administrador (frames pela swap chain ficam de fora)."
    }
    $t | ConvertTo-Json | Set-Content -Path $telePath -Encoding UTF8
    Write-Host ("Telemetria ligada: PCIe, RAM/paginacao, GPU por programa" + $(if ($comPm) { ', frames (PresentMon)' } else { '' }) + ".")
}

switch ($Acao) {
    'Status' { Show-Status }
    'Preparar' { Invoke-Preparar }
    'Restaurar' { Invoke-Restaurar }
    'Telemetria' { Start-Telemetria }
    'PararTelemetria' { Invoke-PararTelemetria }
}
