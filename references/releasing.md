# 发布前检查

本页面向发布维护者，不是普通用户的安装步骤。发布前阅读本页，只打包白名单；不要上传安装目录、data、真实设置或配置备份。`.gitignore` 不能让已经泄露的密钥自动失效；如有泄露，应在对应服务撤销并轮换，随后清理公开历史。

公开的是通用技能和源码，不是用户正在运行的网络目录。以下内容全部留在仓库外：节点/订阅、真实配置、settings.json、routes.json、环境文件、DPAPI 凭据、日志、状态、截图、数据库、回退备份和编译产物。

## 本地验证

运行 Windows 测试和隐私扫描：

```powershell
.\tests\Test-Workbench.ps1 -WorkRoot E:\Temp\WorkbenchTests
.\tests\Test-ProtectionPolicy.ps1
.\tests\Test-ProtectedCore.ps1 -WorkRoot E:\Temp\ProtectedCoreTests
.\tests\Test-ServiceBrowser.ps1 -WorkRoot E:\Temp\ServiceBrowserTests
python .\tests\test_release.py
python .\tests\test_macos.py
python .\tests\test_fresh_install.py
.\tests\Test-FreshInstall.ps1 -WorkRoot E:\Temp\FreshInstallTests
python .\scripts\audit_release.py .
```

首次安装检查会打包、解压到含空格和中文的私人测试目录，再运行解压后的安装入口；只使用合成数据和回环控制器。Windows 非管理员运行只验证拒绝安装且无残留，不能当作管理员安装通过；CI 使用 `-RequireAdmin` 实际验证安装、权限、界面读取、域名往返及重复安装拒绝。Mac 安装与本地界面启动在 Mac CI 执行，窗口中离线核心必须显示为未连通，不假装外网已通。

测试输出也不要放回源码目录。扫描只返回相对文件名和类别，不复述匹配内容。若有权限比对本机真实敏感值，可向 audit 的 deny_values 参数传入内存数据，或使用仓库外的本地 JSON 列表；不要把真实值列表提交或打包。

## 白名单打包

Mac 测试还需在 macOS 执行 `python3 tests/test_macos.py`，包括 POSIX 文件锁和权限检查。工作流已添加 macOS 测试任务，但仅编写任务不等于已经运行。发布者没有 Mac 真机时应保留 README 中的验证范围说明，不能把 Windows 合成测试宣传成 Mac 真机验收。

GitHub Actions 在 main 更新、拉取请求或手动运行时检查；发布标签不重复触发同一份测试，同一分支或拉取请求只保留最新任务。单个任务开始执行后限时 15 分钟，此限时不包括等待执行机器的排队时间。遇到长时间排队先核对 GitHub 服务状态和实际任务记录，不把排队或取消写成测试通过。

scripts/release_manifest.py 是唯一白名单来源。新增通用源码时同步更新它；不要为了让扫描通过而把运行文件加入白名单。

```powershell
python .\scripts\package_release.py . E:\Releases\ccnetkit.zip
```

打包前必须扫描通过，压缩包只收白名单文件，并再次核对内容；同时生成 SHA-256 文件。发布结果应表述为“检查未检出”，不能保证任意未来编辑绝无隐私泄漏。

用户只要求准备公开包时，不自动创建仓库或推送。实际发布需另外明确的授权和目标仓库。README、示例和演示图只使用合成数据；作者可自行填写公开身份，不复用机器上的 Git 身份信息。

## 演示图

`assets/workbench-demo.png` 由公开版程序的 `--preview` 模式离屏渲染，使用固定的虚构域名、程序名、流量与时间，不调用真实控制 API、不枚举连接、不截取桌面。该图已人工验看；发布扫描对它执行白名单 SHA-256 核对，不将图片冒充为已完成文本隐私扫描。

需要更新时，在仓库外用 `scripts/Build-Workbench.ps1 -OutDirectory E:\Temp\WorkbenchDemo\bin` 编译，将 `NETWORK_WORKBENCH_HOME` 设为 `E:\Temp\WorkbenchDemo`，运行编译后的 `Workbench.exe --preview`。检查生成的 `data/preview.png` 所有可见内容与 PNG 元数据，确认只有虚构数据，再复制到上述素材路径并更新 `release_manifest.py` 中已审查图片的哈希。不要用真实连接截图替代，不要直接允许任意二进制文件通过扫描。

## 范围与依赖

同一技能自动分流至 Windows 原 WinForms / PowerShell 后端或 macOS 的 Python 本地界面。Mac 目前支持安装、连接查询、搜索和事务式域名管理；月度用量、专用核心守卫及系统出站隔离不在 Mac 实现范围内。不要在对外介绍中省略这一差异。

本发布版包含使用自己的 VPS、订阅或代理服务安装配置 Mihomo 的步骤，以及独立安装的管理窗口。内核由使用者从官方发行页获取，真实节点与配置始终保存在源码之外。安装窗口脚本本身不改变当前网络或安装第三方隔离；指南中的启动内核、开启 TUN 则会按步骤影响对应网络。真实节点、服务商和不同客户端行为需使用者验证。没有把某台电脑的临时修复参数作为全部用户的默认设置。

软件分流、网络兼容与 Claude Code 保护是可执行的通用流程，专用核心守卫为可选脚本。公开自动测试只覆盖合成配置、状态转换与回环测试，不在发布者现有环境执行换网、WFP 安装或 Claude Code 停用。发布说明必须把这些逻辑验证与使用者机器上的真实隔离验收区分开；不将文档流程称为已适配全部客户端的一键安装器。
