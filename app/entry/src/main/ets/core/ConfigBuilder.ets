/**
 * 生成 mihomo 内核配置（YAML）。
 * - tun fd 由 VpnExtensionAbility 在启动时注入
 * - 节点：全部节点都进 proxies（供测速/切换），当前选中节点放在 group 首位生效
 * - 分流：国内域名/IP 直连（走手机自己的 DNS），其余走代理
 */
import { Profile, RuleItem } from './Model';

const TUN_FD_TOKEN: string = '__TUN_FD__';
const GROUP_NAME: string = 'PROXY';

export class ConfigBuilder {
  /** 默认分流规则（对齐 v2rayN「路由规则设置」的常用项，语义不变）。 */
  static defaultRules(): RuleItem[] {
    return [
      { id: 'r_private_site', title: '绕过局域网域名', kind: 'GEOSITE', value: 'private',
        target: 'DIRECT', enabled: true },
      { id: 'r_cn_site', title: '绕过中国域名', kind: 'GEOSITE', value: 'cn',
        target: 'DIRECT', enabled: true },
      { id: 'r_cn_ip', title: '绕过中国 IP', kind: 'GEOIP', value: 'CN',
        target: 'DIRECT', enabled: true },
      { id: 'r_udp443', title: '阻断 UDP 443（QUIC）', kind: 'AND',
        value: '((NETWORK,UDP),(DST-PORT,443))', target: 'REJECT', enabled: false },
      { id: 'r_foreign_site', title: '代理境外域名', kind: 'GEOSITE', value: 'geolocation-!cn',
        target: 'PROXY', enabled: true },
      { id: 'r_match', title: '其余流量走代理（兜底）', kind: 'MATCH', value: '',
        target: 'PROXY', enabled: true }
    ];
  }

