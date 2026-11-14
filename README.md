# V2rayM

把 Android 上 [v2rayNG](https://github.com/2dust/v2rayNG) 的使用习惯搬到 HarmonyOS 上的原生客户端：
**ArkTS 界面 + mihomo（Go）内核 + NAPI 桥接 + 系统 VPN 扩展**，不是套壳 WebView，也不依赖任何第三方 VPN App。

> **非官方项目。** 本项目与 v2rayNG、mihomo 项目及其作者没有隶属关系，是个人在鸿蒙平台上的一次移植实践，
> 借用的是它们的设计思路、内核与协议实现。上游致谢见 [CREDITS.md](CREDITS.md)。

[![build-unsigned-hap](https://github.com/ansun1714/v2rayng-hos/actions/workflows/build-hap.yml/badge.svg)](https://github.com/ansun1714/v2rayng-hos/actions/workflows/build-hap.yml)

## 界面

| 分流规则面板 | 规则分页（社区大规则集） | 左侧抽屉 |
| --- | --- | --- |
| ![规则面板](docs/images/rules-panel.jpeg) | ![分页](docs/images/rules-paging.jpeg) | ![抽屉](docs/images/drawer.jpeg) |

## 功能

**节点与订阅**

- 订阅链接按「一次导入」自动分组：手动节点一组，每个订阅链接各成一组，大组默认折叠，可单独「更新 / 测速」
- 支持订阅链接导入、单条链接批量粘贴（`vmess://` `vless://` `ss://` `trojan://`，一行一个）、剪贴板导入
- 节点可编辑 / 删除，支持手动添加

**测速与选节点**

- 并发 16 条测速，顶部实时显示「已测 / 待测」进度
- 测速是**本机直连节点**做 TCP 握手 + 首字节探测（不先拉起代理，也不走 TUN），所以拖动代理开关不影响结果
- 测完按延迟从低到高排序，超时/失败的沉底
- **点哪个节点，蓝色对勾立刻落在那一行**：只重绘这一行，不重建整张列表
- 已连接状态下点选节点即切过去：手停 0.8 秒后自动断开重连，状态栏依次显示「准备切换到 …」「正在切换节点…」，
  全程约 5 秒；连点几下只切最后选中的那个
- 列表走 `LazyForEach` 懒加载，392 条节点时点选只刷新两行，滚动不掉帧
- **不会替你挑节点**：切哪个由你自己点

**操作与布局**

- 订阅、导入、设置收进左侧抽屉（约 72% 宽），主页面只留节点列表，不乱
- 底部一整行 50vp 的代理开关（未连接蓝底「开启代理」/ 已连接红底「停止代理」），单手可点

**分流规则（设置 → 分流规则）**

- 手动增删改、单条启停、`DIRECT / PROXY / REJECT` 目标点一下就轮换
- `rules.json` 持久化，连接状态下改完自动重连生效
- 文件导入 / 导出（JSON 或 Clash 规则片段）
- 网址订阅更新：一份地址整份覆盖，支持两种格式
  - 本项目的规则 JSON
  - **社区 rule-provider 的 payload 纯清单**（Loyalsoldier/clash-rules、ACL4SSR 那种一行一个域名的格式），
    域名自动判 `DOMAIN-SUFFIX`、CIDR 自动判 `IP-CIDR`/`IP-CIDR6`，方向按地址或文件名里是否含
    `direct`/`private`/`china`/`reject`/`ban` 推断
- 大清单每屏只渲染 50 条，「再显示 50 条（共 N 条）」逐页展开
- 地址栏默认内置规则集（`builtin://default`，点「网址更新」直接应用内置 6 条，永不失效）；
  换成的自定义地址会记在 `rules-src.txt`，下次打开自动回填；删空后点「保存」就回落到默认

**默认 6 条规则**（对齐 v2rayN 的路由语义）

| 规则 | 目标 | 默认状态 |
| --- | --- | --- |
| `GEOSITE,private` | DIRECT | 开 |
| `GEOSITE,cn` | DIRECT | 开 |
| `GEOIP,CN` | DIRECT | 开 |
| `AND,((NETWORK,UDP),(DST-PORT,443))` | REJECT | 关 |
| `GEOSITE,geolocation-!cn` | PROXY | 开 |
| `MATCH` | PROXY | 开 |

## 架构

```
┌──────────────────────────────────────────────┐
│ ArkTS UI（pages/Index.ets，单文件页面）        │
│  ├ 节点列表 / 测速 / 抽屉 / 分流规则面板        │
│  └ core/ConfigBuilder.ets  生成 mihomo 配置    │
├──────────────────────────────────────────────┤
│ EntryAbility  ←→  VpnExtAbility（VPN 扩展）    │
│  系统 TUN fd  ──►  内核接管                    │
├──────────────────────────────────────────────┤
│ NAPI 桥（cpp/napi_init.cpp → libngnapi.so）    │
│  dlopen libngcore.so，双向回调（protect/socket）│
├──────────────────────────────────────────────┤
│ Go 内核（core-native/main.go + mihomo v1.19.33）│
│  出站 socket 交回 ArkTS 做 protect，绕开回环    │
└──────────────────────────────────────────────┘
```

几个关键决定：

- **内核不自己 open socket 就完事**：鸿蒙的 `VpnConnection.protect()` 只接受 `@ohos.net.socket` 建的 fd，
  Go 自己开的 socket 会被 netmanager 拒绝，所以内核出站前回调到 ArkTS 侧做 protect（NAPI 异步 + 文件桥，避免死锁）
- **同步 NAPI 里不能回调 ArkTS**（会死锁），protect 链路因此做成异步
- 内核日志通过 NAPI 挂到 `hilog`，标签 `NG-CORE`，`hdc hilog | grep NG-CORE` 就能看

## 目录结构

```
app/                            鸿蒙工程（hvigor / ArkTS）
  entry/src/main/ets/
    pages/Index.ets             单文件主界面（节点、测速、抽屉、规则面板）
    core/ConfigBuilder.ets      mihomo 配置生成 + 规则解析（含 payload 清单兼容）
    core/ProxyLink.ets          节点链接解析
    core/FileStore.ets          数据落盘
    core/Model.ets              数据结构
    entryability/EntryAbility.ets
    vpnextability/VpnExtAbility.ets   VPN 扩展，TUN fd 与 protect 处理
  entry/src/main/cpp/           NAPI 桥（napi_init.cpp）
  entry/libs/arm64-v8a/         预编译内核库与 NAPI 库
  entry/src/main/resources/rawfile/   内置节点示例、geo 数据
core-native/                     Go 内核桥接（mihomo 依赖）
tools/                          命令行构建脚本
```

## 自动化构建（GitHub Actions）

不想在本机配鸿蒙环境，直接让 GitHub 编：`.github/workflows/build-hap.yml` 在推送到 `main`、
提 PR、或手动 `workflow_dispatch` 时跑一遍，产出**未签名**的 HAP。

流程：装 Node 22 + JDK 17 → 拉 OpenHarmony SDK（`5.0.3-Release`，API 15，包内 5 个组件 zip
逐个解压，整份缓存）→ 从本仓库 Release（tag `hvigor-5.19.8`）下载 hvigor 的两个自包含 tarball
解压到 `node_modules` → 用 `ci/ohos-sdk-patch/` 覆盖 SDK（补齐 `vpn` 扩展类型）→
`hvigor --mode module -p module=entry@default -p product=default assembleHap` →
把 `entry-default-unsigned.hap` 作为 artifact 上传。

> 为什么需要 SDK 补丁：OpenHarmony 5.0.3 公共 SDK 的 `toolchains/modulecheck/module.json`
> schema 与 `@kit.NetworkKit` 导出里都没有 `vpn` 扩展类型，直接构建会在 PreBuild 报
> `00303038 Configuration Error`（`module.extensionAbilities[0].type` 不在枚举内）。
> `ci/ohos-sdk-patch/` 下是同一版本 SDK 中对应的 Apache-2.0 文件（module schema、
> `@ohos.net.vpnExtension` 等 d.ts、`@kit.NetworkKit` 导出），构建前覆盖进 SDK 即可。


> 为什么不用 npm：`@ohos/hvigor` 与 `@ohos/hvigor-ohos-plugin` 只发布在 `repo.harmonyos.com`，
> 而 `npm ci` 在干净的 runner 上会因 lock 文件与 bundle 依赖不同步（缺 `fsevents`、
> `glob-parent`、`engine.io-parser`）而拒绝安装；把 registry 整个指向华为源又会因为
> `electron-to-chromium` 等包不在该源而 404。这两个 tarball 自带全部 bundled 依赖
> （14.4MB + 27.7MB），解压即可用，已在本地用同样方式验证能正常 `assembleHap`。

- **下载位置**：两种都行
  - Releases 页（推荐）：每次 push 构建成功后由 Actions 自动发布到
    `https://github.com/ansun1714/v2rayng-hos/releases/tag/hap-latest`，
    资产固定叫 `entry-default-unsigned.hap`，正文里有大小、SHA256 与对应 run
  - Actions 对应 run 的页面 → Artifacts → `v2raym-ohos-unsigned-hap-api15`（保留 30 天，同一份产物打成 zip）
  - Release 里的 `hvigor-5.19.8` 是 **prerelease**，只放 CI 需要的 hvigor tarball，不是应用成品

- **为什么一定没签名**：`app/build-profile.json5` 里 `signingConfigs` 是空数组，hvigor 只会产出未签名包
- **耗时**：首次约 10 分钟（要下 4.3GB SDK），之后命中缓存约 2 分钟
- **签名**：下下来后按下面「签名与装机」一节自己签；不签名的包无法直接安装
- **产物大小**：约 78MB（含随仓库分发的 `geoip.dat` / `geosite.dat` 分流数据）

## 构建

**前置**

- OpenHarmony SDK（`compileSdkVersion 15`，`compatibleSdkVersion 12`），DevEco Studio 或纯命令行均可
- Node.js 18+ 与 hvigor（`app/package.json` 里已锁定依赖）
- JDK 17（hvigor 需要）
- 只有需要重编内核时才需要 Go 1.24+ 与 OpenHarmony Go 交叉工具链

**1. 准备环境文件**

```powershell
cd app
Copy-Item local.properties.example local.properties   # 改成你本机 SDK 路径
npm install
```

**2. 准备内置节点（可选）**

`entry/src/main/resources/rawfile/nodes.txt` 不入库（里面是私人节点）。要用内置节点就：

```powershell
Copy-Item entry/src/main/resources/rawfile/nodes.txt.example entry/src/main/resources/rawfile/nodes.txt
# 然后把里面的示例链接换成你自己的，或者直接不建这个文件
```

**3. geo 数据（仓库已随附，通常不用管）**

`geoip.dat` / `geosite.dat`（约 28MB，来自 [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)）
已随仓库分发在 `app/entry/src/main/resources/rawfile/`。要更新到最新版本，自行替换这两个文件即可；
缺失时 `GEOSITE`/`GEOIP` 规则不生效，内核会尝试联网下载。

**4. 编译内核库（仓库已附带预编译产物，可跳过）**

`entry/libs/arm64-v8a/libngcore.so` 是 mihomo 交叉编译出来的 `c-shared` 库，运行时 dlopen 加载。
仓库里已经带了一份；要自己重编（也是核对二进制来源的推荐做法），用 OpenHarmony Go 工具链配合 NDK clang：

```powershell
pwsh -NoProfile -File tools\build-core.ps1 `
  -Sdk "你的 SDK 根目录" -Api "15" -GoRoot "你的 ohos-go 工具链根目录"
```

脚本内部做的事：`GOOS=openharmony`、`GOARCH=arm64`、`CGO_ENABLED=1`、`CC` 指向 NDK 的 clang，
在 `core-native` 目录执行 `go build -buildmode=c-shared -tags with_gvisor -trimpath -ldflags="-s -w"`，
完事打印产物的 `size` 与 `sha256`，并检查二进制里有没有残留本机路径（`-trimpath` 失效会告警）。
用的是 [OpenHarmony 的 Go fork](https://gitee.com/openharmony/third_party_go)，官方 Go 包不支持 `GOOS=openharmony`。

NAPI 库（`libngnapi.so`）同样可以自己重编：

```powershell
pwsh -NoProfile -File tools\build-napi.ps1 -Sdk "你的 SDK 根目录" -Api "15"
```

**二进制与源码的对应**

两个 `.so` 是仓库里的预编译产物，CI 不重建（重建内核要额外装 Go 与 NDK）。为了能核对"手上的二进制是不是这些源码编出来的"：

- 每个 Release（`hap-latest`）都附 `SHA256SUMS.txt`，列出 HAP、`libngcore.so`、`libngnapi.so`、`geoip.dat`、`geosite.dat` 的 sha256
- 按上面两条命令重编后，把打印出来的 sha256 与清单里对应行对照
- 仓库里这两份产物已用上述脚本重编验证过，**逐字节一致**：
  `libngcore.so` = 63,941,544 字节 `75c77b70b2fafb4c1460440a4e44670c2a6a23bbc2167305e4a5f65bdd963d4a`，
  `libngnapi.so` = 40,072 字节 `4c825269605ab31701ab960de88487423e7288171453c14e3ee4252331ead648`
- OpenHarmony Go fork 与 NDK 的版本会影响产物字节，**逐字节相同的哈希只在工具链版本相同时也成立**；
  工具链不同时应比对依赖是否一致、产物是否残留本机路径，而不是强求同一个哈希
- `libngnapi.so` 只有四个依赖（`libace_napi.z.so` / `libhilog_ndk.z.so` / `libc++_shared.so` / `libc.so`），
  `libngcore.so` 只依赖 `libc.so`；多出别的依赖说明链接被改过

**5. 构建 HAP**

```powershell
$env:OHOS_SDK  = "你的 SDK 根目录"
$env:JAVA_HOME = "你的 JDK 17 目录"
pwsh .\tools\build-hap.ps1
```

产物在 `app/entry/build/default/outputs/default/`，未签名。

**6. 签名与装机**

用 DevEco Studio 的自动签名，或自己准备 `p12 / cer / p7b` 后调用 `hap-sign-tool`：

```powershell
java -jar hap-sign-tool.jar sign-app -keyAlias "..." -signAlg "SHA256withECDSA" `
  -mode "localSign" -appCertFile "xxx.cer" -profileFile "xxx.p7b" `
  -inFile "entry-default-unsigned.hap" -keystoreFile "xxx.p12" -outFile "entry-default-signed.hap" `
  -keyPwd "..." -keystorePwd "..." -signCode "1"
hdc install -r entry-default-signed.hap
```

## 更新记录

- **本轮**：订阅组头图标化单行（改名笔 / 刷新 / 测速闪电三个圆钮）、订阅组卡片化与状态行双阴影；
  Release 附 `SHA256SUMS.txt`，两个预编译 `.so` 已用 `tools/build-core.ps1` / `build-napi.ps1` 实测可逐字节复现；
  抽屉里加「清除运行日志」；内核日志只放行 WARNING/ERROR 并丢弃带目的地址的拨号行
- 前一轮：节点列表改为 `LazyForEach` 懒加载（修掉「测速完不排序」「点一下卡十几秒」）；点选节点只重绘两行、
  蓝色对勾即时落在点击行；已连接时点选节点自动切换（0.8 秒防抖）；连接/断开与切换全程有状态文案，按钮在过程中置灰
- 早期：VPN 状态以系统实际存在为准（修「图标消失但界面显示已连接」）、断开/重连改成轮询等通道消失、
  左滑露出编辑/删除、分流规则面板与社区 payload 兼容、全站字号放大

## 已知限制

1. 国内 UDP 直连偶发 `netlinkrib: permission denied`（`[UDP] ... DIRECT`），TCP 正常，走 QUIC 的应用会自动回落 TCP
2. 订阅导入不解析 `sub-userinfo`（流量 / 到期信息）
3. 同一订阅 URL 不同写法（结尾斜杠、大小写、query 变化）会被当成两个分组
4. 文件导入的「选文件 → 读取 → 覆盖」链路在自动化环境里没跑通端到端（系统文件选择器不接收注入），需人工点一次确认
5. 不自动挑选「最优节点」（有意为之，节点由你自己选）；已连接时点选节点才会自动切过去，只是想浏览就先停掉代理
6. 只有一个 `arm64-v8a` 的预编译内核库，其它 ABI 需自行编译
7. **IPv6 不接管（真机验证过，非配置疏漏）**：鸿蒙会把 tun 的 v6 地址挂到 `vpn-tun` 上，
   但 `VpnConfig.routes` 里的 v6 默认路由一律不会进路由表——`::/0`、拆成 `::/1` + `8000::/1`、
   接口名写 `tun0` 或真实名 `vpn-tun`，四种组合在 `/proc/net/ipv6_route` 里都只看到
   `fd00:…/64`、`fe80::/64`、`ff00::/8` 这三类本地路由，没有默认路由；v6 数据报也不会投递到 tun fd
   （华为开发者论坛有同类反馈，未见解法）。拿真实 v6 出口对探，代理开着时出口仍是家里宽带的真实
   v6 地址，等于 v6 直连。所以这里保持 `isIPv6Accepted: false` + 内核 `ipv6: false`：
   内核不给应用下发 AAAA，应用就不会主动产生绕过隧道的 v6 流量。
   若所在网络有 IPv6 且需要彻底防泄漏，请在路由器或手机 Wi‑Fi 设置里关闭 IPv6
8. 没有 kill switch：鸿蒙 `VpnConfig.isBlocking` 指的是 tun fd 的阻塞读写模式，不是 Android 那种「断开时拦流量」；
   API 里也没有 always-on / lockdown 字段。扩展异常退出时，系统会回到直连
9. 节点凭据（密码、原始分享链接、订阅 URL）以明文 JSON 存在应用沙盒的 `profiles.json`；
   沙盒其他应用读不到，但设备被 root、被备份或被调试读取时会暴露。日志（`vpn.log`）保留最近 240 行，
   只记连接状态与出口探测结果，不记订阅 URL 与节点凭据，界面里可一键清除

## 免责声明

本项目仅供学习与研究 HarmonyOS 上的网络代理客户端实现，不提供任何节点、订阅或服务。
使用者需自行确保其使用行为符合所在地法律法规与所在网络的服务条款。作者不对使用后果承担责任。

## 致谢

本项目站在这些开源项目肩膀上，详细来源与许可见 [CREDITS.md](CREDITS.md)：

- **[2dust/v2rayNG](https://github.com/2dust/v2rayNG)** — 界面结构与交互参考（分组、测速、路由设置）
- **[2dust/v2rayN](https://github.com/2dust/v2rayN)** — 分流规则语义与「路由设置」面板的参照
- **[MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)** — 网络内核，本项目以 Go module `v1.19.33` 依赖并交叉编译为 `libngcore.so`
- **[Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)** — `geoip.dat` / `geosite.dat` 数据来源（随仓库分发）
- **[Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules)** — rule-provider payload 清单格式的兼容目标
- **[ACL4SSR/ACL4SSR](https://github.com/ACL4SSR/ACL4SSR)** — 社区规则集格式与命名习惯的参照
- **[v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)** — geosite 数据的上游
- **OpenHarmony SDK / hvigor** — 构建与运行环境（不随仓库分发）

## 许可

[GNU General Public License v3.0](LICENSE)（与 mihomo、v2rayNG 上游一致）。分发衍生作品时请保留同样的许可与致谢。
