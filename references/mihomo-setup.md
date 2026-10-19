# 使用自己的 VPS 或代理服务配置 Mihomo

Mac 请先读 [Mac 接入流程](macos.md)。以下的节点参数与配置原则共用，Windows 安装、路径、驱动和系统命令不要直接在 Mac 执行。

本指南面向 Windows 10/11。使用者提供自己的节点或服务商代理参数，Mihomo 在本机负责连接与分流，工作台负责查看路线和管理域名例外。所有真实配置、订阅缓存、密钥和日志放在技能源码之外，不上传网络配置。

已有网络先读 [兼容与撤回](network-compatibility.md)；只想改变某个软件的路线见 [软件分流](application-routing.md)；需要 Claude Code 固定出口与防直连见 [专用保护](cc-protection.md)。不把日常 TUN 模板直接复制成第二个专用 TUN。

## 1. 先确定手里有什么

| 资源 | 需要的资料与注意点 |
| --- | --- |
| 已搭建代理的 VPS | 节点协议、服务器地址、端口及该协议的认证 / TLS / 传输参数；仅有 VPS IP 或 SSH 密码还不能接入 |
| SOCKS5 / HTTP / HTTPS 代理 | 主机、端口、用户名密码，或服务商后台设置的客户端 IP 白名单；HTTPS 指代理连接自身使用 TLS |
| 节点订阅 | Mihomo / Clash Meta 兼容订阅或代理集合；不同格式需先在本地转换 |
| 节点分享链接 | 使用支持该格式的本地客户端导出 Mihomo 节点配置，或由代理在本机解析；分享链接不是可以直接粘入 JSON 的节点对象 |

VLESS / Reality、Shadowsocks、VMess、Trojan、Hysteria2、TUIC 等是协议；机房、住宅、ISP、移动是出口 IP 来源，静态、动态、轮换是地址变化方式。来源不限制工作台，但入口必须支持所装 Mihomo 的协议。一个裸 IP、普通网站 URL 或只允许特定应用使用的 VPN 账户，不自动等于兼容代理。

IPv4 和 IPv6 入口均取决于本地网络可达性；只有 IPv4 的网络不能凭设置连到仅有 IPv6 的入口。SOCKS5 的 UDP 需服务端实际支持；HTTP 代理一般只适合 TCP。轮换代理不适合承诺固定出口的应用，住宅地址也不保证目标网站接受。

