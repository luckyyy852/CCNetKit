# Claude Code 与同类应用的专用保护

本页的 Sandboxie/WFP 和守卫脚本仅适用于 Windows。Mac 转到 [Mac 接入流程](macos.md)，不要执行本页的 Windows 命令或声称具有同等保护。

目标是让指定应用只连接自己的固定代理入口：代理不可用时应用无法绕过它直连；真实物理网络变化时锁定专用连接，之后由使用者手动恢复。日常 TUN、微信和网站中转继续由原环境管理。

本流程分为固定出口、应用网络隔离、换网守卫三部分。管理窗口只显示状态；安装窗口不会自动完成后两部分。使用者自己的 Windows、应用版本与隔离组件必须经过下面的本机验收，不能把示例或纯逻辑测试说成已建立保护。

## 1. 准备独立代理核心

从 `assets/protected-core.example.json` 复制到仓库外的 `E:\PrivateNetwork\protected-core.json`，填写自己的节点、控制密钥与物理网卡名。节点类型可按官方协议字段替换；使用一个明确的固定出口节点，不使用动态轮换、自动回退或 DIRECT 作为备用。

模板为 TCP 应用准备：回环 mixed 端口 `17900`、控制端口 `19093`，不创建 TUN、不设置系统代理、不提供本机 DNS 服务，UDP 请求被拒绝。所有 TCP 走仅含一个节点的 `CC-ONLY`。先核对两个端口未占用，避免复用不明进程的监听端口。

`interface-name` 填实际物理网卡名，由 `Get-NetAdapter -Physical` 核对。绑定用于避免专用核心再次被日常 TUN 路由；实际 VPN / 驱动组合仍需检查，不宣称接口绑定能替代应用隔离。现有环境需要代理链时按具体网络单独设计，这个简单守卫模板拒绝未经核对的链式配置。

专用核心与数据放在仓库外的新目录。不要拿日常核心进程作为守卫的所有物，也不要将专用配置加入工作台可编辑 Profiles。将它加入 `ProtectedFiles`，避免日常域名操作修改它。

## 2. 建立应用的防直连边界

