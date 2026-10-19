param([ValidateSet('Direct','Default')][string]$Action,[string]$Domain,[ValidatePattern('^[a-f0-9]{32}$')][string]$RequestId)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Workbench.Common.ps1')
. (Join-Path $PSScriptRoot 'RoutePolicy.ps1')
$result=[ordered]@{RequestId=$RequestId;Domain=$Domain;Action=$Action;Success=$false;Message='';TimeUtc=[datetime]::UtcNow.ToString('o')}
$statePath=Join-Path $WorkbenchRoot 'routes.json';$mutex=$null;$held=$false;$written=$false;$saved=@();$reloaded=@()
try{
    if(-not $RequestId){throw '缺少操作编号。'}
    if((ConvertTo-RouteDomain $Domain) -cne $Domain){throw '域名未规范化。'}
    $hash=[Security.Cryptography.SHA256]::Create();try{$id=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($WorkbenchRoot.ToLowerInvariant())))).Replace('-','').Substring(0,20)}finally{$hash.Dispose()}
    $mutex=New-Object Threading.Mutex($false,('Local\NetworkWorkbench-'+$id))
    try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not $held){throw '有其他分流操作正在执行，请稍后再试。'}
    $state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
    $managed=@($state.Domains);foreach($name in $managed){if((ConvertTo-RouteDomain $name) -cne $name){throw '域名管理记录异常。'}}
    $profiles=@($Settings.Profiles|Where-Object {$_.ManageRules -eq $true});if(-not $profiles.Count){throw '没有授权可修改的日常配置。'}
    $protected=@($Settings.ProtectedFiles|ForEach-Object{@{Path=[IO.Path]::GetFullPath($_);Hash=(Get-FileHash -LiteralPath $_).Hash}})
    $fingerprint=Get-ProtectionFingerprint;$active=@();$plan=@();$domains=@()
    foreach($profile in $profiles){
        $path=[IO.Path]::GetFullPath($profile.ConfigPath)
        if($path -in $protected.Path){throw '日常配置路径与受保护文件重合，未修改。'}
        if(-not (Test-Path -LiteralPath $profile.ExecutablePath -PathType Leaf)){throw '找不到指定的 Mihomo 内核。'}
        $cfg=Get-ProfileConfig $profile
        if($cfg.mode -ne 'rule'){throw '仅支持规则模式，未改变当前模式。'}
        foreach($pinned in @($profile.ProtectedRules)){if($pinned -notin @($cfg.rules)){throw '预设保护规则不完整，未修改。'}}
        $edit=Get-RouteEditedRules -Rules $cfg.rules -Managed $managed -Domain $Domain -Action $Action
        if($plan.Count -gt 0 -and (($domains|ConvertTo-Json -Compress) -cne ($edit.Domains|ConvertTo-Json -Compress))){throw '不同配置中的规则归属不一致，未接管其他规则。'}
        $domains=$edit.Domains;$oldRules=@($cfg.rules)|ConvertTo-Json -Compress;$cfg.rules=@($edit.Rules)
        foreach($pinned in @($profile.ProtectedRules)){if($pinned -notin @($cfg.rules)){throw '本次操作会影响预设保护规则，已停止。'}}
        $plan+=@{Profile=$profile;Path=$path;Config=$cfg;Changed=($oldRules -cne ($cfg.rules|ConvertTo-Json -Compress))}
        if($profile.Reload -ne $false){
            $core=Get-ProfileCore $profile
            if($core){$live=Invoke-WorkbenchApi $profile '/configs';if($live.mode -ne 'rule'){throw '运行中的内核不在规则模式。'};$active+=@{Profile=$profile;Identity=$core}}
        }
    }
    if(-not @($plan|Where-Object Changed).Count){
        $result.Success=$true;$result.NoChange=$true
        $result.Message=if($Action -eq 'Default'){'没有该域名的额外设置，原有规则保持不变。'}elseif($Domain -in $managed){'已设置该域名直连，无需重复修改。'}else{'已有原有直连规则；未接管或删除它。'}
    }else{
        $backup=Join-Path $WorkbenchRoot 'rollback';if(-not (Test-Path -LiteralPath $backup)){$null=New-Item -ItemType Directory -Path $backup}
        $index=0
        foreach($path in @($plan.Path)+@($statePath)){$index++;$to=Join-Path $backup ($index.ToString()+'.json');Copy-Item -LiteralPath $path -Destination $to -Force;$saved+=@{Path=$path;Backup=$to}}
        $written=$true
        foreach($item in $plan){
            if(-not $item.Changed){continue}
            $item.Config|ConvertTo-Json -Depth 60|Set-Content -LiteralPath $item.Path -Encoding UTF8
            $coreDataDirectory=if($item.Profile.DataDirectory){$item.Profile.DataDirectory}else{Split-Path $item.Path -Parent}
            $validation=& $item.Profile.ExecutablePath -t -d $coreDataDirectory -f $item.Path 2>&1
            if($LASTEXITCODE -ne 0){throw '内核配置校验失败。'}
        }
        foreach($entry in $active){
            $profile=$entry.Profile;$now=Get-ProfileCore $profile
            if(-not $now -or $now.PID -ne $entry.Identity.PID -or $now.Ticks -ne $entry.Identity.Ticks){throw '操作期间内核身份改变，已停止。'}
            $reloaded+=$profile
            $null=Invoke-WorkbenchApi $profile '/configs?force=false' 'PUT' (@{path=$profile.ConfigPath}|ConvertTo-Json -Compress)
            $liveRules=(Invoke-WorkbenchApi $profile '/rules').rules
            foreach($name in $domains){if(-not @($liveRules|Where-Object {$_.type -eq 'DomainSuffix' -and $_.payload -eq $name -and $_.proxy -eq 'DIRECT'}).Count){throw '运行中规则校验失败。'}}
            if($Action -eq 'Default' -and $Domain -notin $domains){
                $expected=@((Get-ProfileConfig $profile).rules)
                if(('DOMAIN-SUFFIX,'+$Domain+',DIRECT') -notin $expected -and @($liveRules|Where-Object {$_.type -eq 'DomainSuffix' -and $_.payload -eq $Domain -and $_.proxy -eq 'DIRECT'}).Count){throw '待移除的额外规则仍存在。'}
            }
            foreach($pinned in @($profile.ProtectedRules)){
                $parts=$pinned.Split(',');if($parts[0] -in @('DOMAIN','DOMAIN-SUFFIX')){$kind=if($parts[0] -eq 'DOMAIN'){'Domain'}else{'DomainSuffix'};if(-not @($liveRules|Where-Object {$_.type -eq $kind -and $_.payload -eq $parts[1] -and $_.proxy -eq $parts[2]}).Count){throw '运行中的预设保护规则不完整。'}}
            }
        }
        foreach($h in $protected){if((Get-FileHash -LiteralPath $h.Path).Hash -ne $h.Hash){throw '受保护文件发生变化，未重置专用保护。'}}
        if((Get-ProtectionFingerprint) -cne $fingerprint){throw '专用守卫状态在操作期间发生变化，未自动解锁。'}
        foreach($entry in $active){$now=Get-ProfileCore $entry.Profile;if(-not $now -or $now.PID -ne $entry.Identity.PID -or $now.Ticks -ne $entry.Identity.Ticks){throw '内核身份校验未通过。'}}
        @{Version=1;Domains=@($domains)}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $statePath -Encoding UTF8
        $result.Success=$true;$result.AppliedCores=$active.Count
        $result.Message=if($Action -eq 'Direct'){'已设置国内直连：'+$Domain+'（含子域名）。'}else{'已移除该域名的额外设置，按剩余默认规则分流。'}
        $result.Message+=if($active.Count){' 已保存并热加载，请刷新目标网站。'}else{' 已保存，日常核心下次启动时生效。'}
    }
    if($Action -eq 'Default'){$parents=@($managed|Where-Object {$_ -ne $Domain -and $Domain.EndsWith('.'+$_)});if($parents.Count){$result.Message+=' 父域名设置仍适用：'+($parents -join '、')+'。'}}
}catch{
    $result.Message='未完成：'+$_.Exception.GetBaseException().Message
    if($written){try{foreach($backup in $saved){Copy-Item -LiteralPath $backup.Backup -Destination $backup.Path -Force};foreach($profile in $reloaded){$null=Invoke-WorkbenchApi $profile '/configs?force=false' 'PUT' (@{path=$profile.ConfigPath}|ConvertTo-Json -Compress)};$result.RolledBack=$true}catch{$result.RollbackIncomplete=$true;$result.Message+=' 回退未确认完成，请停止重复操作并查看本机记录。'}}
}finally{
    if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
    Write-OperationResult 'route-result.json' $result
}
if(-not $result.Success){exit 1}
