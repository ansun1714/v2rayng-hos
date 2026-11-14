/**
 * 节点模型：对应 v2rayNG 的"配置/节点"概念，字段是各协议的交集。
 */
export class ProxySpec {
  name: string = 'node';
  type: string = 'vless'; // vmess | vless | ss | trojan
  server: string = '';
  port: number = 443;
  uuid: string = '';
  username: string = '';  // socks5/http 出站的用户名
  password: string = '';
  cipher: string = '';   // ss 的加密方式 / vmess 的 scy
  alterId: number = 0;   // vmess 的 aid
  network: string = 'tcp'; // tcp | ws | grpc | h2
  tls: boolean = false;
  sni: string = '';
  wsPath: string = '';
  wsHost: string = '';
  grpcService: string = '';
  flow: string = '';
  fingerprint: string = '';
  realityPbk: string = '';
  realitySid: string = '';
  alpn: string = '';       // TLS ALPN，逗号分隔，如 h2,http/1.1
  allowInsecure: boolean = false;
  kcpSeed: string = '';    // mkcp/kcp 传输的 seed
  kcpHeader: string = '';  // mkcp/kcp 伪装类型（headerType，如 srtp/utp/wechat-video）
  xhttpMode: string = '';  // xhttp 模式（auto/stream-one/stream-up 等）
  hy2Obfs: string = '';     // hysteria2 混淆类型（如 salamander）
  hy2ObfsPassword: string = ''; // hysteria2 混淆密码
  hy2Up: string = '';       // hysteria2 上行带宽（如 50 Mbps）
  hy2Down: string = '';     // hysteria2 下行带宽（如 200 Mbps）
  tuicCongestion: string = '';  // tuic 拥塞控制（bbr/cubic/newreno）
  tuicUdpMode: string = '';     // tuic UDP 中继模式（native/quic）
  tuicReduceRtt: boolean = false;
  tuicFastOpen: boolean = false;
  anytlsMetadata: string = '';  // anytls client-metadata
  link: string = '';
}

/**
 * 节点：字段全量落盘，编辑/订阅/测速都基于它，不再依赖分享链接。
 */
export class Profile {
  id: string = '';
  name: string = '';
  link: string = '';
  type: string = '';
  server: string = '';
  port: number = 443;
  uuid: string = '';
  username: string = '';  // socks5/http 出站的用户名
  password: string = '';
  cipher: string = '';
  alterId: number = 0;
  network: string = 'tcp';
  tls: boolean = false;
  sni: string = '';
  wsPath: string = '';
  wsHost: string = '';
  grpcService: string = '';
  flow: string = '';
  fingerprint: string = '';
  realityPbk: string = '';
  realitySid: string = '';
  alpn: string = '';
  allowInsecure: boolean = false;
  kcpSeed: string = '';
  kcpHeader: string = '';
  xhttpMode: string = '';
  hy2Obfs: string = '';
  hy2ObfsPassword: string = '';
  hy2Up: string = '';
  hy2Down: string = '';
  tuicCongestion: string = '';
  tuicUdpMode: string = '';
  tuicReduceRtt: boolean = false;
  tuicFastOpen: boolean = false;
  anytlsMetadata: string = '';
  delay: number = -1;   // 测速结果（毫秒），-1 未测/不通
  /** 延迟测速是否跑过：未测显示「—」，测过不通才显示红色 -1 */
  delayTested: boolean = false;
  speed: number = -1;   // 下载测速结果（KB/s），-1 未测，0 测过不通
  subId: string = '';   // 来源订阅链接，空表示手动/内置
}

/** 分应用代理模式：all=全部走代理，allow=仅选中走代理，block=排除选中 */
export interface AppScope {
  mode: string;         // all | allow | block
  packages: string[];   // 包名列表（allow 用作白名单，block 用作黑名单）
}

/** 测速相关偏好：延迟测速并发上限、带宽测速下载字节数。落盘 settings.json。 */
export interface AppSettings {
  testConcurrency: number;
  speedBytes: number;
  /** 冷启动 / 掉线后是否自动重连（开关，默认开） */
  autoConnect: boolean;
  /** 节点无流量时是否允许自动故障转移（开关，默认开） */
  failover: boolean;
  /** 连接期间是否申请后台长时任务保活（开关，默认开） */
  keepAlive: boolean;
  /** 应用启动时是否静默更新所有带链接的订阅分组（开关，默认关） */
  autoUpdateOnStart: boolean;
}

/** 订阅分组配额：解析自响应头 subscription-userinfo（upload/download/total/expire）。 */
export interface SubQuota {
  upload: number;
  download: number;
  total: number;
  /** 到期时间戳（秒），0 表示订阅未返回到期时间 */
  expire: number;
}

/** 带响应头的 GET 结果：body 为响应正文，headers 的键统一转小写。 */
export interface FetchResult {
  body: string;
  headers: Map<string, string>;
}

/**
 * 全量备份载荷：节点、分组名、配额、规则、分应用名单、测速偏好与规则源地址。
 * 导出为 JSON 文件换机还原；selected 存选中节点身份（server/port/uuid/name），
 * 还原后按身份重新定位下标，避免顺序变化导致选错节点。
 */
export interface BackupPayload {
  version: number;
  app: string;
  createdAt: number;
  profiles: Profile[];
  groupNames: Record<string, string>;
  subQuota: Record<string, SubQuota>;
  rules: RuleItem[];
  appScope: AppScope;
  settings: AppSettings;
  rulesSrc: string;
  selected: Profile | null;
}

export class CoreState {
  running: boolean = false;
  message: string = '';
  up: number = 0;
  down: number = 0;
  totalUp: number = 0;
  totalDown: number = 0;
}

/** 内核 REST API / NAPI 的延迟测试响应 */
export interface DelayBody {
  delay?: number;
  message?: string;
  error?: string;
}

/** 跨进程测速：界面 → VPN 扩展进程的请求 */
export interface DelayReq {
  seq: number;
  name: string;
  url: string;
}

/** 跨进程测速：扩展进程 → 界面的结果 */
export interface DelayRes {
  seq: number;
  delay: number;
  error: string;
}

/**
 * 分流规则（对应 v2rayN 的「路由规则设置」一条）：
 * 渲染成 mihomo 的 rules 行 `${kind},${value},${target}`。
 */
export interface RuleItem {
  id: string;
  title: string;    // 界面显示名，如「绕过中国域名」
  kind: string;     // GEOSITE | GEOIP | DOMAIN-SUFFIX | DOMAIN-KEYWORD | IP-CIDR | AND | MATCH
  value: string;    // cn / CN / google.com / 192.168.0.0/16 / ((NETWORK,UDP),(DST-PORT,443))
  target: string;   // DIRECT | PROXY | REJECT
  enabled: boolean;
}

