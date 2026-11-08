import { common, Want } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vpnExtension, http } from '@kit.NetworkKit';
import { PromptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { ProxyLink } from '../core/ProxyLink';
import { Profile, CoreState, DelayBody, DelayReq, DelayRes, RuleItem } from '../core/Model';
import { ConfigBuilder } from '../core/ConfigBuilder';
import { FileStore } from '../core/FileStore';

const BUNDLE_NAME: string = 'com.maoxu.v2rayng';
const EXT_ABILITY: string = 'VpnExtAbility';
const API_BASE: string = 'http://127.0.0.1:9090';
const TEST_URL: string = 'http://www.gstatic.com/generate_204';
/** 规则订阅地址的默认值：内置推荐规则集（点「网址更新」即还原默认 6 条）。 */
const BUILTIN_RULE_SRC: string = 'builtin://default';

/** 节点分组：key 为空表示手动添加的节点，否则为订阅 URL。 */
class NodeGroup {
  key: string = '';
  title: string = '';
  indices: number[] = [];
}

@Entry
@Component
struct Index {
  @State profiles: Profile[] = [];
  @State selected: number = -1;
  @State running: boolean = false;
  @State statusText: string = '未连接';
  @State trafficText: string = '';
  @State summary: string = 'mihomo 内核 · 国内直连 / 国外代理';
  @State linkInput: string = '';
  @State subInput: string = '';
  @State testing: boolean = false;
  /** 测速进度：已测 / 待测 */
  @State testDone: number = 0;
  @State testTotal: number = 0;
  @State testInfo: string = '';
  /** 列表重建戳：分组 ForEach 的 key 靠它变化才会重新渲染 */
  @State stamp: number = 0;
  /** 分组折叠状态：显式展开 / 显式收起过的订阅 key */
  @State openedKeys: string[] = [];
  @State closedKeys: string[] = [];
  /** 按延迟排序（默认开：重启后仍沿用已测出的延迟；测速过程中临时关闭，避免列表乱跳） */
  @State sortByDelay: boolean = true;
  /** 左侧抽屉：订阅链接与各类导入都收进这里，主页面只留节点列表 */
  @State drawerOpen: boolean = false;

  // 分流规则（设置页）
  @State rules: RuleItem[] = [];
  @State rulePanel: boolean = false;
  @State ruleEditing: number = -1;
  @State rTitle: string = '';
  @State rKind: string = 'GEOSITE';
  @State rValue: string = '';
  @State rTarget: string = 'DIRECT';
  @State ruleUrl: string = '';
  @State ruleMsg: string = '';
  /** 规则列表一次渲染多少条：社区规则集动辄几千条，分页渲染避免列表卡死。 */
  @State rulesLimit: number = 50;

  // 编辑面板
  @State editing: number = -1;
  @State editNew: boolean = false;
  @State eName: string = '';
  @State eType: string = 'vless';
  @State eServer: string = '';
  @State ePort: string = '443';
  @State eUuid: string = '';
  @State ePassword: string = '';
  @State eCipher: string = '';
  @State eNetwork: string = 'ws';
  @State eTls: boolean = true;
  @State eSni: string = '';
  @State ePath: string = '';
  @State eHost: string = '';

  private filesDir: string = '';
  private pollTimer: number = -1;
  /** 节点列表变动后的自动重连互斥，避免连续操作把连接状态搅乱 */
  private reconnecting: boolean = false;
  private toast: PromptAction = this.getUIContext().getPromptAction();

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.filesDir = context.filesDir;
    FileStore.writeText(FileStore.statePath(this.filesDir), '{"running":false,"message":"未连接"}');
    this.reload();
    if (this.profiles.length === 0) {
      this.seedDefaultNodes();
    }
    const pending: string = AppStorage.get<string>('launchImportUri') ?? '';
    if (pending.length > 0) {
      AppStorage.setOrCreate<string>('launchImportUri', '');
      this.linkInput = pending;
      this.importFromText();
    }
    this.pollTimer = setInterval(() => {
      this.readState();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  // ---------- 数据 ----------

  reload(): void {
    const loaded: Profile[] = FileStore.loadProfiles(this.filesDir);
    // 旧版本只存了 id/name/link/type 四个字段，这里按分享链接补全其余字段
    const list: Profile[] = [];
    loaded.forEach((item: Profile) => {
      let p: Profile = item;
      if (p.server === undefined || p.server.length === 0) {
        try {
          p = ProxyLink.toProfile(item.link, item.id, item.subId !== undefined ? item.subId : '');
          p.name = item.name;
        } catch (err) {
        }
      }
      if (p.port === undefined) {
        p.port = 443;
      }
      if (p.delay === undefined) {
        p.delay = -1;
      }
      if (p.subId === undefined) {
        p.subId = '';
      }
      if (p.network === undefined) {
        p.network = 'tcp';
      }
      list.push(p);
    });
    this.profiles = list;
    if (list.length > 0) {
      FileStore.saveProfiles(this.filesDir, list);
    }
    if (this.profiles.length > 0 && this.selected < 0) {
      this.selected = 0;
    }
    // 分流规则：文件不存在时用默认集初始化并落盘
    const rules: RuleItem[] = FileStore.loadRules(this.filesDir);
    if (rules.length === 0) {
      this.rules = ConfigBuilder.defaultRules();
      FileStore.saveRules(this.filesDir, this.rules);
    } else {
      this.rules = rules;
    }
    // 规则订阅地址：优先用上次成功拉取过的，否则默认填内置推荐规则集
    if (this.ruleUrl.length === 0) {
      this.syncRuleUrlFromStore();
    }
  }

  seedDefaultNodes(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const raw: Uint8Array = context.resourceManager.getRawFileContentSync('nodes.txt');
      const decoder = util.TextDecoder.create('utf-8');
      const text: string = decoder.decodeToString(raw);
      if (text.trim().length === 0) {
        return;
      }
      this.linkInput = text;
      this.importFromText();
    } catch (err) {
    }
  }

  readState(): void {
    const text: string = FileStore.readText(FileStore.statePath(this.filesDir));
    if (text.length === 0) {
      this.running = false;
      return;
    }
    try {
      const state = JSON.parse(text) as CoreState;
      this.running = state.running;
      this.statusText = state.message;
      // 瞬时速率大部分时间是 0，显示累计流量对用户更有意义
      if (state.totalUp !== undefined && state.totalDown !== undefined) {
        this.trafficText = '↑' + Index.human(state.totalUp) + '  ↓' + Index.human(state.totalDown);
      } else if (state.up !== undefined && state.down !== undefined) {
        this.trafficText = '↑' + Index.human(state.up) + '  ↓' + Index.human(state.down);
      } else {
        this.trafficText = '';
      }
    } catch (err) {
    }
  }

  static human(value: number): string {
    if (value > 1048576) {
      return (value / 1048576).toFixed(1) + 'MB';
    }
    if (value > 1024) {
      return (value / 1024).toFixed(1) + 'KB';
    }
    return String(value) + 'B';
  }

  /** 名称去重：mihomo 要求代理名唯一。 */
  uniqueName(list: Profile[], wanted: string): string {
    let name: string = wanted.length > 0 ? wanted : 'node';
    let exists: boolean = list.some((item: Profile) => item.name === name);
    let seq: number = 2;
    while (exists) {
      name = wanted + ' #' + seq;
      exists = list.some((item: Profile) => item.name === name);
      seq++;
    }
    return name;
  }

  saveAll(list: Profile[]): void {
    this.profiles = list;
    FileStore.saveProfiles(this.filesDir, list);
    if (this.selected >= list.length) {
      this.selected = list.length - 1;
    }
    this.bump();
  }

  /** 触发列表重建（测速回填、选中变化等不走 saveAll 的场景）。 */
  bump(): void {
    this.stamp = this.stamp + 1;
  }

  /** 按 subId 归组：手动节点一组，每个订阅链接一组。 */
  groupList(): NodeGroup[] {
    const manual: NodeGroup = new NodeGroup();
    manual.title = '手动节点';
    const byKey: Map<string, NodeGroup> = new Map<string, NodeGroup>();
    const subs: NodeGroup[] = [];
    this.profiles.forEach((item: Profile, index: number) => {
      const key: string = item.subId !== undefined ? item.subId : '';
      if (key.length === 0) {
        manual.indices.push(index);
        return;
      }
      let group: NodeGroup | undefined = byKey.get(key);
      if (group === undefined) {
        group = new NodeGroup();
        group.key = key;
        group.title = Index.subTitle(key);
        byKey.set(key, group);
        subs.push(group);
      }
      group.indices.push(index);
    });
    const result: NodeGroup[] = [];
    if (manual.indices.length > 0) {
      this.sortIndices(manual);
      result.push(manual);
    }
    subs.forEach((item: NodeGroup) => {
      this.sortIndices(item);
      result.push(item);
    });
    return result;
  }

  /** 组内按延迟从低到高排；没测出结果（-1）的沉到组尾，其余保持原相对顺序。 */
  sortIndices(group: NodeGroup): void {
    if (!this.sortByDelay || group.indices.length < 2) {
      return;
    }
    const origin: number[] = group.indices.slice();
    group.indices.sort((a: number, b: number) => {
      const da: number = this.profiles[a].delay >= 0 ? this.profiles[a].delay : 999999;
      const db: number = this.profiles[b].delay >= 0 ? this.profiles[b].delay : 999999;
      if (da !== db) {
        return da - db;
      }
      return origin.indexOf(a) - origin.indexOf(b);
    });
  }

  /** 订阅标题：取 host[:port]，避免整条长链接把行撑爆。 */
  static subTitle(url: string): string {
    let text: string = url;
    const proto: number = text.indexOf('://');
    if (proto >= 0) {
      text = text.substring(proto + 3);
    }
    const slash: number = text.indexOf('/');
    if (slash >= 0) {
      text = text.substring(0, slash);
    }
    if (text.length === 0) {
      return '订阅';
    }
    if (text.length > 26) {
      text = text.substring(0, 26) + '…';
    }
    return '订阅 · ' + text;
  }

  /** 分组是否展开：手动组永远展开；订阅组超过 8 个节点时默认收起。 */
  groupOpen(group: NodeGroup): boolean {
    if (group.key.length === 0) {
      return true;
    }
    if (this.closedKeys.indexOf(group.key) >= 0) {
      return false;
    }
    if (this.openedKeys.indexOf(group.key) >= 0) {
      return true;
    }
    return group.indices.length <= 8;
  }

  toggleGroup(group: NodeGroup): void {
    if (group.key.length === 0) {
      return;
    }
    const open: boolean = this.groupOpen(group);
    const opened: string[] = this.openedKeys.slice();
    const closed: string[] = this.closedKeys.slice();
    if (open) {
      if (closed.indexOf(group.key) < 0) {
        closed.push(group.key);
      }
      const at: number = opened.indexOf(group.key);
      if (at >= 0) {
        opened.splice(at, 1);
      }
    } else {
      if (opened.indexOf(group.key) < 0) {
        opened.push(group.key);
      }
      const at: number = closed.indexOf(group.key);
      if (at >= 0) {
        closed.splice(at, 1);
      }
    }
    this.openedKeys = opened;
    this.closedKeys = closed;
    this.bump();
  }

  // ---------- 导入 ----------

  importFromText(): void {
    const lines: string[] = this.linkInput.split('\n');
    let added: number = 0;
    let failed: number = 0;
    const list: Profile[] = this.profiles.slice();
    lines.forEach((line: string) => {
      const text: string = line.trim();
      if (text.length === 0 || text.startsWith('//')) {
        return;
      }
      try {
        const fresh = ProxyLink.toProfile(text, String(Date.now()) + '_' + String(added), '');
        fresh.name = this.uniqueName(list, fresh.name);
        list.push(fresh);
        added++;
      } catch (err) {
        failed++;
      }
    });
    this.saveAll(list);
    this.linkInput = '';
    if (this.selected < 0 && list.length > 0) {
      this.selected = 0;
    }
    if (added > 0) {
      this.drawerOpen = false;
      this.toast.showToast({ message: '导入 ' + added + ' 个节点' });
    } else {
      this.toast.showToast({ message: '未识别到节点（失败 ' + failed + ' 行）' });
    }
    this.reconnectSoon();
  }

  importFromClipboard(): void {
    const board = pasteboard.getSystemPasteboard();
    board.getData().then((data: pasteboard.PasteData) => {
      this.linkInput = data.getPrimaryText();
      this.importFromText();
    }).catch(() => {
      this.toast.showToast({ message: '剪贴板为空' });
    });
  }

  async httpGet(url: string, timeoutMs: number): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING,
        header: { 'User-Agent': 'v2rayNG-harmony/1.0' }
      });
      if (resp.responseCode !== 200) {
        hilog.error(0x0001, 'V2rayNG-UI', 'httpGet code=%{public}d url=%{public}s', resp.responseCode, url);
        return '';
      }
      // 某些版本 result 会是 ArrayBuffer，直接 String() 只会得到 "[object ArrayBuffer]"
      const raw: string | ArrayBuffer = resp.result as string | ArrayBuffer;
      if (typeof raw === 'string') {
        return raw as string;
      }
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(raw as ArrayBuffer));
    } catch (err) {
      const be = err as BusinessError;
      hilog.error(0x0001, 'V2rayNG-UI', 'httpGet fail code=%{public}d msg=%{public}s url=%{public}s',
        be.code !== undefined ? be.code : -1, String(be.message), url);
      return '';
    } finally {
      req.destroy();
    }
  }

  /**
   * 把订阅内容合并进列表：同源先清空再逐个解析，返回新增节点数；-1 表示内容无法解析。
   */
  applySubContent(url: string, body: string): number {
    let content: string = body;
    if (!content.includes('://')) {
      try {
        content = ProxyLink.decodeBase64(content);
      } catch (err) {
        return -1;
      }
    }
    const list: Profile[] = this.profiles.filter((item: Profile) => item.subId !== url).slice();
    const baseId: string = String(Date.now()) + '_' + Index.subSeq();
    let added: number = 0;
    content.split('\n').forEach((line: string) => {
      const text: string = line.trim();
      if (text.length === 0) {
        return;
      }
      try {
        const fresh = ProxyLink.toProfile(text, baseId + '_' + String(added), url);
        fresh.name = this.uniqueName(list, fresh.name);
        list.push(fresh);
        added++;
      } catch (err) {
      }
    });
    this.saveAll(list);
    return added;
  }

  /** 订阅导入序号：同一毫秒内多次导入也不会撞 id。 */
  static subSeqSeed: number = 0;
  static subSeq(): number {
    Index.subSeqSeed = Index.subSeqSeed + 1;
    return Index.subSeqSeed;
  }

  /** 订阅导入：支持 base64 或明文的一行一个分享链接，重导时覆盖同源节点。 */
  async importSubscription(): Promise<void> {
    const url: string = this.subInput.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      this.toast.showToast({ message: '请填写 http(s) 订阅链接' });
      return;
    }
    this.statusText = '正在拉取订阅…';
    const body: string = await this.httpGet(url, 15000);
    if (body.trim().length === 0) {
      this.toast.showToast({ message: '订阅拉取失败，检查链接或网络' });
      this.statusText = this.running ? '已连接' : '未连接';
      return;
    }
    const added: number = this.applySubContent(url, body);
    this.statusText = this.running ? '已连接' : '未连接';
    if (added < 0) {
      this.toast.showToast({ message: '订阅内容无法解析（非 base64 也非链接）' });
      return;
    }
    this.drawerOpen = false;
    this.toast.showToast({ message: '订阅导入 ' + added + ' 个节点' });
    this.reconnectSoon();
  }

  /** 单个订阅分组更新：只刷新这个订阅的节点，其它分组不动。 */
  async refreshGroup(url: string): Promise<void> {
    this.statusText = '正在更新订阅…';
    const body: string = await this.httpGet(url, 15000);
    if (body.trim().length === 0) {
      this.toast.showToast({ message: '订阅更新失败，检查网络' });
      this.statusText = this.running ? '已连接' : '未连接';
      return;
    }
    const added: number = this.applySubContent(url, body);
    this.statusText = this.running ? '已连接' : '未连接';
    if (added < 0) {
      this.toast.showToast({ message: '订阅内容无法解析' });
      return;
    }
    this.toast.showToast({ message: '已更新 ' + added + ' 个节点' });
    this.reconnectSoon();
  }

  /** 单个分组测速：只测这一组的节点。 */
  async testGroup(group: NodeGroup): Promise<void> {
    if (!this.running) {
      this.toast.showToast({ message: '请先连接，内核起来后才能测速' });
      return;
    }
    if (this.testing) {
      return;
    }
    this.testing = true;
    this.testDone = 0;
    this.testTotal = group.indices.length;
    this.testInfo = '已测 0 · 待测 ' + String(this.testTotal);
    this.bump();
    await this.runPool(group.indices, Index.TEST_CONCURRENCY);
    this.testing = false;
    this.testInfo = '';
    this.sortByDelay = true;
    this.bump();
    this.toast.showToast({ message: '本组测速完成，已按延迟排序' });
  }

  /** 测速并发上限：内核侧是 goroutine，这里控制同时排队请求数。 */
  static TEST_CONCURRENCY: number = 16;

  /** 并发池：固定 concurrency 个 worker 从队列里取节点去测，测完更新进度。 */
  async runPool(indices: number[], concurrency: number): Promise<void> {
    const cursor: number[] = [0];
    const worker = async (): Promise<void> => {
      while (true) {
        const at: number = cursor[0];
        cursor[0] = cursor[0] + 1;
        if (at >= indices.length) {
          return;
        }
        await this.testOne(indices[at]);
        this.testDone = this.testDone + 1;
        this.testInfo = '已测 ' + String(this.testDone) + ' · 待测 ' +
          String(this.testTotal - this.testDone);
        this.bump();
      }
    };
    const workers: Promise<void>[] = [];
    const count: number = Math.min(concurrency, indices.length);
    for (let w = 0; w < count; w++) {
      workers.push(worker());
    }
    await Promise.all(workers);
  }

  // ---------- 节点操作 ----------

  removeProfile(index: number): void {
    const list: Profile[] = this.profiles.slice();
    list.splice(index, 1);
    this.saveAll(list);
    if (this.selected >= list.length) {
      this.selected = list.length - 1;
    }
    this.toast.showToast({ message: '已删除' });
    this.reconnectSoon();
  }

  openEdit(index: number): void {
    const p: Profile = this.profiles[index];
    this.editing = index;
    this.editNew = false;
    this.eName = p.name;
    this.eType = p.type;
    this.eServer = p.server;
    this.ePort = String(p.port);
    this.eUuid = p.uuid;
    this.ePassword = p.password;
    this.eCipher = p.cipher;
    this.eNetwork = p.network;
    this.eTls = p.tls;
    this.eSni = p.sni;
    this.ePath = p.wsPath;
    this.eHost = p.wsHost;
  }

  addNew(): void {
    this.editing = this.profiles.length;
    this.editNew = true;
    this.eName = '';
    this.eType = 'vless';
    this.eServer = '';
    this.ePort = '443';
    this.eUuid = '';
    this.ePassword = '';
    this.eCipher = '';
    this.eNetwork = 'ws';
    this.eTls = true;
    this.eSni = '';
    this.ePath = '';
    this.eHost = '';
  }

  closeEdit(): void {
    this.editing = -1;
    this.editNew = false;
  }

  saveEdit(): void {
    if (this.eServer.trim().length === 0) {
      this.toast.showToast({ message: '服务器地址不能为空' });
      return;
    }
    const port: number = Number.parseInt(this.ePort);
    if (port <= 0 || port > 65535) {
      this.toast.showToast({ message: '端口需在 1-65535' });
      return;
    }
    const isNew: boolean = this.editNew;
    const list: Profile[] = this.profiles.slice();
    let p: Profile;
    if (isNew) {
      p = new Profile();
      p.id = String(Date.now());
      p.subId = '';
      list.push(p);
    } else {
      p = list[this.editing];
    }
    p.type = this.eType;
    p.server = this.eServer.trim();
    p.port = port;
    p.uuid = this.eUuid.trim();
    p.password = this.ePassword;
    p.cipher = this.eCipher.trim();
    p.network = this.eNetwork;
    p.tls = this.eTls;
    p.sni = this.eSni.trim();
    p.wsPath = this.ePath;
    p.wsHost = this.eHost.trim();
    p.delay = -1;
    const wanted: string = this.eName.trim().length > 0 ? this.eName.trim() : (p.server + ':' + p.port);
    if (isNew) {
      p.name = this.uniqueName(list.slice(0, list.length - 1), wanted);
      if (this.selected < 0) {
        this.selected = list.length - 1;
      }
    } else {
      p.name = wanted;
    }
    this.saveAll(list);
    this.closeEdit();
    this.toast.showToast({ message: isNew ? '已添加节点' : '已保存修改' });
    this.reconnectSoon();
  }

  /**
   * 测速：走内核 REST API，让内核真实经该节点请求一次 generate_204，返回毫秒。
   * 注意：必须先连接（内核起来后 9090 才有服务）。
   */
  async testOne(index: number): Promise<void> {
    if (!this.running) {
      this.toast.showToast({ message: '请先连接，内核起来后才能测速' });
      return;
    }
    const name: string = this.profiles[index].name;
    // 界面进程与内核进程不在同一网络命名空间，访问不到 9090，
    // 所以把请求写文件交给扩展进程执行，再轮询结果文件。
    // 并发测速：每个 seq 一对独立文件（delay/req_<seq>.json / res_<seq>.json），互不覆盖。
    // seq 必须落在 int32 内：跨 NAPI 传的是 32 位整数
    const seq: number = Index.nextSeq();
    const req: DelayReq = { seq: seq, name: name, url: TEST_URL };
    const reqFile: string = FileStore.delayReqFile(this.filesDir, seq);
    const resFile: string = FileStore.delayResFile(this.filesDir, seq);
    FileStore.writeText(reqFile, JSON.stringify(req));
    let delay: number = -1;
    // 远节点握手慢，最多等 30 秒（60 × 500ms）
    for (let i = 0; i < 60; i++) {
      await Index.sleep(500);
      const text: string = FileStore.readText(resFile);
      if (text.length === 0) {
        continue;
      }
      try {
        const res = JSON.parse(text) as DelayRes;
        if (res.seq === seq) {
          delay = res.delay !== undefined ? res.delay : -1;
          break;
        }
      } catch (err) {
      }
    }
    FileStore.removeFile(reqFile);
    FileStore.removeFile(resFile);
    this.profiles[index].delay = delay;
    this.profiles = this.profiles.slice();
  }

  static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 测速请求序号：32 位整数内自增，避免 Date.now() 超出 int32 被截断。 */
  static seqSeed: number = 0;
  static nextSeq(): number {
    Index.seqSeed = Index.seqSeed + 1;
    if (Index.seqSeed > 2000000000) {
      Index.seqSeed = 1;
    }
    return Index.seqSeed;
  }

  async testAll(): Promise<void> {
    if (!this.running) {
      this.toast.showToast({ message: '请先连接，内核起来后才能测速' });
      return;
    }
    this.testing = true;
    this.testDone = 0;
    this.testTotal = this.profiles.length;
    this.testInfo = '已测 0 · 待测 ' + String(this.testTotal);
    this.bump();
    const all: number[] = [];
    for (let i = 0; i < this.profiles.length; i++) {
      all.push(i);
    }
    await this.runPool(all, Index.TEST_CONCURRENCY);
    this.testing = false;
    this.testInfo = '';
    this.sortByDelay = true;
    this.bump();
    this.toast.showToast({ message: '测速完成，已按延迟排序' });
  }

  /** 代理名可能含中文，URL 里必须做百分号编码。 */
  static urlEncode(text: string): string {
    const encoder = new util.TextEncoder();
    const bytes: Uint8Array = encoder.encodeInto(text);
    const unreserved: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~';
    let out: string = '';
    for (let i = 0; i < bytes.length; i++) {
      const b: number = bytes[i];
      const ch: string = String.fromCharCode(b);
      if (b < 128 && unreserved.indexOf(ch) >= 0) {
        out += ch;
      } else {
        const hex: string = b.toString(16).toUpperCase();
        out += '%' + (hex.length === 1 ? '0' + hex : hex);
      }
    }
    return out;
  }

  static delayText(value: number): string {
    if (value === undefined || value === null || value < 0) {
      return '—';
    }
    return String(value) + ' ms';
  }

  // ---------- 分流规则 ----------

  openRules(): void {
    this.ruleEditing = -1;
    this.rulePanel = true;
    this.drawerOpen = false;
    this.syncRuleUrlFromStore();
  }

  /** 地址栏内容：优先用上次保存/拉取过的地址，没有地址就回落内置推荐规则集。 */
  syncRuleUrlFromStore(): void {
    let last: string = '';
    try {
      last = FileStore.readText2(this.filesDir, 'rules-src.txt').trim();
    } catch (err) {
      last = '';
    }
    this.ruleUrl = last.length > 0 ? last : BUILTIN_RULE_SRC;
  }

  /** 把地址栏落盘：只认框里的 http(s) 地址，没有地址（内置/删空）就写空串，下次打开回落默认。 */
  saveRuleSrcFromInput(): void {
    const value: string = this.ruleUrl.trim();
    const hit: RegExpMatchArray | null = value.match(/https?:\/\/[^\s"'<>]+/);
    const store: string = (hit !== null && hit.length > 0) ? hit[0] : '';
    try {
      FileStore.writeText2(this.filesDir, 'rules-src.txt', store);
    } catch (err) {
    }
  }

  saveRulesNow(): void {
    FileStore.saveRules(this.filesDir, this.rules);
    this.saveRuleSrcFromInput();
    this.reconnectSoon();
    this.toast.showToast({ message: '规则已保存' });
  }

  /** 一键还原成内置默认规则集（改乱了可以重来），地址栏也回到内置源。 */
  resetRules(): void {
    this.rules = ConfigBuilder.defaultRules();
    this.rulesLimit = 50;
    this.ruleUrl = BUILTIN_RULE_SRC;
    this.saveRuleSrcFromInput();
    FileStore.saveRules(this.filesDir, this.rules);
    this.ruleMsg = '已恢复默认 ' + String(this.rules.length) + ' 条规则';
    this.reconnectSoon();
    this.toast.showToast({ message: '已恢复默认规则集' });
  }

  private replaceRule(index: number, next: RuleItem): void {
    const list: RuleItem[] = this.rules.slice();
    list[index] = next;
    this.rules = list;
  }

  toggleRule(index: number): void {
    this.replaceRule(index, {
      id: this.rules[index].id,
      title: this.rules[index].title,
      kind: this.rules[index].kind,
      value: this.rules[index].value,
      target: this.rules[index].target,
      enabled: !this.rules[index].enabled
    });
  }

  cycleTarget(index: number): void {
    const current: string = this.rules[index].target;
    const next: string = current === 'DIRECT' ? 'PROXY' : (current === 'PROXY' ? 'REJECT' : 'DIRECT');
    this.replaceRule(index, {
      id: this.rules[index].id,
      title: this.rules[index].title,
      kind: this.rules[index].kind,
      value: this.rules[index].value,
      target: next,
      enabled: this.rules[index].enabled
    });
  }

  removeRule(index: number): void {
    const list: RuleItem[] = this.rules.slice();
    list.splice(index, 1);
    this.rules = list;
  }

  openRuleEdit(index: number): void {
    const rule: RuleItem = this.rules[index];
    this.ruleEditing = index;
    this.rTitle = rule.title;
    this.rKind = rule.kind;
    this.rValue = rule.value;
    this.rTarget = rule.target;
  }

  newRule(): void {
    this.ruleEditing = this.rules.length;
    this.rTitle = '';
    this.rKind = 'DOMAIN-SUFFIX';
    this.rValue = '';
    this.rTarget = 'PROXY';
  }

  closeRuleEdit(): void {
    this.ruleEditing = -1;
  }

  saveRuleEdit(): void {
    const kind: string = this.rKind;
    const value: string = kind === 'MATCH' ? '' :
      ConfigBuilder.safeValue(kind, this.rValue);
    if (kind !== 'MATCH' && value.length === 0) {
      this.toast.showToast({ message: '请填写规则内容' });
      return;
    }
    const title: string = this.rTitle.trim().length > 0 ? this.rTitle.trim() :
      kind + ' ' + (value.length > 0 ? value : this.rTarget);
    const rule: RuleItem = {
      id: 'u_' + String(Date.now()),
      title: title,
      kind: kind,
      value: value,
      target: this.rTarget,
      enabled: true
    };
    if (this.ruleEditing < this.rules.length) {
      rule.id = this.rules[this.ruleEditing].id;
      rule.enabled = this.rules[this.ruleEditing].enabled;
      this.replaceRule(this.ruleEditing, rule);
    } else {
      const list: RuleItem[] = this.rules.slice();
      list.push(rule);
      this.rules = list;
    }
    this.ruleEditing = -1;
  }

  /** 导出当前规则集为 JSON，便于备份或换机导入。 */
  async exportRulesToFile(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const doc = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = ['v2rayng-rules-' + String(Date.now()) + '.json'];
      const uris: string[] = await doc.save(options);
      if (uris.length === 0) {
        return;
      }
      const content: string = JSON.stringify(this.rules, null, 2);
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.writeSync(file.fd, content);
      fileIo.closeSync(file);
      this.ruleMsg = '已导出 ' + String(this.rules.length) + ' 条规则到文件';
      this.toast.showToast({ message: '已导出规则文件' });
    } catch (err) {
      this.ruleMsg = '导出失败：' + String(err);
      this.toast.showToast({ message: '导出失败：' + String(err) });
    }
  }

  /** 文件导入：整份规则集覆盖当前规则。 */
  async importRulesFromFile(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const doc = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const uris: string[] = await doc.select(options);
      if (uris.length === 0) {
        return;
      }
      const text: string = Index.readUriText(uris[0]);
      const parsed: RuleItem[] = ConfigBuilder.parseRules(text, Index.targetHintFromUrl(uris[0]));
      if (parsed.length === 0) {
        this.ruleMsg = '文件里没有识别到分流规则';
        this.toast.showToast({ message: '文件里没有识别到分流规则' });
        return;
      }
      this.rules = parsed;
      this.rulesLimit = 50;
      FileStore.saveRules(this.filesDir, this.rules);
      this.ruleMsg = '已从文件导入 ' + String(parsed.length) + ' 条规则';
      this.reconnectSoon();
      this.toast.showToast({ message: '已导入 ' + parsed.length + ' 条规则' });
    } catch (err) {
      this.ruleMsg = '文件导入失败：' + String(err);
      this.toast.showToast({ message: '文件导入失败：' + String(err) });
    }
  }

  /** 地址栏回车也触发更新，键盘遮挡时少一步 */
  async importRulesFromUrl(): Promise<void> {
    let url: string = this.ruleUrl.trim();
    // 先抠出真正的 URL：输入法或自动化注入会把地址粘在内置值后面
    const hit: RegExpMatchArray | null = url.match(/https?:\/\/[^\s"'<>]+/);
    if (hit !== null && hit.length > 0) {
      url = hit[0];
    } else if (url.toLowerCase().startsWith('builtin:')) {
      // 没有 URL、只有内置标记：等于还原内置推荐规则集
      this.resetRules();
      this.ruleMsg = '已应用内置推荐规则集 ' + String(this.rules.length) + ' 条';
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      this.ruleMsg = '请先填写 http(s) 规则订阅地址';
      this.toast.showToast({ message: '请先填写 http(s) 规则订阅地址' });
      return;
    }
    this.ruleMsg = '正在拉取 ' + url;
    const body: string = await this.httpGet(url, 15000);
    hilog.info(0x0000, 'V2rayNG-UI', 'rule url %{public}s body=%{public}d', url, body.length);
    if (body.trim().length === 0) {
      this.ruleMsg = '拉取失败：没有收到内容（HTTP 未返回或链接不可达）';
      this.toast.showToast({ message: '规则拉取失败，检查链接或网络' });
      return;
    }
    const parsed: RuleItem[] = ConfigBuilder.parseRules(body, Index.targetHintFromUrl(url));
    hilog.info(0x0000, 'V2rayNG-UI', 'rule parsed=%{public}d', parsed.length);
    if (parsed.length === 0) {
      const head: string = body.substring(0, Math.min(40, body.length)).replace(/\s+/g, ' ');
      this.ruleMsg = '返回 ' + String(body.length) + ' 字节但无规则：' + head;
      this.toast.showToast({ message: '订阅内容里没有识别到分流规则' });
      return;
    }
    this.rules = parsed;
    this.rulesLimit = 50;
    this.ruleUrl = url; // 把地址栏规范成真正用到的地址
    FileStore.saveRules(this.filesDir, this.rules);
    FileStore.writeText2(this.filesDir, 'rules-src.txt', url);
    this.ruleMsg = '已更新 ' + String(parsed.length) + ' 条规则';
    this.reconnectSoon();
    this.toast.showToast({ message: '已从网址更新 ' + parsed.length + ' 条规则' });
  }

  /** 按地址判断清单方向：reject/ban 类给 REJECT，direct/private/china 类给 DIRECT，其余给 PROXY。 */
  static targetHintFromUrl(url: string): string {
    const lower: string = url.toLowerCase();
    const name: string = lower.substring(lower.lastIndexOf('/') + 1);
    if (name.indexOf('reject') >= 0 || name.indexOf('ban') >= 0) {
      return 'REJECT';
    }
    if (name.indexOf('direct') >= 0 || name.indexOf('private') >= 0 || name.indexOf('lan') >= 0 ||
      name.indexOf('china') >= 0) {
      return 'DIRECT';
    }
    return 'PROXY';
  }

  static readUriText(uri: string): string {
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(uri);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer));
    } catch (err) {
      return '';
    }
  }

  // ---------- 连接 ----------

  async connect(): Promise<void> {
    if (this.running) {
      await this.disconnect();
      return;
    }
    if (this.selected < 0 || this.selected >= this.profiles.length) {
      this.toast.showToast({ message: '请先选择一个节点' });
      return;
    }
    try {
      const config: string = ConfigBuilder.build(this.profiles, this.selected, this.rules);
      FileStore.writeText(FileStore.configPath(this.filesDir), config);
      const want: Want = {
        bundleName: BUNDLE_NAME,
        abilityName: EXT_ABILITY
      };
      await vpnExtension.startVpnExtensionAbility(want);
      this.statusText = '正在启动内核…';
    } catch (err) {
      const message: string = String(err);
      this.toast.showToast({ message: '启动失败：' + message });
      this.statusText = message;
    }
  }

  async disconnect(): Promise<void> {
    try {
      const want: Want = {
        bundleName: BUNDLE_NAME,
        abilityName: EXT_ABILITY
      };
      await vpnExtension.stopVpnExtensionAbility(want);
      this.running = false;
      this.statusText = '未连接';
      this.trafficText = '';
    } catch (err) {
      this.toast.showToast({ message: '断开失败：' + String(err) });
    }
  }

  /**
   * 节点增删改后：内核只在启动时读一次配置，所以连接中改动要自动重连才生效。
   */
  private reconnectSoon(): void {
    if (!this.running || this.reconnecting) {
      return;
    }
    this.reconnecting = true;
    this.statusText = '配置已变更，正在重连…';
    this.disconnect().then(() => {
      return Index.sleep(1500);
    }).then(() => {
      this.reconnecting = false;
      return this.connect();
    }).catch(() => {
      this.reconnecting = false;
    });
  }

  // ---------- UI ----------
  @Builder
  field(label: string, value: string, onChange: (v: string) => void) {
    Row({ space: 8 }) {
      Text(label).fontSize(13).width(76).fontColor('#666666')
      TextInput({ text: value })
        .layoutWeight(1)
        .height(38)
        .fontSize(13)
        .onChange((v: string) => {
          onChange(v);
        })
    }.width('100%')
  }

  @Builder
  chip(label: string, current: string, onTap: () => void) {
    Text(label)
      .fontSize(13)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(8)
      .backgroundColor(current === label ? '#EAF1FF' : '#F2F2F2')
      .fontColor(current === label ? '#0A59F7' : '#333333')
      .onClick(onTap)
  }

  @Builder
  editPanel() {
    Column({ space: 10 }) {
      Text(this.editNew ? '添加节点' : '编辑节点').fontSize(19).fontWeight(FontWeight.Bold)

      Scroll() {
        Column({ space: 8 }) {
          this.field('名称', this.eName, (v: string) => { this.eName = v; })
          Row({ space: 8 }) {
            Text('协议').fontSize(13).width(76).fontColor('#666666')
            Row({ space: 8 }) {
              this.chip('vless', this.eType, () => { this.eType = 'vless'; })
              this.chip('vmess', this.eType, () => { this.eType = 'vmess'; })
              this.chip('trojan', this.eType, () => { this.eType = 'trojan'; })
              this.chip('ss', this.eType, () => { this.eType = 'ss'; })
            }.layoutWeight(1)
          }.width('100%')

          this.field('服务器', this.eServer, (v: string) => { this.eServer = v; })
          this.field('端口', this.ePort, (v: string) => { this.ePort = v; })
          if (this.eType === 'vless' || this.eType === 'vmess') {
            this.field('UUID', this.eUuid, (v: string) => { this.eUuid = v; })
          }
          if (this.eType === 'trojan' || this.eType === 'ss') {
            this.field('密码', this.ePassword, (v: string) => { this.ePassword = v; })
          }
          if (this.eType === 'ss') {
            this.field('加密方式', this.eCipher, (v: string) => { this.eCipher = v; })
          }

          Row({ space: 8 }) {
            Text('传输').fontSize(13).width(76).fontColor('#666666')
            Row({ space: 8 }) {
              this.chip('tcp', this.eNetwork, () => { this.eNetwork = 'tcp'; })
              this.chip('ws', this.eNetwork, () => { this.eNetwork = 'ws'; })
              this.chip('grpc', this.eNetwork, () => { this.eNetwork = 'grpc'; })
            }.layoutWeight(1)
          }.width('100%')

          Row({ space: 8 }) {
            Text('TLS').fontSize(13).width(76).fontColor('#666666')
            Toggle({ type: ToggleType.Switch, isOn: this.eTls })
              .onChange((on: boolean) => {
                this.eTls = on;
              })
          }.width('100%')

          if (this.eTls) {
            this.field('SNI', this.eSni, (v: string) => { this.eSni = v; })
          }
          if (this.eNetwork === 'ws') {
            this.field('WS 路径', this.ePath, (v: string) => { this.ePath = v; })
            this.field('WS Host', this.eHost, (v: string) => { this.eHost = v; })
          }
        }.width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)

      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).height(40).fontSize(15)
          .backgroundColor('#F0F0F0').fontColor('#333333')
          .onClick(() => {
            this.closeEdit();
          })
        Button('保存').layoutWeight(1).height(40).fontSize(15)
          .onClick(() => {
            this.saveEdit();
          })
      }.width('100%')
    }
    .padding(16)
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  groupHeader(group: NodeGroup) {
    Row({ space: 10 }) {
      Text(group.key.length > 0 ? (this.groupOpen(group) ? '▾ ' : '▸ ') + group.title : group.title)
        .fontSize(12)
        .fontColor('#8A8A8A')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick(() => {
          this.toggleGroup(group);
        })
      Text(String(group.indices.length) + ' 个')
        .fontSize(11)
        .fontColor('#B0B0B0')
        .onClick(() => {
          this.toggleGroup(group);
        })
      if (group.key.length > 0) {
        Text('更新').fontSize(12).fontColor('#0A59F7')
          .onClick(() => {
            this.refreshGroup(group.key);
          })
      }
      Text('测速').fontSize(12).fontColor('#0A59F7')
        .onClick(() => {
          this.testGroup(group);
        })
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4, bottom: 2 })
  }

  @Builder
  nodeRow(index: number) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(this.profiles[index].name).fontSize(15).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.profiles[index].type.toUpperCase() + ' · ' + this.profiles[index].server + ':' +
          String(this.profiles[index].port))
          .fontSize(11).fontColor('#8A8A8A').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        this.selected = index;
        this.bump();
      })

      Text(Index.delayText(this.profiles[index].delay))
        .fontSize(12)
        .fontColor(this.profiles[index].delay >= 0 && this.profiles[index].delay < 1500 ? '#2E7D32' : '#8A8A8A')
        .onClick(() => {
          this.testOne(index);
        })

      if (index === this.selected) {
        Text('✓').fontSize(16).fontColor('#0A59F7')
      }

      Text('编辑').fontSize(12).fontColor('#0A59F7').padding({ left: 4, right: 4 })
        .onClick(() => {
          this.openEdit(index);
        })
      Text('删除').fontSize(12).fontColor('#E84026').padding({ left: 4, right: 4 })
        .onClick(() => {
          this.removeProfile(index);
        })
    }
    .width('100%')
    .padding(10)
    .borderRadius(10)
    .backgroundColor(index === this.selected ? '#EAF1FF' : '#F5F5F5')
  }

  @Builder
  drawer() {
    Row() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text('订阅与导入').fontSize(18).fontWeight(FontWeight.Bold)
            Text('按订阅分组 · 可单独更新/测速').fontSize(11).fontColor('#8A8A8A')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)

          Button('关闭')
            .fontSize(12)
            .height(32)
            .width(64)
            .padding({ left: 0, right: 0 })
            .backgroundColor('#F0F0F0')
            .fontColor('#333333')
            .onClick(() => {
              this.drawerOpen = false;
            })
        }.width('100%')

        TextInput({ text: this.subInput, placeholder: '订阅链接 https://…' })
          .width('100%')
          .height(40)
          .fontSize(13)
          .onChange((v: string) => {
            this.subInput = v;
          })

        Button('从订阅链接导入')
          .width('100%')
          .height(40)
          .fontSize(14)
          .onClick(() => {
            this.importSubscription();
          })

        Text('单条链接').fontSize(12).fontColor('#8A8A8A')

        TextArea({ text: this.linkInput, placeholder: '粘贴 vmess:// vless:// ss:// trojan:// 链接，一行一个' })
          .width('100%')
          .height(110)
          .fontSize(12)
          .onChange((value: string) => {
            this.linkInput = value;
          })

        Row({ space: 10 }) {
          Button('剪贴板导入').layoutWeight(1).height(36).fontSize(13)
            .backgroundColor('#F0F0F0').fontColor('#333333')
            .onClick(() => {
              this.importFromClipboard();
            })
          Button('解析导入').layoutWeight(1).height(36).fontSize(13)
            .onClick(() => {
              this.importFromText();
            })
        }.width('100%')

        Text('导入后写进 core.yaml；连接状态下自动重连生效。')
          .fontSize(11)
          .fontColor('#8A8A8A')

        Button('设置 · 分流规则')
          .width('100%')
          .height(40)
          .fontSize(14)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.openRules();
          })

        Blank()
      }
      .width('72%')
      .height('100%')
      .padding(16)
      .backgroundColor('#FFFFFF')
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
      })

      Column()
        .layoutWeight(1)
        .height('100%')
        .onClick(() => {
          this.drawerOpen = false;
        })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  rulesPanel() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Button('返回')
          .width(72)
          .height(34)
          .fontSize(13)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.saveRuleSrcFromInput();
            this.rulePanel = false;
            this.ruleEditing = -1;
          })
        Text('分流规则')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button('保存')
          .width(80)
          .height(34)
          .fontSize(13)
          .onClick(() => {
            this.saveRulesNow();
          })
      }.width('100%')

      Text('从上到下逐条匹配，命中即停；地址栏默认内置推荐规则集，换成自己的规则订阅网址后会记住。')
        .fontSize(11)
        .fontColor('#8A8A8A')
        .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.ruleUrl, placeholder: '内置推荐规则集 / 规则订阅地址 https://…' })
          .layoutWeight(1)
          .height(38)
          .fontSize(12)
          .enterKeyType(EnterKeyType.Go)
          .onChange((v: string) => {
            this.ruleUrl = v;
          })
          .onSubmit((key: EnterKeyType) => {
            this.importRulesFromUrl();
          })
        Button('网址更新')
          .width(128)
          .height(38)
          .fontSize(13)
          .onClick(() => {
            this.importRulesFromUrl();
          })
      }.width('100%')

      Row({ space: 8 }) {
        Button('文件导入')
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.importRulesFromFile();
          })
        Button('导出规则')
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.exportRulesToFile();
          })
      }.width('100%')

      Text(this.ruleMsg.length > 0 ? this.ruleMsg : '手动改规则后点右上角「保存」；也可以整份从文件或网址覆盖')
        .fontSize(11)
        .fontColor(this.ruleMsg.length > 0 ? '#0A59F7' : '#8A8A8A')
        .maxLines(2)
        .width('100%')

      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.rules.slice(0, this.rulesLimit), (rule: RuleItem, index: number) => {
            Row({ space: 8 }) {
              Toggle({ type: ToggleType.Switch, isOn: rule.enabled })
                .onChange((isOn: boolean) => {
                  this.toggleRule(index);
                })
              Column({ space: 2 }) {
                Text(rule.title)
                  .fontSize(14)
                  .fontColor(rule.enabled ? '#222222' : '#AAAAAA')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(rule.kind + (rule.value.length > 0 ? ',' + rule.value : '') + ',' + rule.target)
                  .fontSize(11)
                  .fontColor('#8A8A8A')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)

              Text(rule.target)
                .fontSize(11)
                .fontColor(rule.target === 'DIRECT' ? '#2E7D32' :
                  (rule.target === 'PROXY' ? '#0A59F7' : '#E84026'))
                .backgroundColor('#FFFFFF')
                .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                .borderRadius(8)
                .onClick(() => {
                  this.cycleTarget(index);
                })

              Text('编辑')
                .fontSize(12)
                .fontColor('#0A59F7')
                .onClick(() => {
                  this.openRuleEdit(index);
                })
              Text('删除')
                .fontSize(12)
                .fontColor('#E84026')
                .onClick(() => {
                  this.removeRule(index);
                })
            }
            .width('100%')
            .padding(10)
            .backgroundColor('#F7F7F7')
            .borderRadius(10)
          }, (rule: RuleItem, index: number) => rule.id + '|' + rule.kind + '|' + rule.value + '|' +
            rule.target + '|' + (rule.enabled ? '1' : '0') + '|' + rule.title)

          if (this.rules.length > this.rulesLimit) {
            Button('再显示 50 条（共 ' + String(this.rules.length) + ' 条）')
              .width('100%')
              .height(36)
              .fontSize(13)
              .backgroundColor('#EAF1FF')
              .fontColor('#0A59F7')
              .onClick(() => {
                this.rulesLimit = this.rulesLimit + 50;
              })
          }

          Button('恢复默认规则集')
            .width('100%')
            .height(36)
            .fontSize(13)
            .backgroundColor('#FFF4F2')
            .fontColor('#E84026')
            .onClick(() => {
              this.resetRules();
            })

          Button('+ 添加规则')
            .width('100%')
            .height(36)
            .fontSize(13)
            .backgroundColor('#F0F0F0')
            .fontColor('#333333')
            .onClick(() => {
              this.newRule();
            })
        }.width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
    }
    .padding(12)
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  @Builder
  ruleEditPanel() {
    Column() {
      Scroll() {
        Column({ space: 10 }) {
          Text('规则编辑').fontSize(18).fontWeight(FontWeight.Bold).width('100%')

      Row({ space: 8 }) {
        Text('名称').fontSize(13).width(52)
        TextInput({ text: this.rTitle, placeholder: '显示名，如「代理 Google」' })
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .onChange((v: string) => {
            this.rTitle = v;
          })
      }.width('100%')

      Text('类型').fontSize(13).width('100%')
      Row({ space: 8 }) {
        Button('GEOSITE').layoutWeight(1).height(34).fontSize(12)
          .backgroundColor(this.rKind === 'GEOSITE' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rKind === 'GEOSITE' ? '#FFFFFF' : '#333333')
          .padding(0)
          .onClick(() => {
            this.rKind = 'GEOSITE';
          })
        Button('GEOIP').layoutWeight(1).height(34).fontSize(12)
          .backgroundColor(this.rKind === 'GEOIP' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rKind === 'GEOIP' ? '#FFFFFF' : '#333333')
          .padding(0)
          .onClick(() => {
            this.rKind = 'GEOIP';
          })
        Button('DOMAIN').layoutWeight(1).height(34).fontSize(12)
          .backgroundColor(this.rKind === 'DOMAIN-SUFFIX' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rKind === 'DOMAIN-SUFFIX' ? '#FFFFFF' : '#333333')
          .padding(0)
          .onClick(() => {
            this.rKind = 'DOMAIN-SUFFIX';
          })
        Button('IP-CIDR').layoutWeight(1).height(34).fontSize(12)
          .backgroundColor(this.rKind === 'IP-CIDR' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rKind === 'IP-CIDR' ? '#FFFFFF' : '#333333')
          .padding(0)
          .onClick(() => {
            this.rKind = 'IP-CIDR';
          })
        Button('MATCH').layoutWeight(1).height(34).fontSize(12)
          .backgroundColor(this.rKind === 'MATCH' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rKind === 'MATCH' ? '#FFFFFF' : '#333333')
          .padding(0)
          .onClick(() => {
            this.rKind = 'MATCH';
          })
      }.width('100%')
      Text('GEOSITE 域名库 / GEOIP IP 库 / DOMAIN 单个域名 / IP-CIDR 网段 / MATCH 兜底')
        .fontSize(10)
        .fontColor('#AAAAAA')
        .width('100%')

      Row({ space: 8 }) {
        Text('内容').fontSize(13).width(52)
        TextInput({ text: this.rValue, placeholder: 'cn / CN / google.com / 10.0.0.0/8' })
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .enabled(this.rKind !== 'MATCH')
          .onChange((v: string) => {
            this.rValue = v;
          })
      }.width('100%')

      Text('策略').fontSize(13).width('100%')
      Row({ space: 8 }) {
        Button('直连 DIRECT').layoutWeight(1).height(34).fontSize(12)
          .backgroundColor(this.rTarget === 'DIRECT' ? '#2E7D32' : '#F0F0F0')
          .fontColor(this.rTarget === 'DIRECT' ? '#FFFFFF' : '#333333')
          .onClick(() => {
            this.rTarget = 'DIRECT';
          })
        Button('代理 PROXY').layoutWeight(1).height(34).fontSize(12)
          .backgroundColor(this.rTarget === 'PROXY' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rTarget === 'PROXY' ? '#FFFFFF' : '#333333')
          .onClick(() => {
            this.rTarget = 'PROXY';
          })
        Button('阻断 REJECT').layoutWeight(1).height(34).fontSize(12)
          .backgroundColor(this.rTarget === 'REJECT' ? '#E84026' : '#F0F0F0')
          .fontColor(this.rTarget === 'REJECT' ? '#FFFFFF' : '#333333')
          .onClick(() => {
            this.rTarget = 'REJECT';
          })
      }.width('100%')

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .fontSize(15)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.closeRuleEdit();
          })
        Button('保存规则')
          .layoutWeight(1)
          .height(40)
          .fontSize(15)
          .onClick(() => {
            this.saveRuleEdit();
          })
      }.width('100%')
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
    }
    .padding(16)
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  build() {
    Stack() {
      Column({ space: 8 }) {
        Row({ space: 12 }) {
          Button('☰')
            .fontSize(18)
            .height(38)
            .width(44)
            .backgroundColor('#F0F0F0')
            .fontColor('#333333')
            .onClick(() => {
              this.drawerOpen = true;
            })
          Column({ space: 2 }) {
            Text('v2rayNG 鸿蒙版').fontSize(21).fontWeight(FontWeight.Bold)
            Text(this.summary).fontSize(11).fontColor('#8A8A8A')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%')

        Row({ space: 12 }) {
          Text(this.statusText).fontSize(13).fontColor(this.running ? '#2E7D32' : '#8A8A8A')
          Text(this.trafficText).fontSize(13).fontColor('#0A59F7')
          if (this.testInfo.length > 0) {
            Text(this.testInfo).fontSize(13).fontColor('#E84026')
          }
        }.width('100%')

        Row({ space: 10 }) {
          Button('添加节点').layoutWeight(1).height(32).fontSize(13)
            .backgroundColor('#F0F0F0').fontColor('#333333')
            .onClick(() => {
              this.addNew();
            })
          Button(this.testing ? '测速中…' : '全部测速').layoutWeight(1).height(32).fontSize(13)
            .backgroundColor('#F0F0F0').fontColor('#333333')
            .enabled(!this.testing)
            .onClick(() => {
              this.testAll();
            })
        }.width('100%')

        List({ space: 8 }) {
          ForEach(this.groupList(), (group: NodeGroup) => {
            ListItem() {
              Column({ space: 6 }) {
                this.groupHeader(group)
                if (this.groupOpen(group)) {
                  ForEach(group.indices, (index: number) => {
                    this.nodeRow(index)
                  }, (index: number) => String(index) + '|' + String(this.stamp))
                }
              }
              .width('100%')
            }
          }, (group: NodeGroup) => group.key + '|' + String(this.stamp))
        }
        .layoutWeight(1)
        .width('100%')

        // 代理开关：放在最底部，单手拇指就能够到
        Row() {
          Button(this.running ? '停止代理' : '开启代理')
            .layoutWeight(1)
            .height(50)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .backgroundColor(this.running ? '#E84026' : '#0A59F7')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.connect();
            })
        }
        .width('100%')
        .padding({ top: 6, bottom: 16 })
        .visibility(this.drawerOpen ? Visibility.Hidden : Visibility.Visible)
      }
      .padding(12)
      .width('100%')
      .height('100%')
      .backgroundColor('#FFFFFF')

      if (this.drawerOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000066')
          .onClick(() => {
            this.drawerOpen = false;
          })
        this.drawer()
      }

      if (this.rulePanel) {
        this.rulesPanel()
      }

      if (this.rulePanel && this.ruleEditing >= 0) {
        this.ruleEditPanel()
      }

      if (this.editing >= 0) {
        this.editPanel()
      }
    }
    .width('100%')
    .height('100%')
  }
}
