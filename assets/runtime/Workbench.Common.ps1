$ErrorActionPreference='Stop'
$script:WorkbenchRoot=if($env:NETWORK_WORKBENCH_HOME){[IO.Path]::GetFullPath($env:NETWORK_WORKBENCH_HOME)}else{Split-Path $PSScriptRoot -Parent}
if(Test-Path -LiteralPath (Join-Path $WorkbenchRoot 'SKILL.md')){throw '运行目录必须与公开技能源码分开。'}
$script:SettingsPath=Join-Path $WorkbenchRoot 'settings.json'
$script:Settings=Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8|ConvertFrom-Json
$script:Data=Join-Path $WorkbenchRoot 'data'
function Get-ProfileConfig($Profile){Get-Content -LiteralPath $Profile.ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json}
function Get-ControllerUri($Profile){
    $cfg=Get-ProfileConfig $Profile;$uri=$null
    if(-not [uri]::TryCreate(('http://'+$cfg.'external-controller'),[UriKind]::Absolute,[ref]$uri) -or -not $uri.IsLoopback -or $uri.Port -lt 1 -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment){throw '控制 API 必须配置为本机回环地址。'}
    return $uri
}
function Invoke-WorkbenchApi($Profile,[string]$Path,[string]$Method='GET',[string]$Body=''){
    $cfg=Get-ProfileConfig $Profile;$base=Get-ControllerUri $Profile
    $r=[Net.HttpWebRequest]::Create([uri]::new($base,$Path));$r.Proxy=$null;$r.AllowAutoRedirect=$false;$r.Method=$Method;$r.Timeout=12000
    $r.Headers['Authorization']='Bearer '+$cfg.secret
    if($Body){$bytes=[Text.Encoding]::UTF8.GetBytes($Body);$r.ContentType='application/json';$r.ContentLength=$bytes.Length;$stream=$r.GetRequestStream();try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}
    $response=$r.GetResponse();try{$reader=New-Object IO.StreamReader($response.GetResponseStream());try{$text=$reader.ReadToEnd();if($text){$text|ConvertFrom-Json}}finally{$reader.Dispose()}}finally{$response.Dispose()}
}
function Get-ProfileCore($Profile){
    $port=(Get-ControllerUri $Profile).Port
    $listeners=@(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
    if(-not $listeners.Count){return $null}
    if(@($listeners|Where-Object {$_.LocalAddress -notin @('127.0.0.1','::1')}).Count){throw '控制端口不是仅监听回环地址，未更改配置。'}
    $owners=@($listeners.OwningProcess|Sort-Object -Unique)
    if($owners.Count -ne 1){throw '控制端口进程身份不明确。'}
    $p=Get-Process -Id $owners[0] -ErrorAction Stop
    if(-not $Profile.ExecutablePath -or $p.Path -ne [IO.Path]::GetFullPath($Profile.ExecutablePath)){throw '控制端口所属程序与指定内核不符。'}
    return [pscustomobject]@{PID=$p.Id;Ticks=$p.StartTime.ToUniversalTime().Ticks;Path=$p.Path;Port=$port}
}
function Get-ProtectionFingerprint {
    if(-not $Settings.Protection -or -not $Settings.Protection.GuardStatePath){return ''}
    $s=Get-Content -LiteralPath $Settings.Protection.GuardStatePath -Raw -Encoding UTF8|ConvertFrom-Json
    @{PID=$s.pid;Start=$s.startTimeUtc;Armed=$s.armed;Latched=$s.latched;Locked=([bool]($Settings.Protection.LockPath -and (Test-Path -LiteralPath $Settings.Protection.LockPath)))}|ConvertTo-Json -Compress
}
function Write-OperationResult([string]$Name,$Result){$Result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $Data $Name) -Encoding UTF8}
