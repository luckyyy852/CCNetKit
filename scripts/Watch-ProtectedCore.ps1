param([Parameter(Mandatory=$true)][string]$SettingsPath,[ValidateSet('Run','Resume','Stop','Status')][string]$Action='Status')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Protection.Policy.ps1')
$sourceRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
function PrivatePath([string]$Path){
    if(-not [IO.Path]::IsPathRooted($Path) -or $Path.Contains('"')){throw 'Use absolute private paths without quotation marks.'}
    $full=[IO.Path]::GetFullPath($Path)
    if($full -eq $sourceRoot -or $full.StartsWith($sourceRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Private settings and state must remain outside the skill directory.'}
    $check=$full
    while($check){if((Test-Path -LiteralPath $check) -and ((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Use physical private paths without reparse points.'};$next=Split-Path $check -Parent;if($next -eq $check){break};$check=$next}
    $full
}
$settingsFull=PrivatePath $SettingsPath
$s=Get-Content -LiteralPath $settingsFull -Raw -Encoding UTF8|ConvertFrom-Json
if($s.SchemaVersion -ne 1){throw 'Unsupported private settings version.'}
$stateDir=PrivatePath $s.StateDirectory;$statePath=Join-Path $stateDir 'guard-state.json';$lockPath=Join-Path $stateDir 'locked.json';$stopPath=Join-Path $stateDir 'stop.request'
function ReadVerifiedState {
    $record=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
    $verified=$false
    try{$guardProcess=Get-Process -Id ([int]$record.pid) -ErrorAction Stop;$verified=($guardProcess.StartTime.ToUniversalTime().Ticks -eq ([datetime]::Parse($record.startTimeUtc)).ToUniversalTime().Ticks -and $guardProcess.MainModule.FileName -eq $record.executable)}catch{}
    [pscustomobject]@{Record=$record;Verified=$verified}
}
if($Action -eq 'Status'){
    if(Test-Path -LiteralPath $statePath){$checked=ReadVerifiedState;@{armed=([bool]$checked.Record.armed -and $checked.Verified);latched=([bool]$checked.Record.latched -or (Test-Path -LiteralPath $lockPath));GuardProcessVerified=$checked.Verified;reason=if($checked.Verified){$checked.Record.reason}else{'guard-not-running-or-unverified'}}|ConvertTo-Json}else{@{armed=$false;latched=(Test-Path -LiteralPath $lockPath);message='No recorded session; this does not verify isolation.'}|ConvertTo-Json};exit
}
if($Action -eq 'Stop'){if(-not (Test-Path -LiteralPath $statePath) -or -not (ReadVerifiedState).Verified){throw 'No verified running watcher; no process was stopped.'};[IO.File]::WriteAllText($stopPath,'manual-stop');exit}
$corePath=PrivatePath $s.CoreExecutablePath;$configPath=PrivatePath $s.CoreConfigPath;$dataDir=PrivatePath $s.CoreDataDirectory
if(-not (Test-Path -LiteralPath $corePath -PathType Leaf)){throw 'Dedicated core executable does not exist.'}
$cfg=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json
$spec=Test-ProtectedCoreConfig $cfg
$adapter=Get-NetAdapter -Physical -ErrorAction Stop|Where-Object {$_.Name -ceq $spec.Adapter}
if(@($adapter).Count -ne 1){throw 'Configured binding is not exactly one physical adapter.'}
function NetworkSignature {
    $physical=@(Get-NetAdapter -Physical -ErrorAction Stop|Where-Object Status -eq 'Up')
    $parts=@()
    foreach($a in $physical){
        foreach($family in @('IPv4','IPv6')){
            $prefix=if($family -eq 'IPv4'){'0.0.0.0/0'}else{'::/0'}
            $routes=@(Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily $family -DestinationPrefix $prefix -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
            foreach($r in $routes){$parts+=('{0}|{1}|{2}' -f $a.InterfaceGuid,$family,$r.NextHop)}
        }
    }
    if(-not $parts.Count){return 'offline'}
    $text=($parts|Sort-Object -Unique)-join ';';$sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}
}
$mutex=New-Object Threading.Mutex($false,'Local\NetworkWorkbench-ProtectedCore');$held=$false;$core=$null;$armed=$false;$starting=$false;$reason='startup-failed'
function WritePrivate($Path,$Value){$json=$Value|ConvertTo-Json -Depth 5;$tmp=$Path+'.tmp';[IO.File]::WriteAllText($tmp,$json,[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $tmp -Destination $Path -Force}
function RecordState([bool]$Locked,[string]$Reason){
    $me=Get-Process -Id $PID
    WritePrivate $statePath @{pid=$PID;startTimeUtc=$me.StartTime.ToUniversalTime().ToString('o');executable=$me.MainModule.FileName;armed=$armed;latched=$Locked;reason=$Reason;updatedUtc=[datetime]::UtcNow.ToString('o')}
}
try{
    try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not $held){throw 'A protected-core watcher is already running in this Windows session.'}
    if((Test-Path -LiteralPath $lockPath) -and $Action -ne 'Resume'){throw 'Session is locked; manual Resume is required.'}
    if(@(Get-NetTCPConnection -State Listen -LocalPort @($spec.Port,$spec.ControllerPort) -ErrorAction SilentlyContinue).Count){throw 'A dedicated port is already occupied; no existing process was stopped.'}
    $baseline=NetworkSignature
    if($baseline -eq 'offline'){throw 'No physical default route is ready.'}
    $null=New-Item -ItemType Directory -Path $stateDir,$dataDir -Force
    # Startup remains locked until the owned core and its ports have been verified.
    WritePrivate $lockPath @{reason='starting';at=[datetime]::UtcNow.ToString('o')}
    $starting=$true
    if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath}
    $configHash=(Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    $out=Join-Path $stateDir 'core-output.log';$err=Join-Path $stateDir 'core-error.log'
    & $corePath -t -d $dataDir -f $configPath *> $out
    if($LASTEXITCODE -ne 0){throw 'Dedicated configuration validation failed; see the private log.'}
    $core=Start-Process -FilePath $corePath -ArgumentList ('-d "'+$dataDir+'" -f "'+$configPath+'"') -WorkingDirectory $dataDir -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    $null=$core.Handle # Keep the original process handle, never kill by process name.
    $deadline=[datetime]::UtcNow.AddSeconds(10)
    do{
        if($core.HasExited){throw 'Dedicated core exited at startup.'}
        $listeners=@(Get-NetTCPConnection -State Listen -LocalPort @($spec.Port,$spec.ControllerPort) -ErrorAction SilentlyContinue)
        $ready=(@($listeners|Where-Object OwningProcess -eq $core.Id|Select-Object -ExpandProperty LocalPort -Unique).Count -eq 2)
        if(-not $ready){Start-Sleep -Milliseconds 200}
    }while(-not $ready -and [datetime]::UtcNow -lt $deadline)
    if(-not $ready -or @($listeners|Where-Object {$_.LocalAddress -ne '127.0.0.1' -or $_.OwningProcess -ne $core.Id}).Count){throw 'Dedicated listeners could not be verified as owned and loopback-only.'}
    if((NetworkSignature) -cne $baseline){throw 'Physical network changed during startup.'}
    $armed=$true;Remove-Item -LiteralPath $lockPath;RecordState $false 'running'
    $candidate='';$count=0
    while($true){
        Start-Sleep -Seconds 3
        $core.Refresh()
        $decision=Get-ProtectionDecision -Baseline $baseline -Current (NetworkSignature) -Candidate $candidate -Count $count -CoreAlive (-not $core.HasExited) -StopRequested (Test-Path -LiteralPath $stopPath) -ConfigChanged ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -cne $configHash)
        if($decision.Locked){$reason=$decision.Reason;break}
        $candidate=$decision.Candidate;$count=$decision.Count
    }
}finally{
    if($held -and $starting){
        if($core){try{if(-not $core.HasExited){$core.Kill();$null=$core.WaitForExit(5000)}}finally{$core.Dispose()}}
        $armed=$false
        WritePrivate $lockPath @{reason=$reason;at=[datetime]::UtcNow.ToString('o')}
        RecordState $true $reason
    }
    if($held){$mutex.ReleaseMutex()};$mutex.Dispose()
}
