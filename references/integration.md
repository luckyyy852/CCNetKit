# 接入说明

首次使用、只有自有 VPS 节点或代理参数时，先按 [Mihomo 安装与配置](mihomo-setup.md) 建立可用环境，再填写这里的工作台设置。

已有 VPN / 代理先按 [兼容流程](network-compatibility.md) 明确接管归属；软件专用分流与 Claude Code 保护分别见 [软件分流](application-routing.md)、[Claude Code 保护](cc-protection.md)。专用核心不加入可编辑 Profiles。

真实 `settings.json` 放在仓库外。`Profiles` 中每份配置的字段：

| 字段 | 用途 |
| --- | --- |
| Name | 本机显示名，不需账号信息 |
| ConfigPath | 持久的 Mihomo JSON 配置绝对路径 |
| ExecutablePath | 该配置对应内核绝对路径，操作前核验身份 |
| DataDirectory | 内核数据目录，默认配置所在目录 |
| ManageRules | 是否授权修改这份日常配置 |
| Reload | 查询与热加载开关；预运行配置用 false |
| ProtectedRules | 必须保留的完整规则字符串 |

`ProtectedFiles` 是专用配置、网站环境文件等不应修改的文件绝对路径数组，不写文件内容。专用核心不得放入可编辑 Profiles。

可选 `Protection` 只读接入已有守卫：

```json
{"GuardStatePath":"E:\\PrivateNetwork\\guard-state.json","LockPath":"E:\\PrivateNetwork\\locked.json"}
```

守卫状态需含 pid、startTimeUtc、executable、armed、latched。工具只读，不负责安装或恢复守卫；未接入不表示已经保护。

## 客户端配置

本后端直接支持 Mihomo JSON 和兼容控制 API。许多 Clash 客户端会重写临时 YAML，直接编辑可能在更新后丢失。先使用客户端持久覆写机制；或由用户明确选择独立的持久配置和启动方式。

YAML 转 JSON 必须用解析器，保留节点、DNS、TUN、规则提供器和相对数据目录，并使用内核 `-t` 验证。不要只改扩展名。

热加载调用 PUT /configs?force=false，仍会更新内核配置。仅在配置结构与实际检查均支持时报告未重建 TUN，不能一概称为零副作用。其他内核未经验证应停止说明。

## 规则归属

初始 routes.json 为空，不认领已有例外。只移除自身记录里的完整 DOMAIN-SUFFIX 直连条目；已有同名直连不会被接管。

预设内容和相对顺序保留，自定义规则插入首个 GEOSITE / GEOIP / RULE-SET / MATCH 前。更早的显式域名、进程或 IP 规则可能优先，接入者需先核对，不能保证覆盖任意已有规则。

## 可选月度用量

KiwiVM 私人设置示例（示例地址不是实际节点）：

```json
{"Provider":"kiwivm","VpsId":"YOUR_OWN_VPS_ID","ExpectedIPv4":"192.0.2.10"}
```

本机窗口接收 API Key，按当前 Windows 用户 DPAPI 加密。不要在聊天中索取密钥，不公开其加密文件。查询仅调用 getServiceInfo；月度数据以服务商口径为准，本机累计不能代替它。
