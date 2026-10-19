param()
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Protection.Policy.ps1')
$count=0
function Check([bool]$Value,[string]$Name){if(-not $Value){throw ('Protection policy failed: '+$Name)};$script:count++}
$d=Get-ProtectionDecision -Baseline 'route-a' -Current 'route-a'
Check (-not $d.Locked -and $d.Count -eq 0) 'Stable physical route'
$d=Get-ProtectionDecision -Baseline 'route-a' -Current 'route-b'
Check (-not $d.Locked -and $d.Count -eq 1) 'One different sample does not lock'
$d=Get-ProtectionDecision -Baseline 'route-a' -Current 'route-a' -Candidate $d.Candidate -Count $d.Count
Check (-not $d.Locked -and $d.Count -eq 0) 'Transient sample clears'
$d=Get-ProtectionDecision -Baseline 'route-a' -Current 'route-b'
$d=Get-ProtectionDecision -Baseline 'route-a' -Current 'route-b' -Candidate $d.Candidate -Count $d.Count
Check ($d.Locked -and $d.Reason -eq 'physical-network-changed') 'Sustained route change locks'
$d=Get-ProtectionDecision -Baseline 'route-a' -Current 'route-c' -Candidate 'route-b' -Count 1
Check (-not $d.Locked -and $d.Count -eq 1) 'A different candidate starts a new confirmation'
$d=Get-ProtectionDecision -Baseline 'route-a' -Current 'offline'
$d=Get-ProtectionDecision -Baseline 'route-a' -Current 'offline' -Candidate $d.Candidate -Count $d.Count
Check $d.Locked 'Physical disconnection locks'
Check ((Get-ProtectionDecision -Baseline 'route-a' -Current 'route-a' -Latched $true).Locked) 'Return to original network never unlocks'
Check ((Get-ProtectionDecision -Baseline 'route-a' -Current 'route-a' -CoreAlive $false).Reason -eq 'dedicated-core-exited') 'Core exit locks'
Check ((Get-ProtectionDecision -Baseline 'route-a' -Current 'route-a' -StopRequested $true).Reason -eq 'manual-stop') 'Manual stop locks'
Check ((Get-ProtectionDecision -Baseline 'route-a' -Current 'route-a' -ConfigChanged $true).Reason -eq 'dedicated-config-changed') 'Config change locks'
for($i=0;$i -lt 20;$i++){$d=Get-ProtectionDecision -Baseline 'route-a' -Current 'route-a';if($d.Locked){throw 'Stable network unexpectedly locked'}}
Check $true 'No HTTP result or connection count participates in locking'
$template=Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\protected-core.example.json'
$cfg=Get-Content -LiteralPath $template -Raw -Encoding UTF8|ConvertFrom-Json
$cfg.secret='synthetic-private-controller';$cfg.'interface-name'='Ethernet';$cfg.proxies[0].server='proxy.example.com'
$spec=Test-ProtectedCoreConfig $cfg
Check ($spec.Port -eq 17900 -and $spec.ControllerPort -eq 19093) 'Single-node dedicated recipe accepted'
function Reject($Change,[string]$Name){$candidate=$cfg|ConvertTo-Json -Depth 20|ConvertFrom-Json;& $Change $candidate;$rejected=$false;try{$null=Test-ProtectedCoreConfig $candidate}catch{$rejected=$true};Check $rejected $Name}
Reject {$args[0].tun.enable=$true} 'Never accept dedicated TUN'
Reject {$args[0].'allow-lan'=$true} 'Never expose dedicated proxy to LAN'
Reject {$args[0].'proxy-groups'[0].proxies+=@('DIRECT')} 'Never permit direct fallback'
Reject {$args[0].rules=@('MATCH,DIRECT')} 'Never permit direct catch-all'
Reject {$args[0]|Add-Member -NotePropertyName listeners -NotePropertyValue @()} 'No extra listeners'
Reject {$args[0].'external-controller'='0.0.0.0:19093'} 'No remote control API'
Reject {$args[0].'proxy-groups'[0]|Add-Member -NotePropertyName 'include-all' -NotePropertyValue $true} 'No automatic node import'
Reject {$args[0].proxies[0]|Add-Member -NotePropertyName 'dialer-proxy' -NotePropertyValue 'UNREVIEWED'} 'No unreviewed proxy chain'
@{Passed=$count;PurePolicyOnly=$true;NetworkChanged=$false;IsolationInstalled=$false;RealNodesUsed=$false}|ConvertTo-Json
