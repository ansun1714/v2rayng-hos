/**
 * 分享链接解析：与 v2rayNG 一致，支持 vmess / vless / ss / trojan 分享链接。
 * 解析结果统一成 ProxySpec，再由 ConfigBuilder 生成 mihomo 配置。
 */
import { util } from '@kit.ArkTS';
import { Profile, ProxySpec } from './Model';

interface VmessJson {
  v?: string;
  ps?: string;
  add?: string;
  port?: string;
  id?: string;
  aid?: string;
  scy?: string;
  net?: string;
  type?: string;
  seed?: string;
  host?: string;
  path?: string;
  tls?: string;
  sni?: string;
  alpn?: string;
  fp?: string;
}

class UriParts {
  scheme: string = '';
  userinfo: string = '';
  host: string = '';
  port: number = 443;
  query: Map<string, string> = new Map<string, string>();
  name: string = '';
  valid: boolean = false;
}

export class ProxyLink {
  /** 解析分享链接并直接落成可持久化的节点对象（字段全量展开）。 */
  static toProfile(link: string, id: string, subId: string): Profile {
    const spec: ProxySpec = ProxyLink.parse(link);
    const p = new Profile();
    p.id = id;
    p.name = spec.name;
    p.link = link;
    p.type = spec.type;
    p.server = spec.server;
    p.port = spec.port;
    p.uuid = spec.uuid;
    p.username = spec.username;
    p.password = spec.password;
    p.cipher = spec.cipher;
    p.alterId = spec.alterId;
    p.network = spec.network;
    p.tls = spec.tls;
    p.sni = spec.sni;
    p.wsPath = spec.wsPath;
    p.wsHost = spec.wsHost;
    p.grpcService = spec.grpcService;
    p.flow = spec.flow;
    p.fingerprint = spec.fingerprint;
    p.realityPbk = spec.realityPbk;
    p.realitySid = spec.realitySid;
    p.alpn = spec.alpn;
    p.allowInsecure = spec.allowInsecure;
    p.kcpSeed = spec.kcpSeed;
    p.kcpHeader = spec.kcpHeader;
    p.xhttpMode = spec.xhttpMode;
    p.hy2Obfs = spec.hy2Obfs;
    p.hy2ObfsPassword = spec.hy2ObfsPassword;
    p.hy2Up = spec.hy2Up;
    p.hy2Down = spec.hy2Down;
    p.tuicCongestion = spec.tuicCongestion;
    p.tuicUdpMode = spec.tuicUdpMode;
    p.tuicReduceRtt = spec.tuicReduceRtt;
    p.tuicFastOpen = spec.tuicFastOpen;
    p.anytlsMetadata = spec.anytlsMetadata;
    p.subId = subId;
    return p;
  }

  static parse(link: string): ProxySpec {
    const text: string = link.trim();
    if (text.startsWith('vmess://')) {
      return ProxyLink.parseVmess(text);
    }
    if (text.startsWith('vless://')) {
      return ProxyLink.parseVless(text);
    }
    if (text.startsWith('trojan://')) {
      return ProxyLink.parseTrojan(text);
    }
    if (text.startsWith('hysteria2://') || text.startsWith('hy2://')) {
      return ProxyLink.parseHy2(text);
    }
    if (text.startsWith('tuic://')) {
      return ProxyLink.parseTuic(text);
    }
    if (text.startsWith('anytls://')) {
      return ProxyLink.parseAnytls(text);
    }
    if (text.startsWith('ss://')) {
      return ProxyLink.parseSs(text);
    }
    if (text.startsWith('socks5://') || text.startsWith('socks://')) {
      return ProxyLink.parseSocksHttp(text, 'socks5');
    }
    if (text.startsWith('http://') || text.startsWith('https://')) {
      return ProxyLink.parseSocksHttp(text, 'http');
    }
    throw new Error('不支持的链接：' + text.substring(0, 12));
  }

  static decodeBase64(input: string): string {
    let text: string = input.trim().replace(/-/g, '+').replace(/_/g, '/');
    while (text.length % 4 !== 0) {
      text += '=';
    }
    const helper = new util.Base64Helper();
    const bytes: Uint8Array = helper.decodeSync(text);
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(bytes);
  }

