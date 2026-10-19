function ConvertTo-RouteDomain([string]$InputText) {
    $text=$InputText.Trim()
    if(-not $text -or $text -match '[\s*"''<>]'){throw '请输入有效的网址或域名，不要输入软件名、空格或通配符。'}
    if($text -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://'){$text='https://'+$text}
    $uri=$null
    if(-not [uri]::TryCreate($text,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo){throw '只支持 http/https 网址或域名。'}
    $domain=(New-Object Globalization.IdnMapping).GetAscii($uri.DnsSafeHost.TrimEnd('.')).ToLowerInvariant()
    if($domain.StartsWith('www.')){$domain=$domain.Substring(4)}
    $ip=$null
    if([Net.IPAddress]::TryParse($domain,[ref]$ip) -or $domain.Length -gt 253 -or $domain -notmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$' -or $domain.EndsWith('.exe')){throw '请填写完整网站域名，例如 example.com；不能填写 IP、顶级域或软件名。'}
    return $domain
}
function Get-RouteEditedRules([string[]]$Rules,[string[]]$Managed,[string]$Domain,[string]$Action) {
    $owned=@($Managed|Sort-Object -Unique)
    $exact='DOMAIN-SUFFIX,'+$Domain+',DIRECT'
    if($Action -eq 'Direct' -and $Domain -notin $owned -and $exact -in $Rules){return [pscustomobject]@{Rules=@($Rules);Domains=@($owned);Preexisting=$true}}
    $managedRules=@($owned|ForEach-Object{'DOMAIN-SUFFIX,'+$_+',DIRECT'})
    $base=@($Rules|Where-Object {$_ -notin $managedRules})
    if($Action -eq 'Direct'){$owned=@($owned+$Domain|Sort-Object -Unique)}
    elseif($Action -eq 'Default'){$owned=@($owned|Where-Object {$_ -ne $Domain})}
    else{throw '未知域名操作。'}
    $custom=@($owned|ForEach-Object{'DOMAIN-SUFFIX,'+$_+',DIRECT'})
    $output=New-Object 'Collections.Generic.List[string]';$inserted=$false
    foreach($rule in $base){
        if(-not $inserted -and $rule -match '^(GEOSITE|GEOIP|RULE-SET|MATCH),'){foreach($entry in $custom){$output.Add($entry)};$inserted=$true}
        $output.Add($rule)
    }
    if(-not $inserted){throw '未找到日常分流规则位置，未更改配置。'}
    return [pscustomobject]@{Rules=@($output);Domains=@($owned)}
}