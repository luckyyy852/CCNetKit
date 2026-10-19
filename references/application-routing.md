# 按软件分流，包括 Grok Bot

Grok Bot 在这里是软件示例；同名工具可能来自不同开发者，不能假定它一定有某个代理菜单、固定文件名或相同服务域名。下面全部路径与域名为虚构示例。实际配置仅在使用者本机填写。

## 1. 识别实际发起连接的进程

用工作台连接表与应用安装目录确认主程序、子进程和实际请求。必要时按已知目标 PID 查看完整路径和监听 / 出站记录，不将整机命令行或带凭据的环境输出到公开日志。

优先使用完整 `PROCESS-PATH`。`PROCESS-NAME` 会影响所有同名实例；特别不要把 `node.exe`、`python.exe`、共享浏览器或代理内核整体当成 Grok Bot。软件升级后路径可能变化，必须重新核验。没有进程信息的设备或跨主机请求不能靠 Windows 进程规则识别。

## 2. 根据软件能力选择接入

### A. 应用本身支持代理

优先在该软件自己的设置中使用已存在的回环 HTTP / SOCKS 代理，或为它创建单独的 Mihomo mixed 监听入口。示例顶层字段，合入自己日常配置而不是作为完整配置：

```json
{
  "listeners": [
    {"name":"grok-bot-in","type":"mixed","listen":"127.0.0.1","port":18082,"proxy":"GROK-ROUTE"}
  ],
  "proxy-groups": [
    {"name":"GROK-ROUTE","type":"select","proxies":["MY-NODE"]}
  ]
}
```

`MY-NODE` 必须是原配置中使用者自己的有效节点名。保留原有监听器和策略组，避免名字与端口冲突。`proxy` 将这个入口固定送到该策略，不依赖进程识别，也不会被工作台域名按钮改变。

如果 Grok Bot 提供代理选项，在本机填写 HTTP `http://127.0.0.1:18082`，或 SOCKS5 主机 `127.0.0.1`、端口 `18082`。支持远端解析的 SOCKS 客户端按其说明启用远端 DNS。若应用不支持代理，不凭空编造菜单或把一个启动参数说成已生效。`HTTP_PROXY` / `HTTPS_PROXY` 只对实际支持它们的程序生效，不是系统级强制规则。

