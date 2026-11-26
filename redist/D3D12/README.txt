DirectX 12 Agility SDK runtime 1.620.2 (Microsoft.Direct3D.D3D12 1.620.2 on NuGet)

D3D12Core.dll here is Microsoft's file, unmodified, signed by Microsoft Corporation, and listed
as distributable in the package ("distributable-files.txt"). It is NOT covered by this
repository's GPL license: its terms are in LICENSE-Microsoft-Agility-SDK.txt.

  SHA-256 of D3D12Core.dll: 70A6D47D335B4A15180544C01A35B84474522A369DC582D85FE057313A3AEAA0
  SHA-512 of the NuGet package it was taken from:
  D683FF7F5726906C3F43D299F6CDD4B1CAD22F8329CCD27B3492D0A1413D9904102B8D543419BEC3B3545C86BF49F6A500EBF42D95C999AA0969E5D693032735

Why it is here: victory.exe exports D3D12SDKVersion = 620 and D3D12SDKPath = ".\D3D12\".
Without D3D12\D3D12Core.dll beside victory.exe, D3D12 refuses to make a device on Windows 10
and 11 ("The D3D12 SDK version configuration of the host exe is invalid. (0x887E0003)").

`cargo build` copies it to target\<profile>\D3D12\ (apps/victory/build.rs). If you move
victory.exe elsewhere, take the D3D12 folder with it, or run tools\get-agility-sdk.ps1 -ExeDir <folder>.