  static splitUri(link: string, scheme: string, defaultPort: number = 443): UriParts {
    const parts = new UriParts();
    parts.scheme = scheme;
    let rest: string = link.substring(scheme.length + 3);

    const hashIndex: number = rest.indexOf('#');
    if (hashIndex >= 0) {
      parts.name = decodeURIComponent(rest.substring(hashIndex + 1));
      rest = rest.substring(0, hashIndex);
    }

    const queryIndex: number = rest.indexOf('?');
    if (queryIndex >= 0) {
      const queryText: string = rest.substring(queryIndex + 1);
      rest = rest.substring(0, queryIndex);
      queryText.split('&').forEach((pair: string) => {
        const eq: number = pair.indexOf('=');
        if (eq > 0) {
          const key: string = decodeURIComponent(pair.substring(0, eq));
          const value: string = decodeURIComponent(pair.substring(eq + 1));
          parts.query.set(key, value);
        }
      });
    }

    const atIndex: number = rest.lastIndexOf('@');
    if (atIndex >= 0) {
      parts.userinfo = decodeURIComponent(rest.substring(0, atIndex));
      rest = rest.substring(atIndex + 1);
    }

    const colonIndex: number = rest.lastIndexOf(':');
    if (colonIndex > 0) {
      parts.host = rest.substring(0, colonIndex);
      const portText: string = rest.substring(colonIndex + 1);
      parts.port = portText.length > 0 ? Number.parseInt(portText) : defaultPort;
    } else {
      parts.host = rest;
      parts.port = defaultPort;
    }
    parts.valid = parts.host.length > 0;
    return parts;
  }

  static applyQuery(spec: ProxySpec, parts: UriParts): void {
    const network: string | undefined = parts.query.get('type');
    if (network !== undefined && network.length > 0) {
      spec.network = network === 'h2' ? 'h2' : network;
    }
    const security: string | undefined = parts.query.get('security');
    if (security !== undefined && (security === 'tls' || security === 'reality')) {
      spec.tls = true;
    }
    const sni: string | undefined = parts.query.get('sni') ?? parts.query.get('peer');
    if (sni !== undefined) {
      spec.sni = sni;
    }
    const path: string | undefined = parts.query.get('path');
    if (path !== undefined) {
      spec.wsPath = path;
    }
    const host: string | undefined = parts.query.get('host');
    if (host !== undefined) {
      spec.wsHost = host;
    }
    const serviceName: string | undefined = parts.query.get('serviceName');
    if (serviceName !== undefined) {
      spec.grpcService = serviceName;
    }
    const seed: string | undefined = parts.query.get('seed');
    if (seed !== undefined) {
      spec.kcpSeed = seed;
    }
    const headerType: string | undefined = parts.query.get('headerType')
      ?? parts.query.get('header-type') ?? parts.query.get('header');
    if (headerType !== undefined) {
      spec.kcpHeader = headerType;
    }
    const mode: string | undefined = parts.query.get('mode');
    if (mode !== undefined) {
      spec.xhttpMode = mode;
    }
    const flow: string | undefined = parts.query.get('flow');
    if (flow !== undefined) {
      spec.flow = flow;
    }
    const fp: string | undefined = parts.query.get('fp');
    if (fp !== undefined) {
      spec.fingerprint = fp;
    }
    const pbk: string | undefined = parts.query.get('pbk');
    if (pbk !== undefined) {
      spec.realityPbk = pbk;
    }
    const sid: string | undefined = parts.query.get('sid');
    if (sid !== undefined) {
      spec.realitySid = sid;
    }
    const alpn: string | undefined = parts.query.get('alpn');
    if (alpn !== undefined) {
      spec.alpn = alpn;
    }
    const insecure: string | undefined = parts.query.get('allowInsecure')
      ?? parts.query.get('insecure');
    if (insecure !== undefined) {
      spec.allowInsecure = insecure === '1' || insecure.toLowerCase() === 'true';
    }
    const obfs: string | undefined = parts.query.get('obfs');
    if (obfs !== undefined) {
      spec.hy2Obfs = obfs;
    }
    const obfsPassword: string | undefined = parts.query.get('obfs-password')
      ?? parts.query.get('obfsPassword');
    if (obfsPassword !== undefined) {
      spec.hy2ObfsPassword = obfsPassword;
    }
    const up: string | undefined = parts.query.get('up');
    if (up !== undefined) {
      spec.hy2Up = up;
    }
    const down: string | undefined = parts.query.get('down');
    if (down !== undefined) {
      spec.hy2Down = down;
    }
    const congestion: string | undefined = parts.query.get('congestion-controller')
      ?? parts.query.get('congestion');
    if (congestion !== undefined) {
      spec.tuicCongestion = congestion;
    }
    const udpMode: string | undefined = parts.query.get('udp-relay-mode')
      ?? parts.query.get('udpRelayMode');
    if (udpMode !== undefined) {
      spec.tuicUdpMode = udpMode;
    }
    const reduceRtt: string | undefined = parts.query.get('reduce-rtt')
      ?? parts.query.get('reduceRtt');
    if (reduceRtt !== undefined) {
      spec.tuicReduceRtt = reduceRtt === '1' || reduceRtt.toLowerCase() === 'true';
    }
    const fastOpen: string | undefined = parts.query.get('fast-open')
      ?? parts.query.get('fastOpen');
    if (fastOpen !== undefined) {
      spec.tuicFastOpen = fastOpen === '1' || fastOpen.toLowerCase() === 'true';
    }
    const metadata: string | undefined = parts.query.get('client-metadata')
      ?? parts.query.get('metadata');
    if (metadata !== undefined) {
      spec.anytlsMetadata = metadata;
    }
  }

