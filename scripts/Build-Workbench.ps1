param([Parameter(Mandatory=$true)][string]$OutDirectory)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$out=[IO.Path]::GetFullPath($OutDirectory)
if($out.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Build outside the publishable skill folder.'}
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $compiler)){throw 'Windows .NET Framework 4.x compiler is required.'}
$null=New-Item -ItemType Directory -Path $out -Force
$sources=@(Get-ChildItem -LiteralPath (Join-Path $repo 'assets\runtime') -Filter '*.cs'|ForEach-Object FullName)
& $compiler /nologo /target:winexe /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:System.Core.dll /reference:System.Security.dll ('/out:'+(Join-Path $out 'Workbench.exe')) @sources
if($LASTEXITCODE -ne 0){throw 'Workbench compilation failed.'}
Get-ChildItem -LiteralPath (Join-Path $repo 'assets\runtime') -Filter '*.ps1'|ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $out $_.Name) -Force}
[pscustomobject]@{Compiled=$true;OutputDirectory=$out;Downloaded=$false}