来源：[Mihomo listeners](https://wiki.metacubex.one/config/inbound/listeners/)。

### B. 软件没有代理选项，已有日常 TUN

复用当前 TUN，以使用者实际路径添加进程规则；并把 `find-process-mode` 设为适合本机的模式。下面片段假定 `GROK-ROUTE` 已定义，且 `MY-NODE` 是仅支持 TCP 的出口：

```json
{
  "find-process-mode": "strict",
  "rules": [
    "AND,((PROCESS-PATH,E:\\Apps\\GrokBot\\GrokBot.exe),(NETWORK,UDP)),REJECT",
    "PROCESS-PATH,E:\\Apps\\GrokBot\\GrokBot.exe,GROK-ROUTE",
    "MATCH,PROXY"
  ]
}
```

这是规则顺序示例，**不能用它覆盖已有规则数组**。将相应软件规则合入现有通用地理规则之前，保留网站中转和其他已确认例外。实际节点支持 UDP 且用户需要时再调整第一条；不支持 UDP 的节点可能让请求继续向下匹配，不能让它意外落到国内直连。子进程如果使用独立可执行文件，也按完整路径补充，不把整个磁盘或所有运行时程序纳入。

来源：[进程与规则优先级](https://wiki.metacubex.one/config/rules/)。若没有 TUN 而软件又不支持代理，先按兼容流程决定如何接管，不能只添加进程规则就报告软件已走代理。

### C. 想保留软件原来的中转

先区分两层：API / 内容生成的中转地址是应用或服务端配置，Mihomo 只决定到该地址的传输路线。保留原 URL 和密钥，再决定这个进程或具体域名直连还是代理。不要为了分流把中转域名替换成模型官方域名。

只有一部分功能需要特定路线时，优先按应用提供的单项代理或经核实的具体域名配置；不要无依据接管整个软件。公开仓库不收录使用者的私人中转域名或密钥。

## 3. Grok Bot 实际操作顺序

1. 确认自己的 Grok Bot 路径、实际子进程，以及原来是否设了应用代理、中转或浏览器代理。
2. 选择 A 或 B：有应用代理用专用入口；否则复用已有 TUN 的完整路径规则。需要防止回退直连时，继续使用 [Claude Code 同类保护流程](cc-protection.md)，普通进程规则本身没有此能力。
3. 在私人配置中定义 `GROK-ROUTE` 并引用自己的节点。想固定出口时只放目标节点，不加入 `DIRECT`、自动回退或轮换订阅。要允许故障切换时由使用者明确选择，并写清出口可能变化。
4. 按原客户端方式校验和加载持久配置，关闭再打开该软件，使新请求建立连接；不要结束其他软件。复用同一 TUN 时无需为了这个步骤重启整个网络。
5. 在工作台搜索软件名及实际域名，核对新连接走“代理线路”和预期策略 / 核心；使用应用完成一条实际请求。单独浏览器查 IP 只能证明浏览器的路线，不能证明 Grok Bot。
6. 记录本次新增规则、入口或应用设置。恢复时只撤销这些条目、恢复该软件原值。工作台的“恢复默认分流”仅管理域名，不自动撤销这里的进程规则或监听器。

## 4. 按软件直连与验证边界

某软件需要国内直连时，将对应策略改为 `DIRECT`，先检查进程规则是否会覆盖已有域名例外。不要同时保留互相矛盾的两条同路径规则。对于共享进程、自动更新路径、浏览器扩展、后台服务和不可识别进程，分别使用它们能支持的应用代理或可核验的域名规则，不声称一种进程名规则能覆盖所有情况。

验收要同时记录实际软件操作、当前连接及退出 / 故障后的表现。守卫未安装就只报告“已分流”，不报告“断线不回退”。

普通浏览器也可按网站分流，不必安装指纹浏览器。安装代理负责配置整个服务链路，不让用户逐个补登录、图片或附件域名。下面是服务自有域名的初始合并片段，安装时对照官方当前依赖更新；保留原来的策略组、规则与业务例外。以下按仅支持 TCP 的节点拒绝对应 UDP，避免向下匹配到其他路线：

```json
{
  "proxy-groups": [
    {"name":"CLAUDE-WEB","type":"select","proxies":["MY-NODE"]}
  ],
  "rule-providers": {
    "claude-service": {
      "type":"inline","behavior":"domain",
      "payload":["+.claude.ai","+.claude.com","+.anthropic.com","+.claudeusercontent.com","+.claudemcpcontent.com","+.claudemcpclient.com","+.clau.de"]
    }
  },
  "rules": [
    "AND,((RULE-SET,claude-service),(NETWORK,UDP)),REJECT",
    "RULE-SET,claude-service,CLAUDE-WEB"
  ]
}
```

`MY-NODE` 使用自己的节点名。这不是完整配置，也不能覆盖已有规则数组；把规则放在会截获它的普通浏览器进程规则、通用分流与 MATCH 之前，避免删除原业务例外。安装代理必须先核对已有 API 中转与受保护规则，不把当前业务改成直连官方 API。支持所需 UDP 的节点可按实际情况调整首条规则。

先确保普通浏览器的流量经过这个 TUN 或规则代理。共享的第三方登录、验证码、字体、库与云存储域名不直接整站改为全机固定代理，避免影响其他应用。默认由安装代理使用已有 Chrome / Edge 创建只用于该服务的独立私人配置目录，并把该窗口的 HTTP(S) / WebSocket 网页请求统一送到指定回环代理，覆盖跳转、图片、附件及新增资源域名；已有指纹浏览器可复用其独立环境。该窗口里其他网站也走此入口，不对外宣称是仅一个域名的规则。Claude 网页与 Claude Code 本机程序仍分别核验。

具体部署由执行 skill 的代理完成：

1. 对照 [官方网络依赖](https://code.claude.com/docs/en/network-config#desktop-and-claudeai) 核对自有内容、登录与 CDN 主机，更新上述种子规则；不把静态种子称为永远完整的域名清单。可对照 [MetaCubeX 服务分类](https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/anthropic.yaml) 查漏，不盲目改变全部 Google / Cloudflare 路线。
2. 根据本机已有浏览器生成仓库外的 service-browser 私人设置，参考 `assets/service-browser.example.json`，核对指定代理监听者。使用 `scripts/Open-ServiceBrowser.ps1 -SettingsPath <private-file>` 创建 / 打开独立环境；`-Plan` 仅检查参数，不打开浏览器。脚本拒绝复用原有个人资料目录，不改系统代理、不关其他窗口、不自动创建桌面快捷方式，也不开放远程调试端口。
3. 在该环境检查浏览器实际生效的代理与策略、页面加载及重定向。需要登录或真人验证时由用户完成这一步；安装代理负责之后的路由检查与修复，不让用户自行找域名。再检查图片上传 / 查看、附件下载和所用内容预览；只记录主机和路线，不保存 Cookie、授权码或带签名的完整 URL。未完成登录的测试记录为待验证，不能把 200 根页面或规则语法通过称为整条链路成功。
4. 如请求被交给其他浏览器 / 应用、企业浏览器策略覆盖代理或脚本不能确认参数，代理在授权范围内调整到同一独立入口并复测；不静默改回国内或换节点。用户只要使用配置好的入口。之后依赖改变时仍由 skill 维护配置，不能将技术补项转交给用户。

普通浏览器独立环境的依据：[Chromium 配置目录](https://www.chromium.org/developers/creating-and-using-profiles/)、[Edge 固定代理参数](https://learn.microsoft.com/en-us/deployedge/edge-learnmore-cmdline-options-proxy-settings)。这解决网页请求的路线，不等于操作系统级防直连；需要后者仍执行原有专用保护验收。工作台的域名按钮仍只提供直连 / 恢复默认，不负责创建上述服务专用入口。