  static parseVmess(link: string): ProxySpec {
    const spec = new ProxySpec();
    const body: string = ProxyLink.decodeBase64(link.substring('vmess://'.length));
    const json: VmessJson = JSON.parse(body) as VmessJson;

    spec.type = 'vmess';
    spec.server = json.add ?? '';
    spec.port = json.port !== undefined ? Number.parseInt(json.port) : 443;
    spec.uuid = json.id ?? '';
    spec.alterId = json.aid !== undefined ? Number.parseInt(json.aid) : 0;
    spec.cipher = (json.scy !== undefined && json.scy.length > 0) ? json.scy : 'auto';
    spec.network = json.net !== undefined ? json.net : 'tcp';
    spec.kcpSeed = json.seed ?? '';
    spec.kcpHeader = (spec.network === 'kcp' || spec.network === 'mkcp')
      ? (json.type ?? '') : '';
    spec.tls = json.tls === 'tls';
    spec.sni = json.sni ?? '';
    spec.wsPath = json.path ?? '';
    spec.wsHost = json.host ?? '';
    spec.fingerprint = json.fp ?? '';
    spec.alpn = json.alpn ?? '';
    spec.name = (json.ps !== undefined && json.ps.length > 0) ? json.ps : (spec.server + ':' + spec.port);
    spec.link = link;
    if (spec.server.length === 0) {
      throw new Error('vmess 链接缺少服务器地址');
    }
    return spec;
  }

  static parseVless(link: string): ProxySpec {
    const spec = new ProxySpec();
    const parts: UriParts = ProxyLink.splitUri(link, 'vless');
    if (!parts.valid) {
      throw new Error('vless 链接格式错误');
    }
    spec.type = 'vless';
    spec.server = parts.host;
    spec.port = parts.port;
    spec.uuid = parts.userinfo;
    spec.cipher = 'none';
    ProxyLink.applyQuery(spec, parts);
    spec.name = parts.name.length > 0 ? parts.name : (spec.server + ':' + spec.port);
    spec.link = link;
    return spec;
  }

  static parseTrojan(link: string): ProxySpec {
    const spec = new ProxySpec();
    const parts: UriParts = ProxyLink.splitUri(link, 'trojan');
    if (!parts.valid) {
      throw new Error('trojan 链接格式错误');
    }
    spec.type = 'trojan';
    spec.server = parts.host;
    spec.port = parts.port;
    spec.password = parts.userinfo;
    spec.tls = true;
    ProxyLink.applyQuery(spec, parts);
    spec.name = parts.name.length > 0 ? parts.name : (spec.server + ':' + spec.port);
    spec.link = link;
    return spec;
  }

