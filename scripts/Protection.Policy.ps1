function Get-ProtectionDecision {
    param([string]$Baseline,[string]$Current,[string]$Candidate='',[int]$Count=0,[bool]$CoreAlive=$true,[bool]$StopRequested=$false,[bool]$ConfigChanged=$false,[bool]$Latched=$false)
    $reason=''
    if($Latched){$reason='already-locked'}
    elseif($StopRequested){$reason='manual-stop'}
    elseif(-not $CoreAlive){$reason='dedicated-core-exited'}
    elseif($ConfigChanged){$reason='dedicated-config-changed'}
    elseif($Current -ceq $Baseline){$Count=0;$Candidate=''}
    else{
        if($Current -ceq $Candidate){$Count++}else{$Candidate=$Current;$Count=1}
        if($Count -ge 2){$reason='physical-network-changed'}
    }
    [pscustomobject]@{Locked=([bool]$reason);Reason=$reason;Candidate=$Candidate;Count=$Count}
}
function Test-ProtectedCoreConfig($Config){
    if($Config.mode -ne 'rule' -or $Config.'allow-lan' -ne $false -or $Config.'bind-address' -ne '127.0.0.1' -or $Config.tun.enable -ne $false -or $Config.dns.enable -ne $false){throw 'Dedicated core must be loopback-only, rule mode, without TUN or local DNS.'}
    $port=[int]$Config.'mixed-port';$uri=$null
    if($port -lt 1024 -or $port -gt 65535 -or -not [uri]::TryCreate(('http://'+$Config.'external-controller'),[UriKind]::Absolute,[ref]$uri) -or $uri.Host -ne '127.0.0.1' -or $uri.Port -lt 1024 -or $uri.Port -eq $port -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment){throw 'Use distinct loopback proxy/controller ports above 1023.'}
    if(-not $Config.secret -or $Config.secret -match '^YOUR_' -or -not $Config.'interface-name' -or $Config.'interface-name' -match '^YOUR_'){throw 'Set a private controller secret and the physical adapter name.'}
    $groups=@($Config.'proxy-groups');$nodes=@($Config.proxies)
    if($groups.Count -ne 1 -or $groups[0].name -ne 'CC-ONLY' -or $groups[0].type -ne 'select' -or @($groups[0].proxies).Count -ne 1 -or $nodes.Count -ne 1 -or $groups[0].proxies[0] -cne $nodes[0].name -or $nodes[0].type -in @('direct','reject','dns') -or -not $nodes[0].server -or $nodes[0].server -eq '192.0.2.10' -or $nodes[0].name -in @('DIRECT','REJECT')){throw 'Use exactly one real node in the dedicated CC-ONLY group, without fallback.'}
    if(($Config.rules -join '|') -cne 'NETWORK,udp,REJECT|MATCH,CC-ONLY'){throw 'Dedicated rules must reject UDP and send all TCP to CC-ONLY.'}
    $allowed=@('mixed-port','allow-lan','bind-address','mode','log-level','external-controller','secret','interface-name','tun','dns','proxies','proxy-groups','rules')
    foreach($p in $Config.PSObject.Properties){if($p.Name -notin $allowed){throw 'Unexpected dedicated-core top-level setting; review instead of silently accepting it.'}}
    foreach($p in $groups[0].PSObject.Properties){if($p.Name -notin @('name','type','proxies')){throw 'The dedicated group must not import or automatically select other nodes.'}}
    if($nodes[0].'dialer-proxy'){throw 'An unreviewed upstream chain is not accepted by this dedicated-core recipe.'}
    [pscustomobject]@{Port=$port;ControllerPort=$uri.Port;Adapter=[string]$Config.'interface-name'}
}
