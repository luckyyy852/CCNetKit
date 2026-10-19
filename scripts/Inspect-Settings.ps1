param([Parameter(Mandatory=$true)][string]$SettingsPath)
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path $PSScriptRoot -Parent
if([IO.Path]::GetFullPath($SettingsPath).StartsWith($sourceRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Keep real settings outside the publishable source folder.'}
$s=Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8|ConvertFrom-Json
if($s.SchemaVersion -ne 1 -or -not @($s.Profiles).Count){throw 'SchemaVersion 1 and at least one profile are required.'}
$seen=@();$summary=@()
foreach($p in $s.Profiles){
    if(-not $p.Name -or -not [IO.Path]::IsPathRooted($p.ConfigPath) -or -not [IO.Path]::IsPathRooted($p.ExecutablePath)){throw 'Each profile needs a name and absolute local config/executable paths.'}
    if(-not (Test-Path -LiteralPath $p.ConfigPath -PathType Leaf) -or -not (Test-Path -LiteralPath $p.ExecutablePath -PathType Leaf)){throw 'A specified local file does not exist.'}
    $full=[IO.Path]::GetFullPath($p.ConfigPath)
    if($full.StartsWith($sourceRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Keep private Mihomo profiles outside the source folder.'}
    if($full -in $seen){throw 'Duplicate configuration path.'};$seen+=$full
    $cfg=Get-Content -LiteralPath $full -Raw -Encoding UTF8|ConvertFrom-Json
    if($cfg.mode -ne 'rule' -or -not @($cfg.rules).Count){throw 'Profiles must be JSON Mihomo configurations in rule mode.'}
    $uri=$null
    if(-not [uri]::TryCreate(('http://'+$cfg.'external-controller'),[UriKind]::Absolute,[ref]$uri) -or -not $uri.IsLoopback -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment){throw 'Controllers must use a local loopback host and port.'}
    foreach($r in @($p.ProtectedRules)){if($r -notin @($cfg.rules)){throw 'A configured protected rule is missing.'}}
    if($full -in @($s.ProtectedFiles)){throw 'An editable profile cannot also be a protected file.'}
    $summary+=@{Name=$p.Name;ManageRules=[bool]$p.ManageRules;Reload=($p.Reload -ne $false);Loopback=$true;ProtectedRules=@($p.ProtectedRules).Count}
}
foreach($path in @($s.ProtectedFiles)){if(-not [IO.Path]::IsPathRooted($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'Every protected file must exist at an absolute local path.'}}
if($s.Protection -and $s.Protection.GuardStatePath -and -not (Test-Path -LiteralPath $s.Protection.GuardStatePath -PathType Leaf)){throw 'The optional existing guard state cannot be read.'}
@{Valid=$true;Profiles=$summary;ProtectedFiles=@($s.ProtectedFiles).Count;NetworkModified=$false}|ConvertTo-Json -Depth 5