  /** hysteria2:// / hy2://，userinfo 为密码。 */
  static parseHy2(link: string): ProxySpec {
    const spec = new ProxySpec();
    const scheme: string = link.toLowerCase().startsWith('hysteria2://') ? 'hysteria2' : 'hy2';
    const parts: UriParts = ProxyLink.splitUri(link, scheme);
    if (!parts.valid) {
      throw new Error('hysteria2 链接格式错误');
    }
    spec.type = 'hysteria2';
    spec.server = parts.host;
    spec.port = parts.port;
    spec.password = parts.userinfo;
    spec.tls = true;
    ProxyLink.applyQuery(spec, parts);
    spec.name = parts.name.length > 0 ? parts.name : (spec.server + ':' + spec.port);
    spec.link = link;
    return spec;
  }

  /** tuic://，userinfo 为 uuid:password（或仅 token）。 */
  static parseTuic(link: string): ProxySpec {
    const spec = new ProxySpec();
    const parts: UriParts = ProxyLink.splitUri(link, 'tuic');
    if (!parts.valid) {
      throw new Error('tuic 链接格式错误');
    }
    spec.type = 'tuic';
    spec.server = parts.host;
    spec.port = parts.port;
    const colon: number = parts.userinfo.indexOf(':');
    if (colon >= 0) {
      spec.uuid = parts.userinfo.substring(0, colon);
      spec.password = parts.userinfo.substring(colon + 1);
    } else {
      spec.password = parts.userinfo;
    }
    spec.tls = true;
    ProxyLink.applyQuery(spec, parts);
    spec.name = parts.name.length > 0 ? parts.name : (spec.server + ':' + spec.port);
    spec.link = link;
    return spec;
  }

  /** anytls://，userinfo 为密码。 */
  static parseAnytls(link: string): ProxySpec {
    const spec = new ProxySpec();
    const parts: UriParts = ProxyLink.splitUri(link, 'anytls');
    if (!parts.valid) {
      throw new Error('anytls 链接格式错误');
    }
    spec.type = 'anytls';
    spec.server = parts.host;
    spec.port = parts.port;
    spec.password = parts.userinfo;
    spec.tls = true;
    ProxyLink.applyQuery(spec, parts);
    spec.name = parts.name.length > 0 ? parts.name : (spec.server + ':' + spec.port);
    spec.link = link;
    return spec;
  }

  static parseSs(link: string): ProxySpec {
    const spec = new ProxySpec();
    spec.type = 'ss';
    let body: string = link.substring('ss://'.length);

    let name: string = '';
    const hashIndex: number = body.indexOf('#');
    if (hashIndex >= 0) {
      name = decodeURIComponent(body.substring(hashIndex + 1));
      body = body.substring(0, hashIndex);
    }

    const queryIndex: number = body.indexOf('?');
    if (queryIndex >= 0) {
      body = body.substring(0, queryIndex);
    }

    let credentials: string = '';
    let serverPart: string = '';
    const atIndex: number = body.indexOf('@');
    if (atIndex >= 0) {
      const userPart: string = body.substring(0, atIndex);
      serverPart = body.substring(atIndex + 1);
      credentials = userPart.indexOf(':') >= 0 ? decodeURIComponent(userPart) : ProxyLink.decodeBase64(userPart);
    } else {
      const decoded: string = ProxyLink.decodeBase64(body);
      const decodedAt: number = decoded.lastIndexOf('@');
      credentials = decoded.substring(0, decodedAt);
      serverPart = decoded.substring(decodedAt + 1);
    }

    const colonIndex: number = credentials.indexOf(':');
    if (colonIndex <= 0) {
      throw new Error('ss 链接缺少加密方式');
    }
    spec.cipher = credentials.substring(0, colonIndex);
    spec.password = credentials.substring(colonIndex + 1);

    const serverColon: number = serverPart.lastIndexOf(':');
    spec.server = serverColon > 0 ? serverPart.substring(0, serverColon) : serverPart;
    spec.port = serverColon > 0 ? Number.parseInt(serverPart.substring(serverColon + 1)) : 8388;
    spec.name = name.length > 0 ? name : (spec.server + ':' + spec.port);
    spec.link = link;
    if (spec.server.length === 0) {
      throw new Error('ss 链接解析失败');
    }
    return spec;
  }

