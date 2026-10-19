param([Parameter(Mandatory=$true)][string]$SettingsPath,[switch]$Plan)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
function LocalPrivatePath([string]$Path){
    if(-not [IO.Path]::IsPathRooted($Path) -or $Path.IndexOfAny([char[]]"`"`r`n") -ge 0){throw 'Use an absolute local path without quotes or line breaks.'}
    $full=[IO.Path]::GetFullPath($Path)
    if($full -eq $repo -or $full.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Browser settings and data must remain outside the public skill.'}
    $ancestor=$full
    while($ancestor){if((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Use physical paths, not directory links.'};$next=Split-Path $ancestor -Parent;if($next -eq $ancestor){break};$ancestor=$next}
    $full
}
$settingsFull=LocalPrivatePath $SettingsPath
$s=Get-Content -LiteralPath $settingsFull -Raw -Encoding UTF8|ConvertFrom-Json
$browser=LocalPrivatePath $s.BrowserExecutablePath;$browserProfilePath=LocalPrivatePath $s.ProfileDirectory;$core=LocalPrivatePath $s.ProxyCoreExecutablePath
if([IO.Path]::GetFileName($browser) -notin @('chrome.exe','msedge.exe') -or -not (Test-Path -LiteralPath $browser -PathType Leaf) -or -not (Test-Path -LiteralPath $core -PathType Leaf)){throw 'Select an existing Chrome or Edge executable and the intended local core.'}
$uri=$null
if(-not [uri]::TryCreate($s.ProxyUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.Port -lt 1024 -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment){throw 'Use a fixed loopback HTTP proxy without credentials, PAC or DIRECT fallback.'}
$homeUri=$null
if(-not [uri]::TryCreate($s.HomeUrl,[UriKind]::Absolute,[ref]$homeUri) -or $homeUri.Scheme -ne 'https' -or $homeUri.Host -notin @('claude.ai','claude.com','platform.claude.com') -or $homeUri.UserInfo -or $homeUri.Query -or $homeUri.Fragment){throw 'Use an official Claude home/login page without private callback tokens.'}
$proxy='http://127.0.0.1:'+$uri.Port
$marker=Join-Path $browserProfilePath 'workbench-profile.json'
if(Test-Path -LiteralPath $browserProfilePath){
    if(-not (Test-Path -LiteralPath $browserProfilePath -PathType Container)){throw 'The profile path must be a directory.'}
    if(Test-Path -LiteralPath $marker){
        $owner=Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json
        if($owner.Kind -ne 'service-browser-v1' -or $owner.BrowserExecutablePath -ne $browser -or $owner.ProxyUrl -ne $proxy){throw 'This private profile belongs to different settings; use a new dedicated profile.'}
    }elseif(@(Get-ChildItem -LiteralPath $browserProfilePath -Force).Count){throw 'Do not reuse an existing personal browser profile.'}
}
$argsList=@(('--user-data-dir="'+$browserProfilePath+'"'),('--proxy-server="'+$proxy+'"'),'--disable-quic','--no-first-run','--no-default-browser-check','--new-window',$homeUri.AbsoluteUri)
if($Plan){[pscustomobject]@{Browser=[IO.Path]::GetFileName($browser);Arguments=$argsList;DedicatedProfile=$true;Proxy=$proxy;NetworkModified=$false;BrowserStarted=$false};exit}
$listeners=@(Get-NetTCPConnection -State Listen -LocalPort $uri.Port -ErrorAction SilentlyContinue)
if(-not $listeners.Count -or @($listeners|Where-Object LocalAddress -ne '127.0.0.1').Count){throw 'The intended proxy is not listening only on loopback; no browser was opened.'}
foreach($ownerId in @($listeners.OwningProcess|Sort-Object -Unique)){
    $p=Get-Process -Id $ownerId -ErrorAction Stop
    if($p.Path -ne $core){throw 'The listening process does not match the configured core; no browser was opened.'}
}
# A reused profile must not hand the window to an old instance with other proxy flags.
$active=@(Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'"|Where-Object {$_.CommandLine -and $_.CommandLine.IndexOf($browserProfilePath,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.CommandLine -notmatch '--type='})
foreach($p in $active){if($p.ExecutablePath -ne $browser -or $p.CommandLine.IndexOf(('--proxy-server="'+$proxy+'"'),[StringComparison]::OrdinalIgnoreCase) -lt 0){throw 'An existing dedicated window has different or unverified launch settings; no other browser was closed.'}}
$null=New-Item -ItemType Directory -Path $browserProfilePath -Force
if(-not (Test-Path -LiteralPath $marker)){@{Kind='service-browser-v1';BrowserExecutablePath=$browser;ProxyUrl=$proxy}|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding UTF8}
$null=Start-Process -FilePath $browser -ArgumentList ($argsList -join ' ')
[pscustomobject]@{BrowserLaunchRequested=$true;SystemProxyChanged=$false;OtherBrowserProfilesChanged=$false;IsolationVerified=$false}
