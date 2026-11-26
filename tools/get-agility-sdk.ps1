# Puts the DirectX 12 Agility SDK runtime (D3D12Core.dll 1.620.2) where victory.exe looks for it:
# a "D3D12" folder beside victory.exe. victory.exe exports D3D12SDKVersion = 620 and
# D3D12SDKPath = ".\D3D12\", so without that file D3D12 refuses to make a device on Windows 10 and
# 11 ("The D3D12 SDK version configuration of the host exe is invalid. (0x887E0003)") and the title
# stops at its first root signature.
#
# Source, in this order: the copy kept in this repository (redist\D3D12\D3D12Core.dll), or else
# Microsoft's official NuGet package (Microsoft.Direct3D.D3D12 1.620.2), checked against the
# package's SHA-512 published by NuGet. Either way the file's version and Microsoft signature are
# checked before it is put in place. `cargo build` already copies the repository's copy beside
# victory.exe (apps/victory/build.rs); this script is for a victory.exe moved to another folder.
#
# Usage:
#   .\tools\get-agility-sdk.ps1                          (for target\release\victory.exe)
#   .\tools\get-agility-sdk.ps1 -ExeDir 'D:\somewhere'   (for a victory.exe in another folder)
#   .\tools\get-agility-sdk.ps1 -Download                (ignore the repository copy, use NuGet)
param(
    [string]$ExeDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'target\release'),
    [switch]$Download,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$version = '1.620.2'
$sha512 = 'D683FF7F5726906C3F43D299F6CDD4B1CAD22F8329CCD27B3492D0A1413D9904102B8D543419BEC3B3545C86BF49F6A500EBF42D95C999AA0969E5D693032735'
$url = "https://api.nuget.org/v3-flatcontainer/microsoft.direct3d.d3d12/$version/microsoft.direct3d.d3d12.$version.nupkg"
$kept = Join-Path (Split-Path $PSScriptRoot -Parent) 'redist\D3D12\D3D12Core.dll'

$dir = Join-Path $ExeDir 'D3D12'
$core = Join-Path $dir 'D3D12Core.dll'

function Test-Core([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
    $v = (Get-Item -LiteralPath $path).VersionInfo.FileVersion
    if (-not $v -or -not $v.StartsWith("$version.")) { return "of another version ($v)" }
    $sig = Get-AuthenticodeSignature -LiteralPath $path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { return 'not signed by Microsoft' }
    return 'ok'
}

$state = Test-Core $core
if ($state -eq 'ok' -and -not $Force) {
    Write-Host "Agility SDK $version in place: $core"
    exit 0
}
Write-Host "Agility SDK: $core is $state; putting $version there."

if (-not $Download -and (Test-Core $kept) -eq 'ok') {
    [void][IO.Directory]::CreateDirectory($dir)
    Copy-Item -LiteralPath $kept -Destination $core -Force
    Write-Host "Agility SDK $version copied from the repository: $core"
    exit 0
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('agility-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    $package = Join-Path $temp 'agility.nupkg'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $package
    $hash = (Get-FileHash -LiteralPath $package -Algorithm SHA512).Hash
    if ($hash -ne $sha512) { throw "The package's SHA-512 does not match NuGet's for $version (got $hash). Nothing was installed." }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Get-Item -LiteralPath $package).FullName)
    try {
        $entry = $zip.GetEntry('build/native/bin/x64/D3D12Core.dll')
        if (-not $entry) { throw 'The package has no build/native/bin/x64/D3D12Core.dll.' }
        $staged = Join-Path $temp 'D3D12Core.dll'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $staged, $true)
    } finally { $zip.Dispose() }
    $check = Test-Core $staged
    if ($check -ne 'ok') { throw "The extracted D3D12Core.dll is $check. Nothing was installed." }
    [void][IO.Directory]::CreateDirectory($dir)
    Copy-Item -LiteralPath $staged -Destination $core -Force
    Write-Host "Agility SDK $version installed from NuGet: $core"
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