  /** socks5:// / socks:// / http:// / https:// 出站链接；userinfo 可为 user:pass 或仅 pass。 */
  static parseSocksHttp(link: string, outType: string): ProxySpec {
    const spec = new ProxySpec();
    const lower: string = link.toLowerCase();
    const isHttps: boolean = lower.startsWith('https://');
    const scheme: string = outType === 'socks5'
      ? (lower.startsWith('socks5://') ? 'socks5' : 'socks')
      : (isHttps ? 'https' : 'http');
    const defaultPort: number = outType === 'socks5' ? 1080 : (isHttps ? 443 : 80);
    const parts: UriParts = ProxyLink.splitUri(link, scheme, defaultPort);
    if (!parts.valid) {
      throw new Error(outType + ' 链接格式错误');
    }
    spec.type = outType;
    spec.server = parts.host;
    spec.port = parts.port;
    const colon: number = parts.userinfo.indexOf(':');
    if (colon >= 0) {
      spec.username = parts.userinfo.substring(0, colon);
      spec.password = parts.userinfo.substring(colon + 1);
    } else {
      spec.password = parts.userinfo;
    }
    spec.tls = isHttps;
    ProxyLink.applyQuery(spec, parts);
    spec.name = parts.name.length > 0 ? parts.name : (spec.server + ':' + spec.port);
    spec.link = link;
    if (spec.server.length === 0) {
      throw new Error(outType + ' 链接缺少服务器地址');
    }
    return spec;
  }

  /** 把节点字段编码成 base64 字符串（vmess / ss 凭据用）。 */
  private static b64encode(text: string): string {
    const enc: util.TextEncoder = util.TextEncoder.create('utf-8');
    const bytes: Uint8Array = enc.encodeInto(text);
    const helper: util.Base64Helper = new util.Base64Helper();
    const b64: Uint8Array = helper.encodeSync(bytes);
    const dec: util.TextDecoder = util.TextDecoder.create('iso8859-1');
    return dec.decodeToString(b64);
  }

  /** 拼 vless / trojan 通用的 ?type=...&... 查询串；空值不写。 */
  private static commonQuery(p: Profile): string {
    const q: string[] = [];
    const add = (k: string, v: string): void => {
      if (v !== undefined && v.length > 0) {
        q.push(k + '=' + encodeURIComponent(v));
      }
    };
    add('type', p.network);
    if (p.tls) {
      add('security', p.realityPbk.length > 0 ? 'reality' : 'tls');
      add('sni', p.sni);
      add('fp', p.fingerprint);
      add('pbk', p.realityPbk);
      add('sid', p.realitySid);
      add('alpn', p.alpn);
      if (p.allowInsecure) {
        q.push('allowInsecure=1');
      }
    }
    if (p.network === 'ws') {
      add('path', p.wsPath);
      add('host', p.wsHost);
    } else if (p.network === 'grpc') {
      add('serviceName', p.grpcService);
    } else if (p.network === 'mkcp' || p.network === 'kcp') {
      add('seed', p.kcpSeed);
      add('headerType', p.kcpHeader);
    } else if (p.network === 'http') {
      add('path', p.wsPath);
      add('host', p.wsHost);
    } else if (p.network === 'xhttp') {
      add('path', p.wsPath);
      add('host', p.wsHost);
      add('mode', p.xhttpMode);
    }
    add('flow', p.flow);
    return q.length > 0 ? '?' + q.join('&') : '';
  }

