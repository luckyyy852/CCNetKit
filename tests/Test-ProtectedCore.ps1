param([Parameter(Mandatory=$true)][string]$WorkRoot)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$work=[IO.Path]::GetFullPath($WorkRoot)
if(Test-Path -LiteralPath $work){throw 'Use a fresh test directory.'}
if($work -eq $repo -or $work.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Test outside the skill folder.'}
$null=New-Item -ItemType Directory -Path $work
$count=0;$watchers=@();$ports=@();$corePath=Join-Path $work 'SyntheticCore.exe';$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Check([bool]$Value,[string]$Name){if(-not $Value){throw ('Protected lifecycle test failed: '+$Name)};$script:count++}
function SaveJson($Path,$Value){$Value|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $Path -Encoding UTF8}
function FreePort{$l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$l.Start();$p=$l.LocalEndpoint.Port;$l.Stop();$p}
$src=@'
using System; using System.IO; using System.Linq; using System.Net; using System.Net.Sockets; using System.Threading; using System.Collections.Generic; using System.Web.Script.Serialization;
class SyntheticCore {
  static int Main(string[] args) {
    int index=Array.IndexOf(args,"-f");
    if(args.Contains("-t"))return File.Exists(args[index+1]+".fail-validation")?1:0;
    var cfg=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(args[index+1]));
    int port=Convert.ToInt32(cfg["mixed-port"]);int ctl=new Uri("http://"+cfg["external-controller"]).Port;
    var a=new TcpListener(IPAddress.Loopback,port);var b=new TcpListener(IPAddress.Loopback,ctl);a.Start();b.Start();
    while(true)Thread.Sleep(1000);
  }
}
'@
[IO.File]::WriteAllText((Join-Path $work 'SyntheticCore.cs'),$src)
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /target:exe /reference:System.Web.Extensions.dll ('/out:'+$corePath) (Join-Path $work 'SyntheticCore.cs')
if($LASTEXITCODE){throw 'Synthetic core compilation failed.'}
$ports=@((FreePort),(FreePort));while($ports[1] -eq $ports[0]){$ports[1]=FreePort}
$cfg=Get-Content -LiteralPath (Join-Path $repo 'assets\protected-core.example.json') -Raw -Encoding UTF8|ConvertFrom-Json
$cfg.secret='synthetic-private-controller';$cfg.'interface-name'='SyntheticAdapter';$cfg.proxies[0].server='proxy.example.com';$cfg.'mixed-port'=$ports[0];$cfg.'external-controller'='127.0.0.1:'+$ports[1]
$config=Join-Path $work 'protected-core.json';SaveJson $config $cfg
$settings=Join-Path $work 'protected-session.json';$stateDir=Join-Path $work 'state';$statePath=Join-Path $stateDir 'guard-state.json';$lock=Join-Path $stateDir 'locked.json';$marker=Join-Path $work 'route.txt'
SaveJson $settings @{SchemaVersion=1;CoreExecutablePath=$corePath;CoreConfigPath=$config;CoreDataDirectory=(Join-Path $work 'core-data');StateDirectory=$stateDir}
[IO.File]::WriteAllText($marker,'route-a')
# The wrapper replaces only read-only adapter/route discovery with synthetic values.
# The product script has no test bypass, and no real route, DNS, VPN or firewall is changed.
$wrapper=@'
param([string]$Repo,[string]$Settings,[string]$Marker,[string]$Action)
$ErrorActionPreference='Stop'
Import-Module NetTCPIP -ErrorAction Stop
$env:WORKBENCH_SYNTHETIC_ROUTE_FILE=$Marker
function Get-NetAdapter {param([switch]$Physical) [pscustomobject]@{Name='SyntheticAdapter';Status='Up';ifIndex=123;InterfaceGuid='synthetic-interface'}}
function Get-NetRoute {param($InterfaceIndex,$AddressFamily,$DestinationPrefix,$PolicyStore) [pscustomobject]@{NextHop=([IO.File]::ReadAllText($env:WORKBENCH_SYNTHETIC_ROUTE_FILE))}}
& (Join-Path $Repo 'scripts\Watch-ProtectedCore.ps1') -SettingsPath $Settings -Action $Action
'@
$wrapperPath=Join-Path $work 'Run-SyntheticWatcher.ps1';[IO.File]::WriteAllText($wrapperPath,$wrapper,[Text.UTF8Encoding]::new($true))
function Launch([string]$Action){
    $p=Start-Process -FilePath $shell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$wrapperPath+'" -Repo "'+$repo+'" -Settings "'+$settings+'" -Marker "'+$marker+'" -Action '+$Action) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work ($Action+'-out.log')) -RedirectStandardError (Join-Path $work ($Action+'-error.log')) -PassThru
    $script:watchers+=,$p;return $p
}
function WaitArmed($Process){
    $until=[datetime]::UtcNow.AddSeconds(25)
    do{
        if($Process.HasExited){throw 'Synthetic watcher exited before arming; inspect private test logs.'}
        if(Test-Path -LiteralPath $statePath){try{$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json;if($state.pid -eq $Process.Id -and $state.armed -and -not $state.latched){return}}catch{}}
        Start-Sleep -Milliseconds 200
    }while([datetime]::UtcNow -lt $until)
    throw 'Synthetic watcher did not arm.'
}
try{
    $p=Launch 'Run';WaitArmed $p
    Check (-not (Test-Path -LiteralPath $lock)) 'Initial run clears startup lock only after owned listeners are verified'
    Check (@(Get-NetTCPConnection -LocalPort $ports -State Listen -ErrorAction SilentlyContinue).Count -eq 2) 'Synthetic listeners only'
    [IO.File]::WriteAllText($marker,'route-b')
    Check ($p.WaitForExit(20000)) 'Sustained synthetic route change exits watcher'
    $record=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
    Check ($record.latched -and -not $record.armed -and $record.reason -eq 'physical-network-changed') 'Route change latches state'
    Check (@(Get-NetTCPConnection -LocalPort $ports -State Listen -ErrorAction SilentlyContinue).Count -eq 0) 'Owned core stopped and ports released'
    $blocked=Launch 'Run';Check ($blocked.WaitForExit(10000) -and $blocked.ExitCode -ne 0) 'Normal startup cannot clear persistent lock'
    Check (Test-Path -LiteralPath $lock) 'Rejected startup preserves lock'
    $p=Launch 'Resume';WaitArmed $p
    Check (-not (Test-Path -LiteralPath $lock)) 'Explicit manual resume succeeds'
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\Watch-ProtectedCore.ps1') -SettingsPath $settings -Action Stop
    if($LASTEXITCODE){throw 'Stop request failed.'}
    Check ($p.WaitForExit(12000)) 'Manual stop is processed'
    $record=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
    Check ($record.latched -and $record.reason -eq 'manual-stop') 'Manual stop latches'
    $status=(& $shell -NoProfile -File (Join-Path $repo 'scripts\Watch-ProtectedCore.ps1') -SettingsPath $settings -Action Status)|ConvertFrom-Json
    Check (-not $status.armed -and -not $status.GuardProcessVerified -and $status.latched) 'Stopped watcher is not reported alive'
    [IO.File]::WriteAllText($config+'.fail-validation','synthetic-validation-failure')
    $failed=Launch 'Resume';Check ($failed.WaitForExit(12000) -and $failed.ExitCode -ne 0) 'Native validation failure refuses to start a core'
    $record=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
    Check ($record.latched -and -not $record.armed -and $record.reason -eq 'startup-failed') 'Startup failure remains visibly locked'
    Check (@(Get-NetTCPConnection -LocalPort $ports -State Listen -ErrorAction SilentlyContinue).Count -eq 0) 'Failed validation opens no listener'
    @{Passed=$count;SyntheticPhysicalNetwork=$true;OnlyLoopbackListenersUsed=$true;SystemNetworkChanged=$false;WfpInstalled=$false;RealApplicationsLaunched=$false}|ConvertTo-Json
}finally{
    foreach($p in $watchers){try{if(-not $p.HasExited){if(Test-Path -LiteralPath $stateDir){[IO.File]::WriteAllText((Join-Path $stateDir 'stop.request'),'manual-stop')};if(-not $p.WaitForExit(10000)){$p.Kill();$null=$p.WaitForExit(3000)}}}catch{}}
    # If a test was interrupted, only its compiled synthetic core may be cleaned up.
    foreach($p in @(Get-Process -Name SyntheticCore -ErrorAction SilentlyContinue)){try{if($p.MainModule.FileName -eq $corePath){$p.Kill();$null=$p.WaitForExit(3000)}}catch{}}
}
