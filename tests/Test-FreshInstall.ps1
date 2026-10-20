param([Parameter(Mandatory=$true)][string]$WorkRoot,[string]$PythonExecutable='python',[string]$ArchivePath,[switch]$RequireAdmin)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$work=[IO.Path]::GetFullPath($WorkRoot)
if(Test-Path -LiteralPath $work){throw 'Use a new private test directory.'}
if($work -eq $repo -or $work.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Test outside the source folder.'}
$null=New-Item -ItemType Directory -Path $work
$count=0;$core=$null;$originalHome=$env:NETWORK_WORKBENCH_HOME
function Check([bool]$Value,[string]$Name){if(-not $Value){throw ('Fresh install: '+$Name)};$script:count++}
function SaveJson($Path,$Value){$Value|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $Path -Encoding UTF8}
function RunGui([string]$Argument){$p=Start-Process -FilePath (Join-Path $install 'bin\Workbench.exe') -ArgumentList $Argument -WindowStyle Hidden -PassThru;try{if(-not $p.WaitForExit(20000)){$p.Kill();throw 'Installed GUI check timed out.'};Check ($p.ExitCode -eq 0) $Argument}finally{$p.Dispose()}}
try{
    if(-not $ArchivePath){$ArchivePath=Join-Path $work 'release.zip';& $PythonExecutable (Join-Path $repo 'scripts\package_release.py') $repo $ArchivePath;if($LASTEXITCODE){throw 'Packaging failed.'}}
    $download=Join-Path $work 'New user 下载目录';$null=New-Item -ItemType Directory -Path $download
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $download
    $source=Join-Path $download 'ccnetkit'
    Check (Test-Path -LiteralPath (Join-Path $source 'SKILL.md')) 'Unpacked skill is discoverable at the documented depth'
    Check (-not (Test-Path -LiteralPath (Join-Path $source 'settings.json'))) 'Release contains no private settings'
    $private=Join-Path $work 'Private user 用户';$null=New-Item -ItemType Directory -Path $private
    $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $corePath=Join-Path $private 'SyntheticCore.exe'
    & $compiler /nologo /target:exe /reference:System.Web.Extensions.dll ('/out:'+$corePath) (Join-Path $source 'tests\MockCore.cs')
    if($LASTEXITCODE){throw 'Synthetic controller build failed.'}
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
    $config=Join-Path $private 'daily.json';$protected=Join-Path $private 'protected.env';[IO.File]::WriteAllText($protected,'synthetic-environment-only')
    $cfg=@{mode='rule';'external-controller'=('127.0.0.1:'+$port);secret='synthetic-local-token';rules=@('DOMAIN,relay.example,DIRECT','MATCH,PROXY');tun=@{enable=$false};dns=@{enable=$false}}
    SaveJson $config $cfg
    $before=(Get-Content -LiteralPath $config -Raw -Encoding UTF8|ConvertFrom-Json|ConvertTo-Json -Depth 40 -Compress)
    $settings=Join-Path $private 'settings.json'
    SaveJson $settings @{SchemaVersion=1;Profiles=@(@{Name='Synthetic';ConfigPath=$config;ExecutablePath=$corePath;DataDirectory=$private;ManageRules=$true;Reload=$true;ProtectedRules=@('DOMAIN,relay.example,DIRECT')});ProtectedFiles=@($protected);Protection=$null;Billing=$null}
    $settingsHash=(Get-FileHash -LiteralPath $settings).Hash;$protectedHash=(Get-FileHash -LiteralPath $protected).Hash
    $null=& (Join-Path $source 'scripts\Inspect-Settings.ps1') -SettingsPath $settings
    $install=Join-Path $work 'Installed user 用户'
    $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if(-not $admin){
        if($RequireAdmin){throw 'This CI job must exercise installation with administrator rights.'}
        $refused=$false
        try{$null=& (Join-Path $source 'scripts\Install-Workbench.ps1') -InstallRoot $install -SettingsPath $settings}catch{if($_.Exception.Message -like 'Allow Windows administrator permission*'){$refused=$true}else{throw}}
        Check $refused 'Non-admin installation is refused with the intended reason'
        Check (-not (Test-Path -LiteralPath $install)) 'Non-admin refusal leaves no partial installation'
        @{Passed=$count;AdminInstallationExercised=$false;NonAdminRefusalVerified=$true;NetworkChanged=$false}|ConvertTo-Json
        return
    }
    $null=& (Join-Path $source 'scripts\Install-Workbench.ps1') -InstallRoot $install -SettingsPath $settings
    Check ((Get-Acl -LiteralPath $install).GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') 'Installed backend is owned by Administrators'
    Check ((Get-FileHash -LiteralPath (Join-Path $install 'settings.json')).Hash -eq $settingsHash) 'Private settings are copied intact'
    Check (Test-Path -LiteralPath (Join-Path $install 'HELP.md')) 'Offline help is installed'
    # Inspect the real installed location without an environment override.
    Remove-Item Env:NETWORK_WORKBENCH_HOME -ErrorAction SilentlyContinue
    $core=Start-Process -FilePath $corePath -ArgumentList ($port.ToString()+' "'+$config+'"') -WindowStyle Hidden -PassThru
    $deadline=[datetime]::UtcNow.AddSeconds(10)
    do{Start-Sleep -Milliseconds 100;$ready=@(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)}while(-not $ready.Count -and [datetime]::UtcNow -lt $deadline)
    Check ([bool]$ready.Count) 'Synthetic loopback controller is ready'
    RunGui '--snapshot'
    $snapshot=Get-Content -LiteralPath (Join-Path $install 'data\snapshot.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Check ($snapshot.Cores -eq 1 -and $snapshot.Current -eq 1 -and -not $snapshot.Tun -and -not $snapshot.Errors.Count) 'Installed GUI reads its private settings and controller'
    RunGui '--preview';Check (Test-Path -LiteralPath (Join-Path $install 'data\preview.png')) 'Installed GUI renders without opening a real browser'
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach($action in @('Direct','Default')){
        $request=[guid]::NewGuid().ToString('N')
        & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install 'bin\Set-DomainRoute.ps1') -Action $action -Domain example.com -RequestId $request
        if($LASTEXITCODE){throw 'Installed route operation failed.'}
        $result=Get-Content -LiteralPath (Join-Path $install 'data\route-result.json') -Raw -Encoding UTF8|ConvertFrom-Json
        Check ($result.Success -and $result.RequestId -eq $request -and $result.AppliedCores -eq 1) ('Installed '+$action+' operation')
    }
    Check ((Get-Content -LiteralPath $config -Raw -Encoding UTF8|ConvertFrom-Json|ConvertTo-Json -Depth 40 -Compress) -ceq $before) 'Roundtrip preserves the original synthetic network configuration'
    Check ((Get-FileHash -LiteralPath $protected).Hash -eq $protectedHash) 'Protected file is unchanged'
    $refused=$false;try{$null=& (Join-Path $source 'scripts\Install-Workbench.ps1') -InstallRoot $install -SettingsPath $settings}catch{if($_.Exception.Message -like 'The installation directory already exists*'){$refused=$true}else{throw}}
    Check $refused 'Reinstall does not overwrite the existing installation'
    Check ((Get-FileHash -LiteralPath (Join-Path $install 'settings.json')).Hash -eq $settingsHash) 'Reinstall refusal preserves private settings'
    $core.Refresh();Check (-not $core.HasExited) 'Closing GUI checks does not stop the proxy controller'
    @{Passed=$count;AdminInstallationExercised=$true;OnlyLoopbackController=$true;NetworkChanged=$false;RealCredentialsUsed=$false}|ConvertTo-Json
}finally{
    if($core){try{$core.Refresh();if(-not $core.HasExited){$core.Kill();$null=$core.WaitForExit(3000)}}finally{$core.Dispose()}}
    $env:NETWORK_WORKBENCH_HOME=$originalHome
}
