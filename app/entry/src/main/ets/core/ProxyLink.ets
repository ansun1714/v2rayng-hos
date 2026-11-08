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
    if (text.startsWith('ss://')) {
      return ProxyLink.parseSs(text);
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

  static splitUri(link: string, scheme: string): UriParts {
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
      parts.port = portText.length > 0 ? Number.parseInt(portText) : 443;
    } else {
      parts.host = rest;
      parts.port = 443;
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
    spec.tls = json.tls === 'tls';
    spec.sni = json.sni ?? '';
    spec.wsPath = json.path ?? '';
    spec.wsHost = json.host ?? '';
    spec.fingerprint = json.fp ?? '';
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
}
