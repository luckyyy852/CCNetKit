param([string]$WorkRoot=(Join-Path ([IO.Path]::GetTempPath()) ('network-workbench-test-'+[guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$work=[IO.Path]::GetFullPath($WorkRoot)
if($work -eq $repo -or $work.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Test artifacts must remain outside the release folder.'}
if(Test-Path -LiteralPath $work){throw 'Use a new test directory; existing artifacts were not deleted.'}
$null=New-Item -ItemType Directory -Path $work
$appHome=Join-Path $work 'workbench';$null=New-Item -ItemType Directory -Path $appHome,(Join-Path $appHome 'data')
$count=0;$children=@();$oldHome=$env:NETWORK_WORKBENCH_HOME
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw ('Test failed: '+$Name)};$script:count++}
function SaveJson([string]$Path,$Value){$Value|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $Path -Encoding UTF8}
function FreePort{$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop();return $port}
function Operate([string]$Action,[string]$Domain,[bool]$Expected=$true){
    $request=[guid]::NewGuid().ToString('N');$script=Join-Path $appHome 'bin\Set-DomainRoute.ps1'
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $script -Action $Action -Domain $Domain -RequestId $request
    $result=Get-Content -LiteralPath (Join-Path $appHome 'data\route-result.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Check ($result.RequestId -eq $request -and $result.Success -eq $Expected) ($Action+' '+$Domain)
    return $result
}
try{
    $env:NETWORK_WORKBENCH_HOME=$appHome
    $null=& (Join-Path $repo 'scripts\Build-Workbench.ps1') -OutDirectory (Join-Path $appHome 'bin')
    $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe';$core=Join-Path $work 'MockCore.exe'
    & $compiler /nologo /target:exe /reference:System.Web.Extensions.dll ('/out:'+$core) (Join-Path $PSScriptRoot 'MockCore.cs')
    if($LASTEXITCODE -ne 0){throw 'Mock core compilation failed'}
    . (Join-Path $appHome 'bin\RoutePolicy.ps1')
    Check ((ConvertTo-RouteDomain 'https://www.Example.com/path?q=1') -eq 'example.com') 'URL normalization'
    foreach($bad in @('','*.example.com','com','127.0.0.1','file:///c:/test','app.exe','example.com,REJECT')){$rejected=$false;try{$null=ConvertTo-RouteDomain $bad}catch{$rejected=$true};Check $rejected 'Invalid domain rejected'}
    $ports=@((FreePort),(FreePort));$profiles=@();$originals=@{}
    for($i=0;$i -lt 3;$i++){
        $cfg=Join-Path $work ('profile-'+$i+'.json');$port=if($i -eq 2){$ports[0]}else{$ports[$i]}
        SaveJson $cfg @{mode='rule';'external-controller'=('127.0.0.1:'+$port);secret='synthetic-local-token';rules=@('DOMAIN,relay.example,DIRECT','DOMAIN-SUFFIX,preset.example,DIRECT','GEOSITE,cn,DIRECT','MATCH,PROXY');tun=@{enable=$false};dns=@{enable=$false}}
        $originals[$cfg]=(Get-Content -LiteralPath $cfg -Raw -Encoding UTF8|ConvertFrom-Json|ConvertTo-Json -Depth 40 -Compress)
        $profiles+=@{Name=('Synthetic '+$i);ConfigPath=$cfg;ExecutablePath=$core;DataDirectory=$work;ManageRules=$true;Reload=($i -lt 2);ProtectedRules=@('DOMAIN,relay.example,DIRECT')}
    }
    $protected=Join-Path $work 'protected-environment.txt';[IO.File]::WriteAllText($protected,'synthetic private environment');$protectedHash=(Get-FileHash -LiteralPath $protected).Hash
    $settings=@{SchemaVersion=1;Profiles=$profiles;ProtectedFiles=@($protected);Protection=$null;Billing=$null}
    SaveJson (Join-Path $appHome 'settings.json') $settings;SaveJson (Join-Path $appHome 'routes.json') @{Version=1;Domains=@()}
    for($i=0;$i -lt 2;$i++){$p=Start-Process -FilePath $core -ArgumentList ($ports[$i].ToString()+' "'+$profiles[$i].ConfigPath+'"') -WindowStyle Hidden -PassThru;$children+=$p}
    $ready=[datetime]::UtcNow.AddSeconds(5);do{Start-Sleep -Milliseconds 100;$open=@(Get-NetTCPConnection -State Listen -LocalPort $ports -ErrorAction SilentlyContinue)}while($open.Count -lt 2 -and [datetime]::UtcNow -lt $ready)
    Check ($open.Count -eq 2) 'Two synthetic loopback cores started'
    $null=& (Join-Path $repo 'scripts\Inspect-Settings.ps1') -SettingsPath (Join-Path $appHome 'settings.json')
    $exe=Join-Path $appHome 'bin\Workbench.exe'
    foreach($arg in @('--self-test','--snapshot','--preview')){$p=Start-Process -FilePath $exe -ArgumentList $arg -WindowStyle Hidden -PassThru;if(-not $p.WaitForExit(15000)){throw 'GUI validation timeout'};Check ($p.ExitCode -eq 0) $arg}
    $r=Operate 'Direct' 'example.com';Check ($r.AppliedCores -eq 2) 'Both active cores reloaded'
    $null=Operate 'Direct' 'example.com'
    $null=Operate 'Default' 'example.com'
    foreach($profile in $profiles){$now=Get-Content -LiteralPath $profile.ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json|ConvertTo-Json -Depth 40 -Compress;Check ($now -ceq $originals[$profile.ConfigPath]) 'Roundtrip preserves full original config'}
    $r=Operate 'Direct' 'preset.example';Check ([bool]$r.NoChange) 'Preexisting DIRECT is not adopted'
    $null=Operate 'Default' 'preset.example'
    $r=Operate 'Direct' 'configfail.invalid' $false;Check ([bool]$r.RolledBack) 'Native validation failure rolls back'
    $r=Operate 'Direct' 'reloadfail.invalid' $false;Check ([bool]$r.RolledBack) 'HTTP reload failure rolls back'
    $null=Operate 'Direct' 'example.com';$null=Operate 'Direct' 'other.example';$null=Operate 'Default' 'example.com'
    $domains=@((Get-Content -LiteralPath (Join-Path $appHome 'routes.json') -Raw|ConvertFrom-Json).Domains)
    Check ($domains.Count -eq 1 -and $domains[0] -eq 'other.example') 'Removing one domain retains another'
    $null=Operate 'Default' 'other.example'
    $request=[guid]::NewGuid().ToString('N');& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File (Join-Path $appHome 'bin\Diagnose.ps1') -RequestId $request
    $diagnostic=Get-Content -LiteralPath (Join-Path $appHome 'data\diagnostic-result.json') -Raw|ConvertFrom-Json;Check ($diagnostic.Success -and $diagnostic.RequestId -eq $request) 'Read-only diagnostic'
    Check ((Get-FileHash -LiteralPath $protected).Hash -eq $protectedHash) 'Protected environment preserved'
    foreach($profile in $profiles){$now=Get-Content -LiteralPath $profile.ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json|ConvertTo-Json -Depth 40 -Compress;Check ($now -ceq $originals[$profile.ConfigPath]) 'Final configuration restored'}
    foreach($child in $children){$child.Refresh();Check (-not $child.HasExited) 'Unchanged synthetic core process'}
    $summary=@{Passed=$count;ExternalNetworkUsed=$false;SystemNetworkChanged=$false;RealCredentialsUsed=$false;GuiUnitTests=(Get-Content -LiteralPath (Join-Path $appHome 'data\self-test.json') -Raw|ConvertFrom-Json)}
    $summary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $work 'test-result.json') -Encoding UTF8
    $summary|ConvertTo-Json -Depth 8
}finally{
    foreach($child in $children){try{$child.Refresh();if(-not $child.HasExited -and $child.MainModule.FileName -eq (Join-Path $work 'MockCore.exe')){$child.Kill();$null=$child.WaitForExit(3000)}}catch{}}
    $env:NETWORK_WORKBENCH_HOME=$oldHome
}
