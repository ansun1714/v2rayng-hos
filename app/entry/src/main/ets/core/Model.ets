/**
 * 节点模型：对应 v2rayNG 的"配置/节点"概念，字段是各协议的交集。
 */
export class ProxySpec {
  name: string = 'node';
  type: string = 'vless'; // vmess | vless | ss | trojan
  server: string = '';
  port: number = 443;
  uuid: string = '';
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
  delay: number = -1;   // 测速结果（毫秒），-1 未测
  subId: string = '';   // 来源订阅链接，空表示手动/内置
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

