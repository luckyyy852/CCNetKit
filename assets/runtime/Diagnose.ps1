param([ValidatePattern('^[a-f0-9]{32}$')][string]$RequestId)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Workbench.Common.ps1')
$checks=@();$success=$true
foreach($profile in $Settings.Profiles){
    if($profile.Reload -eq $false){continue}
    try{
        $cfg=Get-ProfileConfig $profile;$core=Get-ProfileCore $profile
        $live=Invoke-WorkbenchApi $profile '/configs'
        if(-not $core -or $cfg.mode -ne 'rule' -or $live.mode -ne 'rule'){throw '规则模式或内核身份检查未通过。'}
        $checks+=@{Profile=$profile.Name;Success=$true;TunEnabled=[bool]$live.tun.enable;ReadOnly=$true}
    }catch{$success=$false;$checks+=@{Profile=$profile.Name;Success=$false;ReadOnly=$true}}
}
if(-not $checks.Count){$success=$false}
$message=if($success){'本机 API、内核身份和规则模式检查通过；未发送外网测试，也未修改网络。'}else{'部分本机检查未通过；没有切换、重启网络或恢复专用连接。'}
Write-OperationResult 'diagnostic-result.json' @{RequestId=$RequestId;Success=$success;Message=$message;Checks=$checks}
if(-not $success){exit 1}
