# 致谢与第三方许可声明（Credits & Third-Party Notices）

本项目的界面灵感、内核能力、规则语义与数据格式都来自下面这些开源项目。
这里如实说明「用了什么、怎么用的、是否随本仓库分发、各自的许可」，以便遵守各上游的许可义务。

本项目整体以 **GNU General Public License v3.0** 发布（见 [LICENSE](LICENSE)）。

---

## 一、直接依赖（代码随本仓库分发 / 编译进产物）

### 1. MetaCubeX/mihomo

- 仓库：https://github.com/MetaCubeX/mihomo
- 用途：网络内核。本项目通过 Go module 依赖 `github.com/metacubex/mihomo v1.19.33`，
  由 `core-native/` 里的桥接代码编译成 `libngcore.so`（`c-shared`），随 HAP 一起运行。
- 分发方式：`app/entry/libs/arm64-v8a/libngcore.so` 是本项目编译出的二进制，**已随仓库分发**。
- 许可：**GPL-3.0**
- GPL 合规说明：mihomo 的完整对应源码见上游仓库（版本 `v1.19.33`），本项目侧的桥接代码见
  `core-native/main.go`、`core-native/go.mod`、`core-native/go.sum`。任何人可据此重新编译出同样的内核库。
- 其间接依赖（`github.com/metacubex/sing`、`sing-tun`、`gvisor`、`quic-go`、`utls` 等）
  同样通过 Go module 引入，版本全部记录在 `core-native/go.mod` / `go.sum` 中，各自许可见其仓库。

### 2. OpenHarmony / HarmonyOS SDK、hvigor

- 用途：编译与运行环境（ArkTS 编译器、NDK、hvigor 构建工具、系统 NAPI 头文件）。
- 分发方式：**不随本仓库分发**，需自行安装 DevEco Studio 或 OpenHarmony SDK。

---

## 二、设计参考（未复制代码，仅参考交互与语义）

### 3. 2dust/v2rayNG

- 仓库：https://github.com/2dust/v2rayNG
- 用途：本项目是「把 v2rayNG 的体验搬到鸿蒙」的一次移植实践。界面信息层级
  （按订阅分组、单组更新/测速、节点行内显示延迟、路由设置面板）与操作习惯参考了它。
- 分发方式：**未复制其源码**；仅在文档与代码注释中说明设计来源。
- 许可：**GPL-3.0**

### 4. 2dust/v2rayN

- 仓库：https://github.com/2dust/v2rayN
- 用途：分流规则的语义与默认规则集（`GEOSITE,private` / `GEOSITE,cn` / `GEOIP,CN` /
  阻断 UDP 443 / `geolocation-!cn` / `MATCH`）参照它的「路由设置」。
- 分发方式：**未复制其源码**。
- 许可：**GPL-3.0**

### 5. Loyalsoldier/clash-rules

- 仓库：https://github.com/Loyalsoldier/clash-rules
- 用途：社区 rule-provider 的 payload 纯清单格式（一行一个域名/IP、不带 target 列）是本项目
  「网址订阅更新」要兼容的目标格式之一。
- 分发方式：**未随仓库分发**其规则文件。
- 许可：**GPL-3.0**

### 6. ACL4SSR/ACL4SSR

- 仓库：https://github.com/ACL4SSR/ACL4SSR
- 用途：社区规则集的写法与命名习惯参照（`DIRECT` / `PROXY` / `REJECT` 三段式、按文件名区分用途）。
- 分发方式：**未复制**其规则文件。
- 许可：上游仓库未见明确的 LICENSE 文件，本项目仅作格式参照，未复制其内容。

---

## 三、数据（不随仓库分发，需自行下载）

### 7. Loyalsoldier/v2ray-rules-dat

- 仓库：https://github.com/Loyalsoldier/v2ray-rules-dat
- 用途：`geoip.dat` / `geosite.dat` 数据来源，供内核做 `GEOIP` / `GEOSITE` 匹配。
- 分发方式：**未随仓库分发**（约 28MB 二进制）。README 里给出了自行下载放置的位置。
- 许可：**GPL-3.0**

### 8. v2fly/domain-list-community

- 仓库：https://github.com/v2fly/domain-list-community
- 用途：`geosite.dat` 中域名分类数据的上游来源。
- 分发方式：**未随仓库分发**。
- 许可：**MIT**

---

## 四、工具链与其它

- **Go**（https://go.dev）— 内核编译语言，BSD-3-Clause
- **Node.js / hvigor** — 鸿蒙工程构建，各自许可见上游
- **Android NDK 风格 clang（随 OHOS SDK 提供）** — 交叉编译 NAPI 与内核库
- **hap-sign-tool**（HarmonyOS SDK 自带）— 应用签名，仅本地使用，未随仓库分发

---

## 五、声明

1. 本项目**非官方项目**，与 v2rayNG、v2rayN、mihomo、Loyalsoldier、ACL4SSR 等上游项目及其作者
   没有隶属、赞助或背书关系。
2. 本项目**不提供任何节点、订阅、服务器或网络服务**，仓库中不含任何可用的节点凭据
   （`nodes.txt` 已加入 `.gitignore`，仓库只保留 `nodes.txt.example` 示例）。
3. 若你是上述任一项目的作者，认为本项目的致谢方式或使用方式不妥，请开 issue 联系，会尽快调整。

---

*本文件随项目更新；发现遗漏或错误请提 issue 指正。*
