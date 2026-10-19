# Mac 接入流程

本页供执行 skill 的 AI 阅读。用户提供自己的节点与目标，由 AI 完成配置。Mac 使用本地浏览器界面，Windows 继续使用原后端。

## 识别与准备

运行 `python3 scripts/workbench.py detect` 自动识别系统。缺少 Python 时用 `uname -s` 识别 Mac，用 `uname -m` 区分 Apple Silicon（arm64）与 Intel（x86_64）。只读核对现有客户端持久配置、TUN、系统代理、默认路由和控制端口，优先复用，不重启正常网络。

管理界面需要 Python 3.10+；先检查 `python3 --version`。缺少时按目标机环境从 [Python 官方](https://www.python.org/downloads/macos/) 或已有包管理器安装，不默认安装 Homebrew、开发工具链或 PowerShell。

先核对依赖下载是否可达；受限时复用已有可信工具，或由用户提供官方离线包路径，不依赖尚未配置好的同一条代理。安装前由 AI 创建所选私人目录和安装目录的父目录，设置相应权限；安装器不会替用户创建缺失的父目录。

没有 Mihomo 时，从 [官方安装页](https://wiki.metacubex.one/startup/) 获取对应 `darwin-arm64` 或 `darwin-amd64` 的稳定内核，按官方校验信息核对，再放入用户私人工具目录。不要关闭系统安全功能来运行不明二进制。

## 接入自己的节点

共用 [Mihomo 配置说明](mihomo-setup.md) 中的节点、订阅及国内分流原则，从合成 `assets/mihomo.example.json` 生成仓库外的私人 JSON。替换用户真实节点与随机控制密钥；控制器仅监听 `127.0.0.1`。已有客户端生成 YAML 时使用持久覆写，不能改临时产物或只改扩展名。

私人目录可选 `$HOME/PrivateNetwork`，工具可选 `$HOME/Tools`。配置目录权限 700，凭据文件 600。样例的 `/Users/example/` 必须由 AI 替换为目标机当前用户的绝对路径。校验命令：

```sh
"$HOME/Tools/mihomo/mihomo" -t -d "$HOME/PrivateNetwork" -f "$HOME/PrivateNetwork/daily.json"
```

先验证授权的非 TUN 显式代理，再按需求使用 [官方 TUN 文档](https://wiki.metacubex.one/config/inbound/tun/) 配置 Mac 的 utun 接口。不要套用 Windows 驱动、网卡名、注册表、计划任务和临时兼容参数。保留既有 DNS、国内规则和网站中转，只保留一个日常 TUN。优先由已有客户端管理权限和生命周期，不让网页管理程序以 root 运行。

安装界面默认不设置开机任务。确需开机连接时，使用现有客户端官方服务方式，或按目标机 `man launchd.plist` 配置独立任务，并记录停用方式，不覆盖其他任务。

## 安装管理界面

1. 在仓库外复制 `assets/settings.macos.example.json`，填写真实绝对路径。`Profiles` 仅放日常可编辑配置。原中转规则加入 `ProtectedRules`，专用配置和网站环境文件加入 `ProtectedFiles`；专用核心不要放入可编辑列表。
2. 普通用户运行：

   ```sh
   python3 scripts/workbench.py install --root "$HOME/Tools/NetworkWorkbench" --settings "$HOME/PrivateNetwork/settings.json"
   ```

3. 双击安装目录的 `Open Workbench.command`，或运行：

   ```sh
   python3 "$HOME/Tools/NetworkWorkbench/bin/mac_workbench.py" --root "$HOME/Tools/NetworkWorkbench"
   ```

安装只复制管理程序和私人设置到新目录，不覆盖已有安装，不启动核心或改系统代理。界面绑定随机回环端口，使用每次启动不同的会话凭据，不对局域网开放。关闭终端进程即停止界面，原网络继续运行；会话地址不要公开。

管理程序核对控制器监听进程路径、启动时间、规则模式和保护文件。只改自己添加的直连规则，校验后热加载，失败回退。文件不可写或身份无法确认时拒绝修改，不自动 sudo、不停止核心。root 或客户端托管的配置应接入受支持的覆写入口，不能开放所有人写权限。Mac 暂不提供月度用量查询。

运行目录 `data/pending.json` 是最多一份的私人事务恢复记录，含原配置，不可公开。正常结束或确认回退后自动移除；若程序中途退出，重新打开会停用写入。由 AI 对照该记录、当前文件和实际核心身份恢复并验证，再移除记录；不要直接删记录后继续改规则。它不属于源码或发布包。

## 软件分流与专用保护

共用 [软件分流说明](application-routing.md) 的节点、入口和完整服务域名流程。进程路径使用 Mac 实际可执行文件，例如应用包的 `Contents/MacOS/`，不用 `.exe`，不接管所有共享运行时。

普通 Chrome / Edge 可用现有浏览器加独立 `--user-data-dir`、固定 `--proxy-server=http://127.0.0.1:<专用端口>`、`--disable-quic`。由 AI 检查真实浏览器路径、独立目录与代理监听归属，再创建本机启动入口；参数以数组传递，不拼接未转义 shell 字符、不复用日常资料目录、不启用远程调试。已有指纹浏览器可接入其独立代理。不要在 Mac 运行 Windows 的 Open-ServiceBrowser.ps1。

代理分流不等于严格防直连。Windows 的 Sandboxie/WFP、DPAPI、Watch-ProtectedCore.ps1 不适用于 Mac。**本包没有等价的 Mac 出站隔离器或换网守卫，不得声称自动安装后已有这些保护。** 保留目标机原有保护；新增严格保护须先确认可用系统出站隔离能约束目标应用与子进程、IPv4/IPv6、TCP/UDP，再实施和现场验证。没有对应能力时报告尚未建立，不用代理设置或出口 IP 代替，不擅自安装付费软件或改全机防火墙。

## 目标机验收

先运行 `python3 tests/test_macos.py`，仅使用虚构配置和回环 stub。再检查真实核心身份、连接显示、一次可撤回的域名修改与恢复、原中转和已有保护。用户要求 TUN、待机恢复或专用保护时再做对应验收。Windows 上测试通过不代表已完成 Mac 真机或系统隔离验证。