  /** 规则值做白名单清洗：防换行/逗号破坏 YAML，也避免任意注入。 */
  static safeValue(kind: string, value: string): string {
    if (kind === 'MATCH') {
      return '';
    }
    return value.replace(/[\r\n"'\\]/g, '').trim();
  }

  /** 允许写入配置的规则类型白名单；表外的 kind 一律丢弃，避免把配置写坏。 */
  static knownKinds(): string[] {
    return ['GEOSITE', 'GEOIP', 'DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD',
      'DOMAIN-REGEX', 'IP-CIDR', 'IP-CIDR6', 'SRC-IP-CIDR', 'SRC-PORT', 'DST-PORT',
      'NETWORK', 'AND', 'OR', 'NOT', 'MATCH'];
  }

  /** 一条规则渲染成 mihomo rules 行；非法或禁用返回空串。 */
  static renderRule(rule: RuleItem): string {
    if (!rule.enabled) {
      return '';
    }
    const target: string = rule.target;
    if (target !== 'DIRECT' && target !== 'PROXY' && target !== 'REJECT') {
      return '';
    }
    const value: string = ConfigBuilder.safeValue(rule.kind, rule.value);
    if (rule.kind === 'MATCH') {
      return '  - MATCH,' + target;
    }
    if (value.length === 0) {
      return '';
    }
    // GEOIP 规则必须带 no-resolve：否则内核为了判国别会在本地做一次明文 DNS 查询，
    // 境外域名的访问目标就白送给运营商了（域名本应交给 GEOSITE 规则判定）。
    if (rule.kind === 'IP-CIDR' || rule.kind === 'IP-CIDR6' || rule.kind === 'GEOIP') {
      return '  - ' + rule.kind + ',' + value + ',' + target + ',no-resolve';
    }
    return '  - ' + rule.kind + ',' + value + ',' + target;
  }

  /**
   * 解析外部规则文本：支持
   * 1) 本 App 的 rules.json（数组，字段 title/kind/value/target/enabled）
   * 2) Clash / mihomo 的 rules 片段（`- DOMAIN-SUFFIX,x.com,DIRECT`）
   * 3) 一行一条的 `GEOSITE,cn,DIRECT` 或 `geosite:cn direct`
   * 4) rule-provider 的 payload 列表（Loyalsoldier / ACL4SSR 那种纯域名/IP 清单），
   *    方向由 targetHint 决定（direct 类清单给 DIRECT，proxy/gfw 类给 PROXY）
   * 返回规则数组；解析不出任何规则时返回空数组。
   */
  static parseRules(text: string, targetHint: string = 'PROXY'): RuleItem[] {
    const trimmed: string = text.trim();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      const fromJson: RuleItem[] = ConfigBuilder.parseRulesJson(trimmed);
      if (fromJson.length > 0) {
        return fromJson;
      }
    }
    if (ConfigBuilder.looksLikePayload(trimmed)) {
      const fromPayload: RuleItem[] = ConfigBuilder.parsePayload(trimmed, targetHint);
      if (fromPayload.length > 0) {
        return fromPayload;
      }
    }
    const out: RuleItem[] = [];
    const lines: string[] = trimmed.split('\n');
    lines.forEach((raw: string) => {
      let line: string = raw.trim();
      if (line.length === 0 || line.startsWith('#') || line.startsWith('//')) {
        return;
      }
      if (line.startsWith('-')) {
        line = line.substring(1).trim();
      }
      const rule: RuleItem | null = ConfigBuilder.parseRuleLine(line, out.length);
      if (rule !== null) {
        out.push(rule);
      }
    });
    return out;
  }

  /** 判断是不是 rule-provider 的纯列表（不带 target 列）。 */
  static looksLikePayload(text: string): boolean {
    if (text.indexOf('payload:') >= 0) {
      return true;
    }
    const lines: string[] = text.split('\n');
    if (lines.length < 5) {
      return false;
    }
    let plain: number = 0;
    let odd: number = 0;
    lines.forEach((raw: string) => {
      const line: string = raw.trim();
      if (line.length === 0 || line.startsWith('#') || line.startsWith('//')) {
        return;
      }
      if (line.indexOf(',') >= 0) {
        odd++;
        return;
      }
      const body: string = line.startsWith('-') ? line.substring(1).trim() : line;
      if (body.length === 0 || body.indexOf(' ') >= 0) {
        odd++;
        return;
      }
      plain++;
    });
    // 全是无逗号、无空格的单值清单才算 payload；混合写法仍按行式解析
    return plain >= 5 && odd === 0;
  }

  /** 把 payload 清单转成规则：域名→DOMAIN-SUFFIX（含子域），CIDR→IP-CIDR/IP-CIDR6。 */
  static parsePayload(text: string, targetHint: string): RuleItem[] {
    const out: RuleItem[] = [];
    const target: string = ConfigBuilder.normTarget(targetHint);
    const seen: Set<string> = new Set<string>();
    const now: number = Date.now();
    const lines: string[] = text.split('\n');
    lines.forEach((raw: string) => {
      let line: string = raw.trim();
      if (line.length === 0 || line.startsWith('#') || line.startsWith('//')) {
        return;
      }
      if (line === 'payload:') {
        return;
      }
      if (line.endsWith(':') && !line.startsWith('-')) {
        return;
      }
      if (line.startsWith('-')) {
        line = line.substring(1).trim();
      }
      line = line.replace(/^['"]/, '').replace(/['"]$/, '').trim();
      if (line.indexOf(' ') >= 0) {
        return; // 复杂表达式（AND/NOT 等）不在清单里，跳过
      }
      if (line.startsWith('+.')) {
        line = line.substring(2);
      } else if (line.startsWith('*.')) {
        line = line.substring(2);
      } else if (line.startsWith('.')) {
        line = line.substring(1);
      }
      if (line.length === 0 || line.indexOf(',') >= 0) {
        return;
      }
      let kind: string = 'DOMAIN-SUFFIX';
      if (line.indexOf('/') > 0 && (line.indexOf(':') >= 0 || /^[0-9.]+/.test(line))) {
        kind = line.indexOf(':') >= 0 ? 'IP-CIDR6' : 'IP-CIDR';
      }
      if (seen.has(line)) {
        return;
      }
      seen.add(line);
      out.push({
        id: 'p_' + String(out.length) + '_' + String(now),
        title: line,
        kind: kind,
        value: line,
        target: target,
        enabled: true
      });
    });
    return out;
  }

  static parseRulesJson(text: string): RuleItem[] {
    const out: RuleItem[] = [];
    try {
      let list: RuleItem[] = [];
      if (text.startsWith('[')) {
        list = JSON.parse(text) as RuleItem[];
      } else {
        const obj = JSON.parse(text) as Record<string, Object>;
        const inner = obj['rules'];
        if (inner !== undefined) {
          list = inner as RuleItem[];
        }
      }
      list.forEach((item: RuleItem, i: number) => {
        const kind: string = String(item.kind !== undefined ? item.kind : '').toUpperCase();
        if (kind.length === 0) {
          return;
        }
        // 外部 JSON 只认白名单内的 kind，其余丢弃（防注入、防整份配置解析失败）
        if (ConfigBuilder.knownKinds().indexOf(kind) < 0) {
          return;
        }
        out.push({
          id: 'i_' + String(i) + '_' + String(Date.now()),
          title: item.title !== undefined && item.title.length > 0 ? item.title : kind + ' ' + item.value,
          kind: kind,
          value: item.value !== undefined ? String(item.value) : '',
          target: ConfigBuilder.normTarget(item.target),
          enabled: item.enabled !== false
        });
      });
    } catch (err) {
    }
    return out;
  }

  /** 宽松解析单行：`GEOSITE,cn,DIRECT` / `geosite:cn direct` / `DOMAIN-SUFFIX,xx.com,PROXY`。 */
  static parseRuleLine(line: string, seq: number): RuleItem | null {
    let kind: string = '';
    let value: string = '';
    let target: string = '';
    if (line.indexOf(',') > 0) {
      const parts: string[] = line.split(',');
      kind = parts[0].trim().toUpperCase();
      const last: string = parts[parts.length - 1].trim();
      target = ConfigBuilder.normTarget(last);
      if (parts.length === 2) {
        // 形如 `MATCH,DIRECT`
        value = '';
      } else {
        value = parts.slice(1, parts.length - 1).join(',').trim();
      }
    } else {
      // `geosite:cn direct` 这种空格分隔
      const tokens: string[] = line.split(/\s+/);
      if (tokens.length < 2) {
        return null;
      }
      const head: string = tokens[0];
      if (head.indexOf(':') > 0) {
        const pair: string[] = head.split(':');
        kind = ConfigBuilder.kindFromShort(pair[0]);
        value = pair[1];
      } else {
        kind = head.toUpperCase();
        value = tokens[1];
      }
      target = ConfigBuilder.normTarget(tokens[tokens.length - 1]);
    }
    if (kind.length === 0) {
      return null;
    }
    // 未知 kind 直接跳过，避免写进内核后整份配置失效
    const known: string[] = ConfigBuilder.knownKinds();
    if (known.indexOf(kind) < 0) {
      return null;
    }
    if (kind === 'MATCH' && target.length === 0) {
      return null;
    }
    if (kind !== 'MATCH' && value.length === 0) {
      return null;
    }
    return {
      id: 'i_' + String(seq) + '_' + String(Date.now()),
      title: kind + ' ' + (value.length > 0 ? value : target),
      kind: kind,
      value: ConfigBuilder.safeValue(kind, value),
      target: target.length > 0 ? target : 'DIRECT',
      enabled: true
    };
  }

  static kindFromShort(short: string): string {
    const key: string = short.trim().toLowerCase();
    if (key === 'geosite') {
      return 'GEOSITE';
    }
    if (key === 'geoip') {
      return 'GEOIP';
    }
    if (key === 'domain') {
      return 'DOMAIN-SUFFIX';
    }
    return key.toUpperCase();
  }

  /** 目标只认三种；节点名一律归到 PROXY，避免规则指向不存在的组。 */
  static normTarget(raw: string): string {
    const upper: string = String(raw).trim().toUpperCase();
    if (upper === 'DIRECT' || upper === 'REJECT' || upper === 'BLOCK') {
      return upper === 'BLOCK' ? 'REJECT' : upper;
    }
    return 'PROXY';
  }

  static groupName(): string {
    return GROUP_NAME;
  }

  static quote(text: string): string {
    const escaped: string = text.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    return '"' + escaped + '"';
  }

  static buildProxy(profile: Profile): string {
    const lines: string[] = [];
    lines.push('  - name: ' + ConfigBuilder.quote(profile.name));
    lines.push('    type: ' + profile.type);
    lines.push('    server: ' + ConfigBuilder.quote(profile.server));
    lines.push('    port: ' + profile.port);
    lines.push('    udp: true');

    if (profile.type === 'vmess') {
      lines.push('    uuid: ' + ConfigBuilder.quote(profile.uuid));
      lines.push('    alterId: ' + profile.alterId);
      lines.push('    cipher: ' + ConfigBuilder.quote(profile.cipher.length > 0 ? profile.cipher : 'auto'));
    } else if (profile.type === 'vless') {
      lines.push('    uuid: ' + ConfigBuilder.quote(profile.uuid));
      if (profile.flow.length > 0) {
        lines.push('    flow: ' + ConfigBuilder.quote(profile.flow));
      }
    } else if (profile.type === 'trojan') {
      lines.push('    password: ' + ConfigBuilder.quote(profile.password));
    } else if (profile.type === 'ss') {
      lines.push('    cipher: ' + ConfigBuilder.quote(profile.cipher));
      lines.push('    password: ' + ConfigBuilder.quote(profile.password));
    } else if (profile.type === 'socks5' || profile.type === 'http') {
      if (profile.username.length > 0) {
        lines.push('    username: ' + ConfigBuilder.quote(profile.username));
      }
      if (profile.password.length > 0) {
        lines.push('    password: ' + ConfigBuilder.quote(profile.password));
      }
    }

    if (profile.type !== 'socks5' && profile.type !== 'http') {
    if (profile.network === 'ws') {
      lines.push('    network: ws');
      lines.push('    ws-opts:');
      if (profile.wsPath.length > 0) {
        lines.push('      path: ' + ConfigBuilder.quote(profile.wsPath));
      }
      if (profile.wsHost.length > 0) {
        lines.push('      headers:');
        lines.push('        Host: ' + ConfigBuilder.quote(profile.wsHost));
      }
    } else if (profile.network === 'grpc') {
      lines.push('    network: grpc');
      lines.push('    grpc-opts:');
      lines.push('      grpc-service-name: ' + ConfigBuilder.quote(profile.grpcService));
    } else if (profile.network === 'h2') {
      lines.push('    network: h2');
      lines.push('    h2-opts:');
      if (profile.wsPath.length > 0) {
        lines.push('      path: ' + ConfigBuilder.quote(profile.wsPath));
      }
      if (profile.wsHost.length > 0) {
        lines.push('      host:');
        lines.push('        - ' + ConfigBuilder.quote(profile.wsHost));
      }
    }
    }

    if (profile.tls) {
      lines.push('    tls: true');
      if (profile.sni.length > 0) {
        lines.push('    servername: ' + ConfigBuilder.quote(profile.sni));
      }
      if (profile.fingerprint.length > 0) {
        lines.push('    client-fingerprint: ' + ConfigBuilder.quote(profile.fingerprint));
      }
      if (profile.realityPbk.length > 0) {
        lines.push('    reality-opts:');
        lines.push('      public-key: ' + ConfigBuilder.quote(profile.realityPbk));
        if (profile.realitySid.length > 0) {
          lines.push('      short-id: ' + ConfigBuilder.quote(profile.realitySid));
        }
      }
      if (profile.alpn.length > 0) {
        const alpnItems: string[] = profile.alpn.split(',').map((a: string) => a.trim())
          .filter((a: string) => a.length > 0);
        if (alpnItems.length > 0) {
          lines.push('    alpn: [' + alpnItems.map((a: string) => ConfigBuilder.quote(a)).join(', ') + ']');
        }
      }
      if (profile.allowInsecure === true) {
        lines.push('    skip-cert-verify: true');
      }
    }
    return lines.join('\n');
  }

  /** 生成完整配置：多节点 + 分组（供测速/切换）+ 规则驱动的分流 + tun fd 占位。 */
  static build(profiles: Profile[], selected: number, rules: RuleItem[]): string {
    const lines: string[] = [];
    // 只走 tun，不开本地混合端口：allow-lan:false 时它虽只绑 127.0.0.1，
    // 但本机任意应用都能无认证借道（7890），没必要留这个面。
    // 也不开 external-controller：界面进程访问不到内核的网络命名空间，
    // 且无 secret 时 mihomo 默认放开 CORS，属于纯粹多出来的攻击面。
    lines.push('allow-lan: false');
    lines.push('mode: rule');
    // info 级别会把每条连接的目的地址写进日志，隐私上不可接受，只保留 warning 及以上
    lines.push('log-level: warning');
    // IPv6 保持关闭：鸿蒙这台设备上 VpnConfig 的 v6 默认路由不会生效（真机实测），
    // v6 一旦放出去就是绕过隧道直连、暴露真实地址。关掉它就只走 v4，全部流量进隧道。
    lines.push('ipv6: false');
    lines.push('unified-delay: true');
    lines.push('tcp-concurrent: true');
    lines.push('find-process-mode: off');
    lines.push('global-client-fingerprint: chrome');
    lines.push('');
    // 分流依赖的 geo 数据：随 App 打包进 rawfile，启动时拷到 filesDir（内核 home 目录）
    lines.push('geodata-mode: true');
    lines.push('geo-auto-update: false');
    lines.push('');
    lines.push('dns:');
    lines.push('  enable: true');
    lines.push('  ipv6: false');
    lines.push('  enhanced-mode: fake-ip');
    lines.push('  fake-ip-range: 198.18.0.1/16');
    lines.push('  fake-ip-filter:');
    lines.push('    - "+.lan"');
    lines.push('    - "+.local"');
    lines.push('    - "localhost"');
    // 引导 DNS：只能填 IP（mihomo 用它先把 DoH 服务器域名解析出来），
    // 这两条是明文但不承载用户查询，只是用来把下面 DoH 的域名解析成 IP。
    lines.push('  default-nameserver:');
    lines.push('    - 223.5.5.5');
    lines.push('    - 119.29.29.29');
    // 常规解析全部走 DoH，运营商看不到查询内容，应答也没法篡改。
    lines.push('  nameserver:');
    lines.push('    - "https://dns.alidns.com/dns-query"');
    lines.push('    - "https://doh.pub/dns-query"');
    // 解析代理服务器域名同样用 DoH（直连，不绕代理，避免自己解析自己）
    lines.push('  proxy-server-nameserver:');
    lines.push('    - "https://dns.alidns.com/dns-query"');
    lines.push('    - "https://doh.pub/dns-query"');
    lines.push('  nameserver-policy:');
    lines.push('    "geosite:cn":');
    lines.push('      - "https://dns.alidns.com/dns-query"');
    lines.push('      - "https://doh.pub/dns-query"');
    lines.push('');
    lines.push('tun:');
    lines.push('  enable: true');
    lines.push('  stack: mips');
    lines.push('  device: tun0');
    lines.push('  file-descriptor: ' + TUN_FD_TOKEN);
    lines.push('  dns-hijack:');
    lines.push('    - "any:53"');
    lines.push('  auto-route: false');
    lines.push('  auto-detect-interface: false');
    lines.push('  mtu: 1400');
    lines.push('  inet4-address:');
    lines.push('    - 172.19.0.1/30');
    lines.push('');
    lines.push('proxies:');
    profiles.forEach((item: Profile) => {
      lines.push(ConfigBuilder.buildProxy(item));
    });
    lines.push('');
    lines.push('proxy-groups:');
    lines.push('  - name: ' + GROUP_NAME);
    lines.push('    type: select');
    lines.push('    proxies:');
    const ordered: number[] = ConfigBuilder.order(profiles, selected);
    ordered.forEach((index: number) => {
      lines.push('      - ' + ConfigBuilder.quote(profiles[index].name));
    });
    lines.push('');
    lines.push('rules:');
    // 出口 IP 查询域名固定走代理：这几条必须排在最前。
    // 否则「绕过中国域名/中国 IP」会把它们判成直连，测回来的是本地宽带地址，不是节点出口。
    lines.push('  - DOMAIN-SUFFIX,ipip.net,PROXY');
    lines.push('  - DOMAIN-SUFFIX,ip.sb,PROXY');
    const active: RuleItem[] = rules.filter((rule: RuleItem) => rule.enabled);
    if (active.length === 0) {
      // 兜底：规则文件被清空也不能让内核直接放行全部流量
      ConfigBuilder.defaultRules().forEach((rule: RuleItem) => {
        const row: string = ConfigBuilder.renderRule(rule);
        if (row.length > 0) {
          lines.push(row);
        }
      });
    } else {
      active.forEach((rule: RuleItem) => {
        const row: string = ConfigBuilder.renderRule(rule);
        if (row.length > 0) {
          lines.push(row);
        }
      });
    }
    // 没有 MATCH 时补一条，保证未命中的流量仍然走代理
    let hasMatch: boolean = false;
    lines.forEach((line: string) => {
      if (line.trim().startsWith('- MATCH,')) {
        hasMatch = true;
      }
    });
    if (!hasMatch) {
      lines.push('  - MATCH,' + GROUP_NAME);
    }
    return lines.join('\n');
  }

  /** 选中的节点排第一位（mihomo select 组默认取第一个），其余按原顺序。 */
  static order(profiles: Profile[], selected: number): number[] {
    const result: number[] = [];
    if (selected >= 0 && selected < profiles.length) {
      result.push(selected);
    }
    for (let i = 0; i < profiles.length; i++) {
      if (i !== selected) {
        result.push(i);
      }
    }
    return result;
  }

  static injectFd(config: string, fd: number): string {
    return config.replace(TUN_FD_TOKEN, String(fd));
  }
}
