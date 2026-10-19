param([Parameter(Mandatory=$true)][string]$InstallRoot,[Parameter(Mandatory=$true)][string]$SettingsPath,[switch]$Open)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$destination=[IO.Path]::GetFullPath($InstallRoot)
if(-not [IO.Path]::IsPathRooted($InstallRoot) -or $destination.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $destination -eq $repo){throw 'Use a separate absolute installation directory outside the skill repository.'}
if(Test-Path -LiteralPath $destination){throw 'The installation directory already exists; no files were overwritten.'}
$ancestor=Split-Path $destination -Parent
while($ancestor){if(Test-Path -LiteralPath $ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Use a physical installation path, not a junction or symlink parent.'}};$next=Split-Path $ancestor -Parent;if($next -eq $ancestor){break};$ancestor=$next}
& (Join-Path $PSScriptRoot 'Inspect-Settings.ps1') -SettingsPath $SettingsPath
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Allow Windows administrator permission to install the protected backend. Inspection and build do not require elevation.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$null=New-Item -ItemType Directory -Path $destination
$null=New-Item -ItemType Directory -Path (Join-Path $destination 'data')
$bin=Join-Path $destination 'bin'
$null=& (Join-Path $PSScriptRoot 'Build-Workbench.ps1') -OutDirectory $bin
Copy-Item -LiteralPath $SettingsPath -Destination (Join-Path $destination 'settings.json')
@{Version=1;Domains=@()}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $destination 'routes.json') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $repo 'references\user-guide.md') -Destination (Join-Path $destination 'HELP.md')
& "$env:SystemRoot\System32\icacls.exe" $destination /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' ('*'+$identity.User.Value+':(OI)(CI)RX')|Out-Null
if($LASTEXITCODE){throw 'Could not protect the runtime directory; do not use the backend until its ACL is repaired.'}
& "$env:SystemRoot\System32\icacls.exe" $destination /setowner '*S-1-5-32-544' /T /Q|Out-Null
if($LASTEXITCODE){throw 'Runtime ownership setup failed.'}
& "$env:SystemRoot\System32\icacls.exe" (Join-Path $destination 'data') /grant:r ('*'+$identity.User.Value+':(OI)(CI)M')|Out-Null
if($LASTEXITCODE){throw 'Runtime data directory access setup failed.'}
@{Installed=$true;ProfilesCopied=$false;NetworkChanged=$false;AutoStartRegistered=$false}|ConvertTo-Json
if($Open){Start-Process -FilePath (Join-Path $bin 'Workbench.exe') -WindowStyle Normal}