协议字段以 [官方出站文档](https://wiki.metacubex.one/config/proxies/) 和所装版本为准。自建 VPS 还没有服务端时，先按用户选定协议的官方服务端说明搭建，取得真实节点，再继续本指南；不要将 SSH 登录参数误当节点。

## 2. 从官方发行页安装内核

已有可用 Mihomo 时复用，不另起冲突的内核。首次安装：

1. 打开 [官方安装页](https://wiki.metacubex.one/startup/) 或 [MetaCubeX/mihomo 稳定版发行页](https://github.com/MetaCubeX/mihomo/releases/latest)。选择 Windows 与实际 CPU 架构：常见 Intel / AMD 64 位为 amd64，Windows ARM 设备为 arm64；旧 CPU 应选择满足其指令集的构建，不盲选最高优化级别。
2. 下载对应压缩包并解压；将可执行文件保存为 `E:\Tools\mihomo\mihomo.exe`。路径可自行替换。若发行页提供校验值，核对下载文件的 SHA-256；自己算出哈希不等于完成官方校验。不要从广告下载站获取同名程序。
3. 创建新的私人目录 `E:\PrivateNetwork`。运行以下命令只检查版本、占用，不修改系统网络：

   ```powershell
   & E:\Tools\mihomo\mihomo.exe -v
   Get-NetTCPConnection -State Listen -LocalPort 7890,9090 -ErrorAction SilentlyContinue
   ```

   若端口已占用，先确认属于哪个现有客户端；复用它或为新配置选择空闲端口，不结束未知进程。

## 3. 在本机填写自己的节点

在技能根目录运行，下列复制操作仅适用于新文件；已有文件不会覆盖：

```powershell
New-Item -ItemType Directory -Path E:\PrivateNetwork -Force | Out-Null
if (Test-Path -LiteralPath E:\PrivateNetwork\daily-tun.json) { throw '配置已存在，请先核对已有环境。' }
Copy-Item -LiteralPath .\assets\mihomo.example.json -Destination E:\PrivateNetwork\daily-tun.json
```

在本机编辑新 JSON。模板的 `192.0.2.10` 是文档保留地址，所有 `YOUR_` 都要替换；无法用示例地址联网。`secret` 是自己生成的本机控制 API 随机密钥，与节点密码不同；可用下面表达式生成，在本机填入，不打印或提交：

```powershell
$controllerSecret = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
```

模板默认 SOCKS5。将服务器、端口、用户名、密码改为自己的参数；无认证时删除用户名和密码字段。只有服务端明确支持 UDP 时才设 `udp: true`。

若使用 HTTP / HTTPS，替换 `proxies` 中的节点对象，保留名 `MY-NODE`，以便策略组引用一致：

```json
{
  "name": "MY-NODE",
  "type": "http",
  "server": "proxy.example.com",
  "port": 443,
  "username": "YOUR_PROXY_USERNAME",
  "password": "YOUR_PROXY_PASSWORD",
  "tls": true
}
```

普通 HTTP 入口设 `tls: false` 并填实际端口；不要通过关闭证书校验解决错误的服务器名称或证书。

VLESS / Reality 的节点结构示例：

```json
{
  "name": "MY-NODE",
  "type": "vless",
  "server": "node.example.com",
  "port": 443,
  "uuid": "YOUR_NODE_UUID",
  "network": "tcp",
  "tls": true,
  "servername": "YOUR_SERVER_NAME",
  "client-fingerprint": "chrome",
  "flow": "xtls-rprx-vision",
  "reality-opts": {
    "public-key": "YOUR_REALITY_PUBLIC_KEY",
    "short-id": "YOUR_REALITY_SHORT_ID"
  },
  "udp": true
}
```

UUID、公钥、short-id、SNI、flow、传输类型必须与服务端一致；这个片段不能替代所有 VLESS 节点。其他协议使用官方对应的节点结构。不要要求使用者把密码、完整订阅或节点链接贴到公开 issue。

### 使用自己的订阅

服务商若提供完整可运行的 Mihomo 配置，优先将其保存在私人目录，并按 [接入说明](integration.md) 保留持久覆写。不能用节点列表替代整个运行配置。

若提供 Mihomo 代理集合，在私人 JSON 增加如下顶层字段，并将原来的 `proxies` 改为空数组、将策略组替换为下面这组：

```json
{
  "proxy-providers": {
    "MY-SUB": {
      "type": "http",
      "url": "https://subscription.example.com/YOUR_PRIVATE_TOKEN",
      "path": "./providers/my-sub.yaml",
      "interval": 86400
    }
  },
  "proxies": [],
  "proxy-groups": [
    { "name": "PROXY", "type": "select", "use": ["MY-SUB"] }
  ]
}
```

以上是要合入原 JSON 的字段，不是完整配置。首次订阅下载需要已有可达路径；不能让下载依赖尚未取得的同一个节点。如果本地网络无法访问订阅，使用现有可用连接完成初次下载，或从服务商取得本地文件并使用 `type: file`。提供器缓存保留在 `-d` 数据目录内。普通网页、HTML 错误页、其他客户端的专属订阅格式不能直接用；转换只在本机完成，不提交给第三方转换网站。见 [官方代理集合](https://wiki.metacubex.one/config/proxy-providers/)。

## 4. 先验证显式代理

模板初始不开 TUN、不接管系统代理；只将 `.cn` 和本地域名直连，其余走 `PROXY`。这用于确认节点，并非完整国内分流。

```powershell
& E:\Tools\mihomo\mihomo.exe -t -d E:\PrivateNetwork -f E:\PrivateNetwork\daily-tun.json
if ($LASTEXITCODE -ne 0) { throw '配置检查失败，先处理本机报错。' }
& E:\Tools\mihomo\mihomo.exe -d E:\PrivateNetwork -f E:\PrivateNetwork\daily-tun.json
```

第二条是前台运行，保持该终端开启；本步骤还没有为所有软件接通代理。另开普通 PowerShell，用 Windows 自带 `curl.exe` 显式测试：

```powershell
curl.exe --proxy http://127.0.0.1:7890 --connect-timeout 10 --max-time 25 https://api.ipify.org
```

这会访问外部 IP 查询服务，只报告你当次的出口。与自己的服务商预期比较；轮换代理每次可能不同。`-t` 通过不等于节点可连，端口监听不等于目标网页可达。如果失败，分别看解析、TCP、TLS、认证和 HTTP，避免反复重启全网。日志在本机检查并脱敏。

## 5. 补齐国内分流，再按需启用 TUN

只管理显式代理的应用可跳过 TUN。需要覆盖日常软件时，在节点已验证后为这个新实例配置 TUN；已有正常 TUN / VPN 时先核对，避免双重接管。改配置前只停止自己刚启动的前台实例（在该终端按 Ctrl+C），并在私人目录保存一份修改前配置。

国内分流可采用 MetaCubeX 维护的规则集。将以下字段合入私人 JSON，`rules` 替换原模板规则；已有业务例外则合并并保留它们在通用规则之前的顺序：

```json
{
  "rule-providers": {
    "private-ip": {
      "type": "http", "behavior": "ipcidr", "format": "mrs",
      "path": "./rules/private-ip.mrs",
      "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/private.mrs",
      "interval": 86400, "proxy": "PROXY"
    },
    "cn-domain": {
      "type": "http", "behavior": "domain", "format": "mrs",
      "path": "./rules/cn-domain.mrs",
      "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs",
      "interval": 86400, "proxy": "PROXY"
    },
    "cn-ip": {
      "type": "http", "behavior": "ipcidr", "format": "mrs",
      "path": "./rules/cn-ip.mrs",
      "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs",
      "interval": 86400, "proxy": "PROXY"
    }
  },
  "rules": [
    "DOMAIN,localhost,DIRECT",
    "DOMAIN-SUFFIX,local,DIRECT",
    "DOMAIN-SUFFIX,lan,DIRECT",
    "RULE-SET,private-ip,DIRECT,no-resolve",
    "RULE-SET,cn-domain,DIRECT",
    "RULE-SET,cn-ip,DIRECT",
    "MATCH,PROXY"
  ]
}
```

规则源首次下载依赖已验证的代理。先保持 `tun.enable: false`，按步骤 4 校验并启动，确认规则实际加载后，再停止自己的这个前台实例，继续下面的 TUN 设置。下载失败先解决下载或使用可信的本地规则文件，不能把空规则当成已完成国内分流。规则集是分类数据，具体网站仍需看实际命中，不能保证每个域名都准确。来源：[MetaCubeX 规则数据](https://github.com/MetaCubeX/meta-rules-dat/tree/meta)、[规则集合格式](https://wiki.metacubex.one/config/rule-providers/)。

开启 TUN 时，可将以下 `tun` 与 `dns` 合入私人配置；这是新环境起点，不应覆盖已有专用保护、网站规则或已验证 DNS：

```json
{
  "tun": {
    "enable": true,
    "stack": "gvisor",
    "auto-route": true,
    "auto-detect-interface": true,
    "dns-hijack": ["any:53", "tcp://any:53"]
  },
  "dns": {
    "enable": true,
    "listen": "127.0.0.1:1053",
    "ipv6": true,
    "enhanced-mode": "redir-host",
    "nameserver": ["https://cloudflare-dns.com/dns-query#PROXY"],
    "proxy-server-nameserver": ["https://dns.alidns.com/dns-query"],
    "direct-nameserver": ["https://dns.alidns.com/dns-query"]
  }
}
```

DNS 端口也要检查空闲；示例 DNS 需要在实际网络能访问，代理节点的域名不能依赖尚未建立的代理才能解析。依据实际失败调整解析器，不全局关闭 IPv6，也不同时更改网卡和系统 DNS。`allow-lan: false` 与控制 API 回环地址继续保留，防止控制接口暴露给局域网。参见 [DNS](https://wiki.metacubex.one/config/dns/) 与 [TUN](https://wiki.metacubex.one/config/inbound/tun/)。

重新执行 `-t`，检查通过后在管理员 PowerShell 用相同 `-d` / `-f` 前台启动这个实例。它会建立虚拟网卡与路由；若提示组件缺失，按该版本官方 Windows 安装说明补齐，不能关闭防火墙解决。

启用后在普通应用验证国内网页、外网页面和实际图片上传；再用不带 `--proxy` 的 IP 查询核对透明路径。若失败，在启动该实例的终端 Ctrl+C 退出，使用私人备份恢复这个实例的配置，核对其虚拟路由已释放；保留原客户端与原恢复入口。不要结束其他核心或覆盖网站配置。若原来人为启用过系统代理，需单独恢复原值；本指南的命令没有设置系统代理。

## 6. 安装并使用工作台

将 `assets/settings.example.json` 复制到私人目录的 `settings.json`，与本指南路径一致时可直接填写：

- `ConfigPath`: `E:\PrivateNetwork\daily-tun.json`
- `ExecutablePath`: `E:\Tools\mihomo\mihomo.exe`
- `DataDirectory`: `E:\PrivateNetwork`
- 只有日常可编辑配置加入 `Profiles`。专用配置与网站环境文件按 [接入说明](integration.md) 加入保护。

执行 README 的检查、安装与普通用户启动步骤。若新 TUN 内核以管理员运行，后端修改需管理员许可，窗口查询受目标机器权限限制时应核对，不降低内核或配置保护。窗口可搜索实际连接、将指定网址设为国内直连、恢复默认分流。节点订阅更新和启动仍由自己选择的客户端或内核启动方式管理。

开机自动启动是单独的配置步骤：需要时，使用所选客户端的开机启动功能，或在 Windows 任务计划程序中为自己的实例创建登录触发任务。程序填写 `E:\Tools\mihomo\mihomo.exe`，参数填写 `-d E:\PrivateNetwork -f E:\PrivateNetwork\daily-tun.json`，起始目录填写 `E:\PrivateNetwork`。任务身份必须能读到私人配置；TUN 选择有管理员权限的身份与最高权限。应先关闭刚才前台启动的同一个实例，避免重复启动；关闭任务时只处理它自己的进程。先验证一次重启与一次待机恢复，再报告自动连接已验证。不要将他人机器的守卫、计划任务、电源设置直接搬过来；已有专用应用仍遵守原防直连和手动解锁策略。

## 7. 发布时保留示例，移除运行资料

技能里只保留通用模板和这些步骤。真实 IP、UUID、密码、SNI、公钥 / short-id、订阅 URL、API 密钥、配置缓存及备份均留在私人目录，不加入 Git、不上传排错附件。公开报告使用合成数据。工作台不因使用某种 IP 就提供账户地区或风控通过保证。