  /**
   * 按节点字段反向生成分享链接（用于复制 / 分享）。
   * vmess 的字段组合在本工程内无法完全无损重建，优先回退导入时保留的原始 link。
   */
  static toLink(p: Profile): string {
    const name: string = encodeURIComponent(p.name);
    if (p.type === 'vmess') {
      if (p.link.length > 0 && p.link.startsWith('vmess://')) {
        return p.link;
      }
      const obj: VmessJson = {
        v: '2', ps: p.name, add: p.server, port: String(p.port), id: p.uuid,
        aid: String(p.alterId), scy: p.cipher, net: p.network, type: p.network,
        host: p.wsHost, path: p.wsPath, tls: p.tls ? 'tls' : '', sni: p.sni,
        alpn: p.alpn, fp: p.fingerprint
      };
      return 'vmess://' + ProxyLink.b64encode(JSON.stringify(obj)) + '#' + name;
    }
    if (p.type === 'ss') {
      const cred: string = ProxyLink.b64encode(p.cipher + ':' + p.password);
      return 'ss://' + cred + '@' + p.server + ':' + String(p.port) + '#' + name;
    }
    if (p.type === 'trojan') {
      return 'trojan://' + encodeURIComponent(p.password) + '@' + p.server + ':' +
        String(p.port) + ProxyLink.commonQuery(p) + '#' + name;
    }
    if (p.type === 'socks5' || p.type === 'http') {
      const cred: string = p.username.length > 0
        ? encodeURIComponent(p.username) + ':' + encodeURIComponent(p.password)
        : encodeURIComponent(p.password);
      const scheme: string = p.type === 'http' ? (p.tls ? 'https' : 'http') : 'socks5';
      return scheme + '://' + cred + '@' + p.server + ':' + String(p.port) + '#' + name;
    }
    if (p.type === 'hysteria2') {
      if (p.link.length > 0 && p.link.startsWith('hysteria2://')) {
        return p.link;
      }
      const q: string[] = [];
      const add = (k: string, v: string): void => {
        if (v.length > 0) { q.push(k + '=' + encodeURIComponent(v)); }
      };
      add('obfs', p.hy2Obfs);
      add('obfs-password', p.hy2ObfsPassword);
      add('sni', p.sni);
      add('alpn', p.alpn);
      add('up', p.hy2Up);
      add('down', p.hy2Down);
      add('fp', p.fingerprint);
      if (p.allowInsecure) { q.push('allowInsecure=1'); }
      const qs: string = q.length > 0 ? '?' + q.join('&') : '';
      return 'hysteria2://' + encodeURIComponent(p.password) + '@' + p.server + ':' +
        String(p.port) + qs + '#' + name;
    }
    if (p.type === 'tuic') {
      if (p.link.length > 0 && p.link.startsWith('tuic://')) {
        return p.link;
      }
      const q: string[] = [];
      const add = (k: string, v: string): void => {
        if (v.length > 0) { q.push(k + '=' + encodeURIComponent(v)); }
      };
      add('sni', p.sni);
      add('alpn', p.alpn);
      add('congestion-controller', p.tuicCongestion);
      add('udp-relay-mode', p.tuicUdpMode);
      if (p.tuicReduceRtt) { q.push('reduce-rtt=1'); }
      if (p.tuicFastOpen) { q.push('fast-open=1'); }
      add('fp', p.fingerprint);
      if (p.allowInsecure) { q.push('allowInsecure=1'); }
      const qs: string = q.length > 0 ? '?' + q.join('&') : '';
      const cred: string = p.uuid.length > 0
        ? encodeURIComponent(p.uuid) + ':' + encodeURIComponent(p.password)
        : encodeURIComponent(p.password);
      return 'tuic://' + cred + '@' + p.server + ':' + String(p.port) + qs + '#' + name;
    }
    if (p.type === 'anytls') {
      if (p.link.length > 0 && p.link.startsWith('anytls://')) {
        return p.link;
      }
      const q: string[] = [];
      const add = (k: string, v: string): void => {
        if (v.length > 0) { q.push(k + '=' + encodeURIComponent(v)); }
      };
      add('sni', p.sni);
      add('alpn', p.alpn);
      add('client-metadata', p.anytlsMetadata);
      add('fp', p.fingerprint);
      if (p.allowInsecure) { q.push('allowInsecure=1'); }
      const qs: string = q.length > 0 ? '?' + q.join('&') : '';
      return 'anytls://' + encodeURIComponent(p.password) + '@' + p.server + ':' +
        String(p.port) + qs + '#' + name;
    }
    // vless（默认）
    return 'vless://' + encodeURIComponent(p.uuid) + '@' + p.server + ':' +
      String(p.port) + ProxyLink.commonQuery(p) + '#' + name;
  }
}