优先复用已验证的本机隔离 / 防火墙策略；首次部署可选 Sandboxie Plus 的 WFP 路径。使用官方 [安装来源](https://github.com/sandboxie-plus/Sandboxie/releases) 与 [WFP 文档](https://sandboxie-plus.github.io/sandboxie-docs/PlusContent/WFPSupport.html)，先核对版本、可用功能与许可证，不假定每个版本的代理 UI 都可用。不修改其他已有箱的策略。

创建独立箱 `ProtectedApp`。在原配置的相应节中合并以下字段，不能用片段覆盖整份 Sandboxie.ini：

```ini
[GlobalSettings]
NetworkEnableWFP=y

[ProtectedApp]
Enabled=y
AllowNetworkAccess=y
PromptForInternetAccess=n
NetworkAccess=*,Block
NetworkAccess=*,Allow;Port=17900;Address=127.0.0.1;Protocol=TCP
```

此处 `AllowNetworkAccess=y` 避免独立的全封锁门禁阻断代理，再由 NetworkAccess 的默认阻止与精确回环允许限制地址、端口和协议。WFP 开关是全局组件，启用前检查所有现有箱的规则及可能受影响的实例；组件已开启就复用，不反复切换。若不能在不影响已有箱的前提下开启，应选择已有可验证的隔离方案，不能默默降级为普通分流。

在该箱的网络防火墙界面核对实际生效规则和模板；删除本次新箱中与默认拒绝冲突的宽泛允许条目，不修改其他箱。规则有程序 / 端点优先级，并非“最后一条总生效”。只有用户态拦截时不能当作 WFP 已生效。不要设置阻断全部回环的额外选项，也不要把允许目标扩大到整个局域网或任意端口。来源：[NetworkAccess 语法与优先级](https://sandboxie-plus.github.io/sandboxie-docs/Content/NetworkAccess/)。

只在自己的箱内配置目标应用的启动强制规则，并核对主程序、相关子进程和升级路径。可以在 Program Control / Force Programs 中选择实际程序，不应将所有浏览器、`node.exe`、`powershell.exe` 或整个项目开发目录强制进箱。已有进程不会因为新增强制规则自动受保护；保存工作后退出目标应用，再从保护入口启动。AppContainer、服务进程与更新器需单独核验，不能假定进程名强制覆盖全部情况。来源：[ForceProcess](https://sandboxie-plus.github.io/sandboxie-docs/Content/ForceProcess/)。

## 3. 让应用连接允许的入口

应用内代理优先填写 `http://127.0.0.1:17900` 或 SOCKS5 的相同地址端口。没有应用代理设置时，只采用该应用版本实际支持的方式，或使用隔离组件可用的 Internet Proxy 功能。不能凭空添加不存在的菜单，也不能把 `--proxy-server` 或环境变量的设置本身当作生效证据。

Claude Code CLI 可按其 [官方网络配置](https://code.claude.com/docs/en/network-config) 使用 HTTP / HTTPS 代理环境变量；只在受保护启动流程中设置，避免写入全局用户环境而影响网站开发：

```powershell
$env:HTTP_PROXY='http://127.0.0.1:17900'
$env:HTTPS_PROXY='http://127.0.0.1:17900'
$env:NO_PROXY='localhost,127.0.0.1'
# 在受保护箱内的终端启动自己的 claude 命令；不要从普通未受保护终端继续使用。
```

这里以 Claude Code 本机 CLI 为例；Claude 桌面聊天与其中的 Code 会话需分别核验，不能因 CLI 生效就认定它们也生效。需要外部浏览器登录时浏览器仍遵守它自己的路线；不为了登录将整个箱的 Internet 临时开放。回调需要其他本地端口时先明确其作用与监听方，做最小的单独例外后重新验收，不能直接允许所有本机端口。

Claude Code 的后台 supervisor、服务和工作进程可能不从当前终端继承设置。需要后台模式时按官方网络与启动包装器文档核对它们的启动范围、配置来源和隔离归属；这份前台终端示例不能直接证明后台模式受保护。CLI 使用 HTTP 代理入口，不能将 SOCKS URL 当作它已支持的原生代理。

使用官方 Sandboxie 启动器启动 Claude Code 本机可执行文件的路径示例：

```powershell
& 'C:\Program Files\Sandboxie-Plus\Start.exe' /box:ProtectedApp 'E:\Apps\ClaudeCode\claude.exe'
```

这是虚构的应用路径，填写自己的安装位置；后台已有未入箱实例时，单实例应用可能把请求转交过去，必须检查实际进程所在箱。启动器来源：[Start 命令行](https://sandboxie-plus.github.io/sandboxie-docs/Content/StartCommandLine/)。

本机隔离不等于云端沙箱。项目读写可按用户任务开放必要目录，敏感文件另按文件访问策略处理；不要用整个磁盘放行来解决网络问题。外部服务、COM 代理和未入箱的子进程不能自动继承这条保证。

## 4. 安装换网锁定守卫

附带 `scripts/Watch-ProtectedCore.ps1` 与 `Protection.Policy.ps1`。它只启动并持有自己创建的专用核心进程；不停止日常 TUN、不写系统代理、不改网卡 DNS、不安装启动任务，也不控制应用文件权限。它不是隔离器，必须先完成上面的防直连边界。

将 `assets/protected-session.example.json` 复制到私人 `E:\PrivateNetwork\protected-session.json`，填写专用内核、配置、数据和状态目录。四个目录 / 文件路径都要来自自己的机器，状态目录专门给这个守卫使用，不能指向其他应用数据目录。脚本及专用配置应使用适当 ACL，禁止受保护应用随意篡改；不要允许箱内程序访问守卫控制目录或专用核心的控制 API。

先在普通 PowerShell 校验脚本来源与私人配置，再运行：

```powershell
.\scripts\Watch-ProtectedCore.ps1 -SettingsPath E:\PrivateNetwork\protected-session.json -Action Run
```

这是持续运行的守卫，不是运行完就退出的安装命令。需要隐藏后台窗口时可由本机任务或隐藏 PowerShell 托管，使用固定脚本路径，避免绑定到临时下载目录。默认一个 Windows 会话只允许一个此守卫；同一专用出口可为多个受保护应用提供入口，多个不同专用出口需独立设计与验收，不能直接复制同名任务互抢端口。

行为说明：

- 只观察物理网卡上活动的默认网关集合，连续两次、每次间隔 3 秒不同才锁定；网卡上下线 / 网关切换包括在内。普通连接数量、DNS 值、IPv6 临时地址、流量峰值与单个 HTTP 超时不参与判断。此定义不等于检测所有形式的网络变化，短于采样间隔的切换可能不被观察。
- 专用核心退出、专用配置变更或手动 Stop 会锁定。脚本不测试远程 HTTP，因此远程瞬断只让应用请求失败，不自动断开其他网络。
- 锁定只终止其自己启动并持有句柄的专用核心，写入 `locked.json`；不按进程名批量结束任何程序。不自动重启、选备用节点或清除锁定。
- 守卫是采样与进程托管，不是零时间窗口的内核换网阻断。强制终止守卫、系统异常、其他管理员重配或恶意绕过不在脚本的可靠托管保证内；检查守卫进程死亡时不能继续报告“换网守卫正常”。应用的直接联网限制依靠前面的 WFP 边界持续提供。

查询、手动停用与手动恢复：

```powershell
.\scripts\Watch-ProtectedCore.ps1 -SettingsPath E:\PrivateNetwork\protected-session.json -Action Status
.\scripts\Watch-ProtectedCore.ps1 -SettingsPath E:\PrivateNetwork\protected-session.json -Action Stop
# 守卫退出并核对当前网络后，由使用者明确执行下面这条；恢复本身不会自动打开应用。
.\scripts\Watch-ProtectedCore.ps1 -SettingsPath E:\PrivateNetwork\protected-session.json -Action Resume
```

Resume 是持续运行的新守卫，会以当次物理网络为基准，校验并重新启动专用核心，然后清除本轮锁定。已有锁定时 Run 拒绝启动，计划任务也不能自动改为 Resume。发现端口被已有进程占用时拒绝启动，不杀占用者。Status 是本机状态，不是网络隔离验收证书。

## 5. 接入工作台状态

在私人工作台设置中添加：

```json
{
  "Protection": {
    "GuardStatePath": "E:\\PrivateNetwork\\protected-state\\guard-state.json",
    "LockPath": "E:\\PrivateNetwork\\protected-state\\locked.json"
  }
}
```

把专用配置加入 `ProtectedFiles`，不要加入 `Profiles`。工作台只读观察守卫身份、状态与锁定；它不会解锁这个新守卫，恢复使用上面的显式 Resume。守卫在线不表示所有目标进程都确实入箱。

## 6. 在使用者机器逐项验收

先保存目标应用工作，以下停代理和换网动作会有意断开它，不能当成无感测试：

| 场景 | 实际应观察的结果 |
| --- | --- |
| 专用代理正常 | 目标进程及相关子进程确实在箱内；完成一条实际请求，确认专用入口与预期节点 |
| 专用核心停止 | 应用无法完成外部请求；不会改走日常代理、国内直连或其他本地端口；国内软件仍正常 |
| 禁用应用代理后的直接请求 | 在隔离规则仍开启时，真实 TCP / UDP 与 IPv4 / IPv6 直连被阻止；若有透明 SOCKS 拦截，应在独立测试箱中关掉该重定向后测试 WFP，不把“被重新代理”当作“直连被拒绝” |
| 正常短超时 | 不触发守卫锁定，不重启日常网络，不自动替换节点 |
| 实际物理网卡 / 默认网关变化 | 在文档采样范围内锁定，只停自有专用核心；恢复物理网络后仍锁定，Run 不会解锁 |
| 手动 Resume、软件更新、重启 / 唤醒 | 核对当次入口、强制入箱路径、守卫进程与固定节点；已锁定时不会因启动任务自行恢复 |
| 日常网络与网站中转 | 国内图片上传、普通网页和原网站请求实际可用；原中转 URL / 密钥 / 规则未被改动 |

用本机观察与实际请求验证，不能仅靠规则编辑器的“测试规则”、代理 IP 网页或源代码阅读作结论。未完成的行明确记录为未验证；公开测试使用合成配置且不在当前用户机器安装 WFP 或切换网络。

## 7. 撤回与卸载

先退出受保护应用，再请求守卫 Stop 并确认专用核心退出。只撤销本次为目标应用添加的入口、强制规则与箱；保留其他箱、日常 TUN、网站例外及用户数据。全局 WFP 被其他箱使用时保留，不因删除这个箱而关闭。应用原来在箱内形成的数据需按 Sandboxie 官方恢复方式处理，不能直接删除整个箱内容。退回普通未保护使用方式须由使用者明确选择，不能把它当成静默故障回退。
