param([Parameter(Mandatory=$true)][string]$WorkRoot)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent;$work=[IO.Path]::GetFullPath($WorkRoot)
if(Test-Path -LiteralPath $work){throw 'Use a new test folder.'}
if($work -eq $repo -or $work.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Test outside the public skill.'}
$null=New-Item -ItemType Directory -Path $work
# These empty fixture files are never executed: every invocation uses Plan.
$browser=Join-Path $work 'msedge.exe';$core=Join-Path $work 'mihomo.exe';[IO.File]::WriteAllBytes($browser,[byte[]]@());[IO.File]::WriteAllBytes($core,[byte[]]@())
$cfg=@{BrowserExecutablePath=$browser;ProfileDirectory=(Join-Path $work 'dedicated');ProxyUrl='http://127.0.0.1:17900';ProxyCoreExecutablePath=$core;HomeUrl='https://claude.ai/'}
$settings=Join-Path $work 'private-settings.json';$scriptFile=Join-Path $repo 'scripts\Open-ServiceBrowser.ps1';$count=0
function Save{$cfg|ConvertTo-Json|Set-Content -LiteralPath $settings -Encoding UTF8}
function Check([bool]$Value,[string]$Name){if(-not $Value){throw $Name};$script:count++}
Save
$plan=& $scriptFile -SettingsPath $settings -Plan
Check ($plan.Arguments -contains '--proxy-server="http://127.0.0.1:17900"') 'Fixed proxy argument'
Check ($plan.Arguments -contains '--disable-quic') 'Do not introduce direct QUIC'
Check ($plan.Arguments -contains ('--user-data-dir="'+$cfg.ProfileDirectory+'"')) 'Separate profile argument'
Check (-not $plan.BrowserStarted -and -not (Test-Path -LiteralPath $cfg.ProfileDirectory)) 'Plan performs no launch or profile creation'
foreach($url in @('http://proxy.example.com:8080','http://127.0.0.1:17900/?token=private','http://user:password@127.0.0.1:17900')){
    $cfg.ProxyUrl=$url;Save;$rejected=$false;try{$null=& $scriptFile -SettingsPath $settings -Plan}catch{$rejected=$true};Check $rejected 'Reject ambiguous proxy settings'
}
$cfg.ProxyUrl='http://127.0.0.1:17900';$null=New-Item -ItemType Directory -Path $cfg.ProfileDirectory;[IO.File]::WriteAllText((Join-Path $cfg.ProfileDirectory 'personal-data.txt'),'synthetic-personal-profile');Save
$rejected=$false;try{$null=& $scriptFile -SettingsPath $settings -Plan}catch{$rejected=$true};Check $rejected 'Never reuse a personal browser profile'
@{Passed=$count;BrowserStarted=$false;NetworkChanged=$false;RealProfilesUsed=$false}|ConvertTo-Json
