import { common, Want } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vpnExtension, http, connection } from '@kit.NetworkKit';
import { PromptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { ProxyLink } from '../core/ProxyLink';
import { Profile, CoreState, DelayBody, DelayReq, DelayRes, RuleItem, AppScope, AppSettings, SubQuota, FetchResult, BackupPayload } from '../core/Model';
import { ConfigBuilder } from '../core/ConfigBuilder';
import { FileStore } from '../core/FileStore';
import { KeepAliveManager } from '../core/KeepAliveManager';
import { NgCore } from '../core/NgCore';

const BUNDLE_NAME: string = 'com.maoxu.v2rayng';
const EXT_ABILITY: string = 'VpnExtAbility';
const TEST_URL: string = 'http://www.gstatic.com/generate_204';
/** 自动恢复：连续 3 次（约 9s）确认系统 VPN 缺失，规避建连瞬间误判 */
const RECOVER_CONFIRM: number = 3;
/** 自动恢复退避：5→10→20→60s 封顶 */
const RECOVER_DELAYS: number[] = [5000, 10000, 20000, 60000];
/** 自动恢复尝试上限，超过后停止重连，避免无限循环 */
const RECOVER_MAX_ATTEMPTS: number = 8;
/** 规则订阅地址的默认值：内置推荐规则集（点「网址更新」即还原默认 6 条）。 */
const BUILTIN_RULE_SRC: string = 'builtin://default';

/**
 * 出口 IP 归属查询地址。已连接时代理生效、本应用没被 protect，
 * 这两个请求就是经节点出去的，返回的 IP 即「出口」而非本地宽带。
 */
// 主源用 v4-only 的 geoip 接口：这个域名只返回 A 记录，探测连接被迫走 IPv4 进隧道。
// 双栈网络下用双栈端点会被系统 Happy Eyeballs 选走 v6，而 v6 在鸿蒙这台设备上不进 tun（见 README 第 7 条），
// 探测就会看到家里宽带的真实 v6 地址，误判成“泄漏”。
const EXIT_URL_PRIMARY: string = 'https://api-ipv4.ip.sb/geoip';
const EXIT_URL_BACKUP: string = 'https://api.ip.sb/geoip';
// 保留给“v4-only 端点也挂了”时的最后兜底
const EXIT_URL_IPIP: string = 'https://myip.ipip.net/';
// 交叉校验源：另一家 v4-only 端点，只用来核对主源报的 IP 是否可信（不参与显示）
const EXIT_URL_CROSS: string = 'https://ipv4.icanhazip.com/';
// 带宽测速：单一端点不可靠 —— 11-14 09:30 用 Cloudflare speed 接口在 Warp 出口
// 上两枪全超时，09:36 换 CacheFly 的 /1mb.test 又直接 404。改成候选列表 + HEAD 预检：
// 先并发探一遍哪些端点真的返回 200，再用第一个可用的端点下载计时。
// 另外 1MB 文件测出来的 783KB/s 明显偏低（该节点订阅标注 64.59Mbps），
// 是被 TLS/TCP 慢启动吃掉了，所以探测用小文件、计时用 5~10MB 大文件，中间加一次预热。
const SPEED_PROBES: string[] = [
  'https://speed.cloudflare.com/__down?bytes=1048576',
  'https://speed.hetzner.de/1MB.bin',
  'https://proof.ovh.net/files/1Mb.dat'
];

// Geo 资源默认更新源（MetaCubeX meta-rules-dat 最新 release）。下载走直连 https，
// 若本机网络访问 GitHub 受限，可在 Geo 管理页改用本地文件替换。
const GEOIP_URL: string = 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat';
const GEOSITE_URL: string = 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat';

interface ExitGeo {
  ip?: string;
  country?: string;
  country_code?: string;
  region?: string;
  city?: string;
}

/** 一次出口探测的结果；suspect = 归属落在中国大陆，多半这一枪走的是手机自己的网络 */
interface ExitProbe {
  text: string;
  suspect: boolean;
  /** 主源报出来的源 IP，用于交叉校验 */
  ip: string;
}

/** 备用源（api.ip.sb）返回英文，常见国家和城市映射成中文，保证「国家」一定看得懂 */
const GEO_CN: Map<string, string> = new Map<string, string>([
  ['China', '中国'], ['Hong Kong', '中国香港'], ['Taiwan', '中国台湾'], ['Macau', '中国澳门'],
  ['Singapore', '新加坡'], ['Japan', '日本'], ['South Korea', '韩国'], ['Korea', '韩国'],
  ['United States', '美国'], ['USA', '美国'], ['Canada', '加拿大'], ['United Kingdom', '英国'],
  ['Germany', '德国'], ['France', '法国'], ['Netherlands', '荷兰'], ['Switzerland', '瑞士'],
  ['Sweden', '瑞典'], ['Finland', '芬兰'], ['Norway', '挪威'], ['Denmark', '丹麦'],
  ['Italy', '意大利'], ['Spain', '西班牙'], ['Austria', '奥地利'], ['Ireland', '爱尔兰'],
  ['Belgium', '比利时'], ['Poland', '波兰'], ['Czechia', '捷克'], ['Portugal', '葡萄牙'],
  ['Greece', '希腊'], ['Russia', '俄罗斯'], ['Ukraine', '乌克兰'], ['Turkey', '土耳其'],
  ['Israel', '以色列'], ['United Arab Emirates', '阿联酋'], ['India', '印度'], ['Thailand', '泰国'],
  ['Vietnam', '越南'], ['Malaysia', '马来西亚'], ['Philippines', '菲律宾'], ['Indonesia', '印度尼西亚'],
  ['Australia', '澳大利亚'], ['New Zealand', '新西兰'], ['Brazil', '巴西'], ['Argentina', '阿根廷'],
  ['Mexico', '墨西哥'], ['Chile', '智利'], ['South Africa', '南非'], ['Egypt', '埃及'],
  ['Tokyo', '东京'], ['Osaka', '大阪'], ['Seoul', '首尔'], ['North Chungcheong', '忠清北道'],
  ['Los Angeles', '洛杉矶'], ['San Jose', '圣何塞'], ['San Francisco', '旧金山'], ['New York', '纽约'],
  ['Seattle', '西雅图'], ['Dallas', '达拉斯'], ['Silicon Valley', '硅谷'], ['Ashburn', '阿什本'],
  ['London', '伦敦'], ['Frankfurt', '法兰克福'], ['Amsterdam', '阿姆斯特丹'], ['Paris', '巴黎'],
  ['Berlin', '柏林'], ['Sydney', '悉尼'], ['Melbourne', '墨尔本'], ['Toronto', '多伦多'],
  ['Moscow', '莫斯科'], ['Bangkok', '曼谷'], ['Kuala Lumpur', '吉隆坡'], ['Manila', '马尼拉'],
  ['Jakarta', '雅加达'], ['Mumbai', '孟买'], ['Taipei', '台北'], ['Kowloon', '九龙'],
  ['Jiangsu', '江苏'], ['Zhejiang', '浙江'], ['Guangdong', '广东'], ['Shanghai', '上海'],
  ['Beijing', '北京'], ['Fujian', '福建'], ['Sichuan', '四川'], ['Hong Kong Island', '香港岛']
]);

function geoCn(name: string): string {
  const key: string = name.trim();
  const hit: string | undefined = GEO_CN.get(key);
  return hit !== undefined ? hit : key;
}

/** 节点分组：key 为空表示手动添加的节点，否则为订阅 URL。 */
class NodeGroup {
  key: string = '';
  title: string = '';
  indices: number[] = [];
}

/** 设置项局部补丁：字段全部可选，未传的保持原值。 */
interface SettingsPatch {
  testConcurrency?: number;
  speedBytes?: number;
  autoConnect?: boolean;
  failover?: boolean;
  keepAlive?: boolean;
  autoUpdateOnStart?: boolean;
}

/**
 * 列表中的一行。LazyForEach 只按需创建可见的行，
 * 所以这里把要显示的字段都拍平，渲染时不用再回头读 profiles。
 */
class NodeRow {
  /** 0 分组头 / 1 节点 / 2「再显示」 */
  kind: number = 0;
  key: string = '';
  groupKey: string = '';
  groupTitle: string = '';
  groupCount: number = 0;
  groupOpen: boolean = false;
  nodeIndex: number = -1;
  name: string = '';
  delay: number = -1;
  /** 延迟测速是否跑过：false 显示「—」，true 且 delay<0 才显示红色 -1 */
  delayTested: boolean = false;
  /** 下载测速结果（KB/s，-1 未测，0 测过不通）；与延迟一起显示在节点行 */
  speed: number = -1;
  addr: string = '';
  selected: boolean = false;
  /** 多选模式下该行是否被勾选 */
  checked: boolean = false;
  moreLeft: number = 0;
  /** 订阅配额/到期展示文案（仅订阅分组头使用） */
  quotaText: string = '';
  /** 订阅组在这里是一整块卡片：首行给上圆角、末行给下圆角 */
  firstInBlock: boolean = false;
  lastInBlock: boolean = false;
}

/** LazyForEach 的数据源：整体换行数组后通知列表刷新。 */
class NodeDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private rows: NodeRow[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): NodeRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  setRows(rows: NodeRow[]): void {
    this.rows = rows;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }

  /** 只有某一行内容变了：精确通知，避免整表重建 */
  notifyRowChange(index: number): void {
    if (index < 0 || index >= this.rows.length) {
      return;
    }
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataChange(index);
    });
  }

  /** 按节点下标找它所在的行号（-1 表示当前不可见或未展开） */
  indexOfNode(nodeIndex: number): number {
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].kind === 1 && this.rows[i].nodeIndex === nodeIndex) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 改某一行的选中态：复制一份再替换，引用变了 LazyForEach 才认这是新数据，
   * 只通知这一行，其它行完全不动。
   */
  markSelected(nodeIndex: number, flag: boolean): void {
    const at: number = this.indexOfNode(nodeIndex);
    if (at < 0) {
      return;
    }
    const src: NodeRow = this.rows[at];
    if (src.selected === flag) {
      return;
    }
    const copy: NodeRow = new NodeRow();
    copy.kind = src.kind;
    copy.key = src.key;
    copy.groupKey = src.groupKey;
    copy.groupTitle = src.groupTitle;
    copy.groupCount = src.groupCount;
    copy.groupOpen = src.groupOpen;
    copy.nodeIndex = src.nodeIndex;
    copy.name = src.name;
    copy.delay = src.delay;
    copy.delayTested = src.delayTested;
    copy.speed = src.speed;
    copy.addr = src.addr;
    copy.selected = flag;
    copy.checked = src.checked;
    copy.moreLeft = src.moreLeft;
    copy.quotaText = src.quotaText;
    this.rows[at] = copy;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataChange(at);
    });
  }
}

@Entry
@Component
struct Index {
  @State profiles: Profile[] = [];
  /** 当前选中的节点下标。故意不用 @State：点选节点只改两行，不该触发整页重建。 */
  private selected: number = -1;
  @State running: boolean = false;
  @State statusText: string = '未连接';
  @State totalText: string = '';
  /** 当前出口 IP 归属，例如「出口 1.2.3.4 · 中国 江苏 无锡」；已连接时代理生效，请求走的就是出口 */
  @State exitInfo: string = '';
  @State exitBusy: boolean = false;
  /** 出口检测的请求代际：切节点/断开时自增，旧请求的结果回来直接作废 */
  private exitSeq: number = 0;
  /** 连续空结果（握手失败/超时）枪数；拿到任一非空结果即清零 */
  private exitEmptyStreak: number = 0;
  /** 最近一次订阅重建后，原选中节点是否原样保留（server+port+uuid 全等）；true 则不必重连 */
  private selectedKept: boolean = true;
  /** 已熔断：当前节点无可用出口，exitInfo 是提示文案而非真出口，置灰显示 */
  @State exitBlocked: boolean = false;
  /** 熔断时刻与当时的累计下行字节：用于区分「节点真死」和「后台探测被冻结」 */
  private exitBlockedAt: number = 0;
  private exitBlockedDown: number = 0;
  /** 当前这次连接已自动切换过几次节点：防止全网节点都死时疯狂重连 */
  private failoverCount: number = 0;
  /** 最近一次读到的累计下行：判断隧道是否真有流量在走 */
  private lastTotalDown: number = 0;
  /** 已连接节点最近一次测速成功的延迟：故障转移优先选它 */
  private failoverTried: string[] = [];
  /** 连续多少枪全空后停止重试（约 1 分钟），避免死节点上无限转圈 */
  static readonly EXIT_EMPTY_LIMIT: number = 8;
  /** 熔断后的自动复检间隔：不再永久停，60s 后自己爬起来再试一枪 */
  static readonly EXIT_RECHECK_MS: number = 60000;
  /** 单次连接最多自动切换节点次数 */
  static readonly FAILOVER_MAX: number = 2;
  /** 判定「隧道确实有流量」的最小增量（4KB），避免把噪声当成通 */
  static readonly FLOW_ALIVE_BYTES: number = 4096;
  /** 带宽测速进行中 / 结果文案（显示在出口卡片上） */
  @State speedBusy: boolean = false;
  @State speedInfo: string = '';
  @State summary: string = 'mihomo 内核 · 国内直连 / 国外代理';
  @State linkInput: string = '';
  @State subInput: string = '';
  @State testing: boolean = false;
  /** 多选模式：节点行前置勾选框，工具条支持批量测延迟/删除/导出 */
  @State multiMode: boolean = false;
  /** 勾选节点的 Profile.id 集合（用 id 而非下标：删除/订阅刷新后下标会漂移） */
  private checkedIds: Set<string> = new Set();
  /** 勾选数量的响应式镜像：Set 本身不是 @State，工具条文案靠它刷新 */
  @State checkedCount: number = 0;
  /** 连接/断开进行中：按钮立刻给出反馈，避免「点了没反应」的错觉 */
  @State busy: boolean = false;
  /** 测速进度：已测 / 待测 */
  @State testDone: number = 0;
  @State testTotal: number = 0;
  @State testInfo: string = '';
  /** 全部更新：互斥标志 + 已完成 / 待完成计数 + 进度文案（卡片样式与测速进度一致） */
  @State updatingAll: boolean = false;
  @State updDone: number = 0;
  @State updTotal: number = 0;
  @State updInfo: string = '';
  /** 列表重建戳：分组 ForEach 的 key 靠它变化才会重新渲染 */
  @State stamp: number = 0;
  /** 分组已展开的节点页数（每页 PAGE_SIZE 个），改变它触发列表重绘 */
  @State pageSeq: number = 0;
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
  /** 路由快捷清单：直连 / 强制代理域名输入框 */
  @State directDomInput: string = '';
  @State proxyDomInput: string = '';
  /** 规则列表一次渲染多少条：社区规则集动辄几千条，分页渲染避免列表卡死。 */
  @State rulesLimit: number = 50;

  // 分应用代理（设置页）
  @State appScopePanel: boolean = false;
  @State appMode: string = 'all';
  @State appPkgs: string = '';

  // 编辑面板
  @State editing: number = -1;
  @State editNew: boolean = false;
  @State eName: string = '';
  @State eType: string = 'vless';
  @State eServer: string = '';
  @State ePort: string = '443';
  @State eUuid: string = '';
  @State eUsername: string = '';
  @State ePassword: string = '';
  @State eCipher: string = '';
  @State eNetwork: string = 'ws';
  @State eTls: boolean = true;
  @State eSni: string = '';
  @State ePath: string = '';
  @State eHost: string = '';
  @State eAlpn: string = '';
  @State eInsecure: boolean = false;
  @State eFingerprint: string = '';
  // 高级传输 / 协议字段（手动新建/编辑入口）
  @State eFlow: string = '';
  @State eGrpcService: string = '';
  @State eRealityPbk: string = '';
  @State eRealitySid: string = '';
  @State eAlterId: string = '0';
  @State eKcpSeed: string = '';
  @State eKcpHeader: string = '';
  @State eXhttpMode: string = '';
  @State eHttpUpgrade: boolean = false;
  @State eHttpUpgradeFastOpen: boolean = false;
  @State eHy2Obfs: string = '';
  @State eHy2ObfsPassword: string = '';
  @State eHy2Up: string = '';
  @State eHy2Down: string = '';
  @State eTuicCongestion: string = '';
  @State eTuicUdpMode: string = '';
  @State eTuicReduceRtt: boolean = false;
  @State eTuicFastOpen: boolean = false;
  @State eAnytlsMetadata: string = '';

  // 测速偏好（并发 / 包大小）与内核版本
  @State settingsPanel: boolean = false;
  @State settings: AppSettings = {
    testConcurrency: 24, speedBytes: 5242880,
    autoConnect: true, failover: true, keepAlive: true, autoUpdateOnStart: false
  };
  @State coreVersion: string = '';

  // 订阅分组改名：key = 订阅 URL，value = 用户自己起的名字（存 group-names.json）
  @State renameKey: string = '';
  @State renameText: string = '';
  private groupNames: Map<string, string> = new Map<string, string>();

  // 测速停止标志：批次间隙与单点测速轮询循环都会检查
  private testStop: boolean = false;

  // 应用内日志查看器：三通道（ui / vpn / watchdog）切换、刷新、清空、行数统计
  @State logPanel: boolean = false;
  @State logChannel: string = 'ui';
  @State logLines: string[] = [];
  @State logMsg: string = '';

  // 本次会话：连接起始时间戳、内核计数器基线、界面展示文案
  private sessionStart: number = 0;
  private baseUp: number = 0;
  private baseDown: number = 0;
  @State sessionText: string = '';

  // 订阅配额：key = 订阅 URL，解析自 subscription-userinfo 响应头
  private subQuota: Map<string, SubQuota> = new Map<string, SubQuota>();

  // 新建分组面板：名称 + 订阅链接（链接留空 = 手动分组）
  @State groupPanel: boolean = false;
  @State gName: string = '';
  @State gUrl: string = '';

  // Geo 资源管理页：geoip.dat / geosite.dat 大小与修改时间文案、忙碌标志
  @State geoPanel: boolean = false;
  @State geoMsg: string = '';
  @State geoBusy: boolean = false;
  @State geoIpText: string = '';
  @State geoSiteText: string = '';

  private filesDir: string = '';
  private pollTimer: number = -1;
  /** 系统 VPN 存活校验（state.json 可能残留 running=true） */
  private watchTimer: number = -1;
  /** groupList 缓存：profiles 引用 + 排序开关 + 数据版本都不变时直接复用 */
  private cacheProfiles: Profile[] | undefined = undefined;
  private cacheSort: boolean = false;
  private cacheGroups: NodeGroup[] = [];
  /** 列表数据源：LazyForEach 按需渲染，几百个节点也只创建屏幕内的行 */
  private dataSource: NodeDataSource = new NodeDataSource();
  /** 节点列表变动后的自动重连互斥，避免连续操作把连接状态搅乱 */
  private reconnecting: boolean = false;
  /** 切换过程中又有新的选择，等这轮完成后再切一次 */
  private pendingSwitch: boolean = false;
  private switchTimer: number = -1;
  /** 手动推进度提示的保护区：这段时间内不让 state.json 的旧文案把它盖掉 */
  private statusManualUntil: number = 0;
  /** 自动恢复：系统 VPN 连续缺失计数 */
  private lostCount: number = 0;
  /** 自动恢复互斥，避免同一时刻多路重连 */
  private recovering: boolean = false;
  /** 自动恢复已尝试次数（退避用） */
  private recoverAttempt: number = 0;
  /** 自动恢复退避定时器 */
  private recoverTimer: number = -1;
  /** 连接入口互斥：恢复定时器 / 用户点击 / 节点切换并发时只允许一路启动扩展 */
  private connecting: boolean = false;
  /** 冷启动自愈一次性标志（与 KeepAliveManager 的进程内标志形成双保险） */
  private coldStartHealTriggered: boolean = false;
  /** 后台保活不可用提示（长时任务连续申请失败时显示，不再静默） */
  @State keepAliveWarn: string = '';

  /** 显示一条自己控制的进度文案，几秒内不被轮询覆盖 */
  private setStatus(text: string): void {
    this.statusText = text;
    this.statusManualUntil = Date.now() + 5000;
  }
  private toast: PromptAction = this.getUIContext().getPromptAction();

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.filesDir = context.filesDir;
    // 注入应用级 context，确保 userStopped 持久化在用户点击前已恢复
    KeepAliveManager.getInstance().init(context);
    // 只在状态文件不存在时初始化；已有状态交给 readState + verifyRunning 判断，
    // 否则每次重新进入页面都会把上一轮的真实状态（可能是运行中）覆盖成「未连接」。
    if (FileStore.readText(FileStore.statePath(this.filesDir)).length === 0) {
      FileStore.writeText(FileStore.statePath(this.filesDir), '{"running":false,"message":"未连接"' + FileStore.userStoppedField(this.filesDir) + '}');
    }
    this.reload();
    this.loadGroupNames();
    this.refreshRows();
    if (this.profiles.length === 0) {
      this.seedDefaultNodes();
    }
    // 启动自动更新：开关打开且已有节点时，延迟一拍等首帧渲染后静默拉取全部订阅
    if (this.settings.autoUpdateOnStart && this.profiles.length > 0) {
      setTimeout(() => {
        this.updateAllSubscriptions();
      }, 600);
    }
    const pending: string = AppStorage.get<string>('launchImportUri') ?? '';
    if (pending.length > 0) {
      AppStorage.setOrCreate<string>('launchImportUri', '');
      // 任何应用都能通过 Want 拉起本 App 并塞 importUri；直接导入等于让外部应用
      // 决定你连哪个节点，所以先弹窗确认，用户点了才真正解析。
      setTimeout(() => {
        AlertDialog.show({
          title: '外部导入请求',
          message: '另一个应用请求导入 ' + String(pending.length) + ' 个字符的节点链接。\n' +
            '如果这不是你自己发起的，请选择忽略。',
          autoCancel: true,
          primaryButton: {
            value: '忽略',
            action: () => {
            }
          },
          secondaryButton: {
            value: '导入',
            action: () => {
              this.linkInput = pending;
              this.importFromText();
            }
          }
        });
      }, 0);
    }
    this.pollTimer = setInterval(() => {
      this.readState();
      // 消费 EntryAbility.onForeground 登记的冷启动自愈请求：只读布尔，不额外读文件
      this.tryColdStartRecover(false);
      // 消费 onForeground 的系统 VPN 交叉校验结果（state 说已连接、实际无 :vpn）
      this.consumeNeedRecover();
    }, 1000);
    // 系统 VPN 是否真的还在，3 秒校验一次：状态文件可能是扩展被强杀前的残留
    this.watchTimer = setInterval(() => {
      this.verifyRunning();
    }, 3000);
    this.verifyRunning();
    // 冷启动自愈：UI 进程被系统回收后重新拉起时，扩展 onDestroy 已把 state.json
    // 写成 running=false，verifyRunning() 首行直接短路，自动恢复永远排不上。
    // 仅「非用户主动停止 + 扩展已死」双条件成立时才排一次恢复。
    this.tryColdStartRecover(true);
    // 冷启动时 onForeground 早于页面加载：这里补消费一次交叉校验标记
    this.consumeNeedRecover();
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.watchTimer >= 0) {
      clearInterval(this.watchTimer);
      this.watchTimer = -1;
    }
    if (this.recoverTimer >= 0) {
      clearTimeout(this.recoverTimer);
      this.recoverTimer = -1;
    }
    this.recovering = false;
  }

  /** 系统里当前是否真的有 VPN 通道（权威判断，优于状态文件里的 running 字段）。 */
  async hasSystemVpn(): Promise<boolean> {
    try {
      const nets: connection.NetHandle[] = await connection.getAllNets();
      for (let i = 0; i < nets.length; i++) {
        const caps: connection.NetCapabilities = await connection.getNetCapabilities(nets[i]);
        const bearers: connection.NetBearType[] = caps.bearerTypes;
        if (bearers !== undefined && bearers.indexOf(connection.NetBearType.BEARER_VPN) >= 0) {
          return true;
        }
      }
    } catch (err) {
      FileStore.appendLog(this.filesDir, 'getAllNets failed: ' + String(err));
    }
    return false;
  }

  /**
   * 校准运行状态：扩展被系统杀掉（VPN 图标消失）时，state.json 往往还停在 running=true。
   * 以系统 VPN 是否存在为准，并区分「用户主动断开」与「疑似被系统回收」：
   * - 用户主动断开：只把界面/状态文件纠正为未连接，绝不自动重连或申请保活；
   * - 疑似被回收：连续 3 次确认（约 9s，规避建连瞬间 getAllNets 未出现
   *   BEARER_VPN 导致的 13:09 型 2s 误判）后，按退避自动恢复。
   */
  async verifyRunning(): Promise<void> {
    if (!this.running) {
      this.lostCount = 0;
      return;
    }
    const alive: boolean = await this.hasSystemVpn();
    if (alive) {
      this.lostCount = 0;
      this.recoverAttempt = 0;
      return;
    }
    const mgr: KeepAliveManager = KeepAliveManager.getInstance();
    if (mgr.isUserStopped()) {
      FileStore.appendLog(this.filesDir, 'verify: no system vpn, force ui to disconnected');
      this.applyDisconnected();
      return;
    }
    this.lostCount++;
    if (this.lostCount < RECOVER_CONFIRM) {
      return;
    }
    this.lostCount = 0;
    FileStore.appendLog(this.filesDir, 'verify: no system vpn, force ui to disconnected');
    this.applyDisconnected();
    // 检出疑似系统回收：置冷却（不立即重申请长时任务），再排自动恢复
    mgr.noteTaskCancelled();
    this.scheduleRecover();
  }

  /** 把界面与状态文件纠正为未连接（不改 userStopped，不释放保活）。 */
  private applyDisconnected(): void {
    this.running = false;
    this.statusText = '未连接';
    this.totalText = '';
    FileStore.writeText(FileStore.statePath(this.filesDir), '{"running":false,"message":"未连接"' + FileStore.userStoppedField(this.filesDir) + '}');
  }

  /**
   * 冷启动自愈（进程内一次性）。
   * checkState=true 仅由 aboutToAppear 调用，顺带做一次 state.json 判定；
   * checkState=false 供 1s pollTimer 使用，只消费 EntryAbility.onForeground
   * 登记的请求，避免每秒重复读文件。
   * 触发条件在 KeepAliveManager.isAbnormalDisconnect() 中双校验，缺一不可：
   * !running && userStopped === false && message === '已断开'。
   * 用户主动停止落盘的是「未连接」+ userStopped=true，绝不会被自动抢连回来。
   * 复用 scheduleRecover()：保留 5→10→20→60s 退避、8 次尝试上限、
   * Math.max(delay, cooldownRemaining()) 与 canAutoRecover() 冷却门禁，
   * 不新增 state.json 字段。
   */
  private tryColdStartRecover(checkState: boolean): void {
    if (this.coldStartHealTriggered) {
      return;
    }
    const mgr: KeepAliveManager = KeepAliveManager.getInstance();
    if (mgr.autoConnectDisabled()) {
      return;
    }
    if (checkState) {
      mgr.requestColdStartHeal(this.filesDir);
    }
    if (!mgr.consumeColdStartHeal()) {
      return;
    }
    this.coldStartHealTriggered = true;
    // 两种异常来源分开记：扩展走了 onDestroy（abnormal disconnect）vs 被 SIGKILL、
    // state.json 残留 running:true（stale heartbeat，靠 mtime 超 30s 判定）。
    FileStore.appendLog(this.filesDir, 'cold start recover: ' + mgr.abnormalKind(this.filesDir) +
      ' (userStopped=false)');
    this.scheduleRecover();
  }

  /**
   * 消费 EntryAbility.onForeground 的系统 VPN 交叉校验结果。
   * 为什么需要：state.json 里的 running 可能是扩展被 SIGKILL 前残留的「已连接」，
   * 只信文案会永久卡在假连接；而 onForeground 是系统稳定投递的生命周期回调，
   * 不受应用冻结影响，是唯一可靠的纠错时点。用户主动停止 / 冷却中一律不恢复。
   */
  private consumeNeedRecover(): void {
    if (AppStorage.get<boolean>('needRecover') !== true) {
      return;
    }
    AppStorage.setOrCreate<boolean>('needRecover', false);
    const mgr: KeepAliveManager = KeepAliveManager.getInstance();
    if (mgr.isUserStopped() || !mgr.canAutoRecover() || mgr.autoConnectDisabled()) {
      return;
    }
    FileStore.appendLog(this.filesDir, 'recover: needRecover consumed (onForeground cross-check)');
    this.scheduleRecover();
  }

  /**
   * 自动恢复调度：去重（recovering + 单定时器）、5→10→20→60s 封顶退避、
   * 尝试上限，并把冷却剩余并入延迟以规避「系统取消后立即再次申请」红线。
   * 复用现有 connect() 启动 vpnExtension 的入口（fromRecover=true 不改 userStopped）。
   */
  private scheduleRecover(): void {
    const mgr: KeepAliveManager = KeepAliveManager.getInstance();
    if (this.recovering || this.recoverTimer >= 0) {
      return;
    }
    // 自动连接被用户关闭：冷启动 / 掉线都不自动重连
    if (mgr.autoConnectDisabled()) {
      return;
    }
    if (mgr.isUserStopped()) {
      return;
    }
    if (this.recoverAttempt >= RECOVER_MAX_ATTEMPTS) {
      FileStore.appendLog(this.filesDir, 'recover: give up after max attempts');
      return;
    }
    const idx: number = Math.min(this.recoverAttempt, RECOVER_DELAYS.length - 1);
    const baseDelay: number = RECOVER_DELAYS[idx];
    const delayMs: number = Math.max(baseDelay, mgr.cooldownRemaining());
    this.recoverAttempt++;
    this.recovering = true;
    FileStore.appendLog(this.filesDir, 'verify: vpn lost, auto recovering attempt=' +
      String(this.recoverAttempt) + ' delay=' + String(delayMs));
    this.recoverTimer = setTimeout(() => {
      this.recoverTimer = -1;
      this.recovering = false;
      if (!mgr.canAutoRecover()) {
        return;
      }
      this.connect(true).catch((err: Error) => {
        FileStore.appendLog(this.filesDir, 'recover: connect failed ' + err.message);
      });
      // 8s 后复查：扩展拉起失败（running 仍为 false）就按递增退避再排一轮
      this.recoverTimer = setTimeout(() => {
        this.recoverTimer = -1;
        if (!this.running && !mgr.isUserStopped()) {
          this.scheduleRecover();
        }
      }, 8000);
    }, delayMs);
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
      if (p.alpn === undefined) {
        p.alpn = '';
      }
      if (p.allowInsecure === undefined) {
        p.allowInsecure = false;
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
    // 测速偏好（并发 / 包大小 / 连接行为开关）
    this.settings = FileStore.loadSettings(this.filesDir);
    // 订阅配额与到期信息（上次成功拉取时落盘）
    this.subQuota = FileStore.loadSubQuota(this.filesDir);
    // 内核版本：扩展进程启动时写入；首次连接前文件可能为空，这里直接调 NAPI 兜底读一次
    this.coreVersion = FileStore.readText(FileStore.coreVersionPath(this.filesDir)).trim();
    if (this.coreVersion.length === 0) {
      try {
        const ver: string = NgCore.version();
        if (ver.length > 0 && ver !== 'unknown') {
          this.coreVersion = ver;
          FileStore.writeText(FileStore.coreVersionPath(this.filesDir), ver);
        }
      } catch (err) {
      }
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
      if (this.running) {
        this.running = false;
      }
      return;
    }
    try {
      const state = JSON.parse(text) as CoreState;
      // 值没变就不赋值：每秒都写一遍 @State 会白白触发整页重绘（列表里有几百个节点）
      if (this.running !== state.running) {
        this.running = state.running;
        if (this.running) {
          // 刚连上，隧道还没稳，稍等一下再测出口
          this.exitEmptyStreak = 0;
          this.exitBlocked = false;
          // 记录本次会话起点与内核计数器基线，会话流量 = 当前值 - 基线
          this.sessionStart = Date.now();
          this.baseUp = state.up !== undefined ? state.up : 0;
          this.baseDown = state.down !== undefined ? state.down : 0;
          this.refreshSessionText(state.up !== undefined ? state.up : 0,
            state.down !== undefined ? state.down : 0);
          this.scheduleExitRefresh(2000, 1);
          // 连上立即申请一次长时任务（force）：不再只依赖边沿触发。
          // 真机 14:10/14:14 重连时边沿丢失导致 69 分钟后台无保活，
          // 这是「漏申请」根因的第一道修复。
          this.requestKeepAlive();
        } else {
          this.exitSeq++;
          this.exitBusy = false;
          this.exitEmptyStreak = 0;
          this.exitBlocked = false;
          this.sessionStart = 0;
          this.sessionText = '';
          if (this.exitInfo.length > 0) {
            this.exitInfo = '';
          }
          // 仅用户主动停止才释放长时任务；系统回收 / UI 校正时保留保活，
          // 避免把「被回收」误当成「用户停止」而丢掉后台保护。
          if (KeepAliveManager.getInstance().isUserStopped()) {
            this.releaseKeepAlive();
          }
        }
      }
      // 状态驱动低频复核：只要 VPN 仍在运行，就周期性确认长时任务还在
      // （管理器内部 ≥30s 节流 + 冷却），不依赖任何边沿或组件实例布尔量。
      // 这是「漏申请」根因的主修复，组件重建、页面切后台都不会再漏。
      if (state.running && !KeepAliveManager.getInstance().isUserStopped()) {
        this.ensureKeepAlive();
      }
      // 保活连续失败时给出可见提示，不再静默地显示「已连接」
      const warn: string = KeepAliveManager.getInstance().warningText(state.running);
      if (this.keepAliveWarn !== warn) {
        this.keepAliveWarn = warn;
      }
      if (this.statusText !== state.message && Date.now() > this.statusManualUntil) {
        this.statusText = state.message;
      }
      // 状态行只显示本次累计用量；实时速率对后台常驻的代理没实际意义，不再采集
      let total: string = '';
      if (state.totalUp !== undefined && state.totalDown !== undefined &&
          (state.totalUp > 0 || state.totalDown > 0)) {
        total = '累计 ↑' + Index.human(state.totalUp) + ' ↓' + Index.human(state.totalDown);
      }
      if (this.totalText !== total) {
        this.totalText = total;
      }
      // 累计下行用于两件事：证明隧道确实有流量；熔断后判断是节点死还是探测被冻结
      if (state.totalDown !== undefined) {
        this.lastTotalDown = state.totalDown;
      }
      // 本次会话时长与上下行差值（每秒随状态文件刷新一次）
      if (this.running) {
        this.refreshSessionText(state.up !== undefined ? state.up : 0,
          state.down !== undefined ? state.down : 0);
      }
      // 熔断不再永久停：每 60s 自己复检一次，有流量就重试探测，没流量就尝试故障转移
      this.tickExitBlocked();
    } catch (err) {
    }
  }

  /**
   * 熔断后的自愈节拍（由 readState 每秒驱动，内部按 60s 节流）。
   * 背景：真机 11-14 03:32–04:33 连续 8 枪全超时后熔断，之后 4 小时 37 分
   * 界面一直停在「当前节点无可用出口」，而同一时段累计下行还有 357MB ——
   * 说明后台 UI 定时器被系统节流后才凑满 8 枪，节点根本没死。所以：
   * - 熔断期间累计下行仍在增长 ⇒ 判定探测链路问题，重新探一枪等它自己恢复；
   * - 累计下行也没增长 ⇒ 才认为是节点真不通，尝试自动切换。
   */
  private tickExitBlocked(): void {
    if (!this.exitBlocked || !this.running || this.exitBusy) {
      return;
    }
    const now: number = Date.now();
    if (this.exitBlockedAt === 0) {
      this.exitBlockedAt = now;
      this.exitBlockedDown = this.lastTotalDown;
      return;
    }
    if (now - this.exitBlockedAt < Index.EXIT_RECHECK_MS) {
      return;
    }
    const grew: boolean = this.lastTotalDown - this.exitBlockedDown > Index.FLOW_ALIVE_BYTES;
    this.exitBlockedAt = now;
    this.exitBlockedDown = this.lastTotalDown;
    if (grew) {
      // 有流量就不动节点，只把探测重新跑一遍；失败会按 EXIT_EMPTY_LIMIT 再次熔断
      FileStore.appendLog(this.filesDir,
        'exit probe blocked but traffic alive (down=' + String(this.lastTotalDown) +
        '), retry probe');
      this.refreshExit(1);
      return;
    }
    this.tryFailover('no traffic for ' + String(Index.EXIT_RECHECK_MS / 1000) + 's');
  }

  /**
   * 自动故障转移：当前节点判定不可用且确实没有流量时，换一个节点。
   * 候选顺序：本组内已测速成功（delay>=0）按延迟升序 → 其它组已测速成功
   * → 未测速节点按列表顺序轮转。已试过的 server:port 不重复试，最多 FAILOVER_MAX 次。
   */
  private tryFailover(reason: string): void {
    // 故障转移被用户关闭：节点无流量时不自动换节点，保留在当前节点上
    if (!this.settings.failover) {
      return;
    }
    if (this.profiles.length < 2 || this.selected < 0 || this.selected >= this.profiles.length) {
      return;
    }
    if (this.failoverCount >= Index.FAILOVER_MAX) {
      FileStore.appendLog(this.filesDir, 'failover: limit reached (' +
        String(Index.FAILOVER_MAX) + '), stay on current node');
      // 自动切换额度用尽且确实没流量：这才是「节点不可用」，给明确可操作提示
      this.exitInfo = '当前节点无可用出口，请手动切换';
      return;
    }
    const cur: Profile = this.profiles[this.selected];
    const curKey: string = cur.server + ':' + String(cur.port);
    if (this.failoverTried.indexOf(curKey) < 0) {
      this.failoverTried.push(curKey);
    }
    let best: number = -1;
    let bestDelay: number = 999999;
    for (let i = 0; i < this.profiles.length; i++) {
      const p: Profile = this.profiles[i];
      const key: string = p.server + ':' + String(p.port);
      if (i === this.selected || this.failoverTried.indexOf(key) >= 0) {
        continue;
      }
      if (p.delay >= 0 && p.delay < bestDelay) {
        bestDelay = p.delay;
        best = i;
      }
    }
    if (best < 0) {
      // 没有任何已测速成功的候选：按列表顺序找一个没试过的，避免全网死节点时死磕
      for (let step = 1; step < this.profiles.length; step++) {
        const i: number = (this.selected + step) % this.profiles.length;
        const key: string = this.profiles[i].server + ':' + String(this.profiles[i].port);
        if (this.failoverTried.indexOf(key) < 0) {
          best = i;
          break;
        }
      }
    }
    if (best < 0) {
      FileStore.appendLog(this.filesDir, 'failover: no untried candidate, stay');
      return;
    }
    this.failoverCount++;
    const name: string = this.profiles[best].name;
    FileStore.appendLog(this.filesDir, 'failover #' + String(this.failoverCount) +
      ' (' + reason + ') -> ' + name);
    this.exitEmptyStreak = 0;
    this.exitBlocked = false;
    this.exitBlockedAt = 0;
    if (this.exitInfo.length > 0) {
      this.exitInfo = '';
    }
    this.toast.showToast({ message: '节点无流量，已自动切换到 ' + name });
    this.selectNode(best, true);
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

  /** 本次会话时长 + 上下行差值；内核计数器基线在连上瞬间记下。 */
  private refreshSessionText(up: number, down: number): void {
    if (this.sessionStart === 0) {
      this.sessionText = '';
      return;
    }
    const sec: number = Math.max(0, Math.floor((Date.now() - this.sessionStart) / 1000));
    const hh: number = Math.floor(sec / 3600);
    const mm: number = Math.floor((sec % 3600) / 60);
    const ss: number = sec % 60;
    const pad = (n: number): string => String(n).padStart(2, '0');
    const dur: string = hh > 0 ? (hh + ':' + pad(mm) + ':' + pad(ss)) : (mm + ':' + pad(ss));
    const du: number = Math.max(0, up - this.baseUp);
    const dd: number = Math.max(0, down - this.baseDown);
    this.sessionText = '时长 ' + dur + ' · ↑' + Index.human(du) + ' ↓' + Index.human(dd);
  }

  /** IPv6 出口地址太长，中段省略，别把后面的地区挤掉 */
  static shortIp(ip: string): string {
    if (ip.length <= 24) {
      return ip;
    }
    return ip.substring(0, 10) + '…' + ip.substring(ip.length - 8);
  }

  /** 归属落在中国大陆（港澳台除外）= 这一枪大概率走了手机自己的网络，不是节点出口 */
  static looksLocal(loc: string): boolean {
    if (loc.length === 0) {
      return false;
    }
    if (loc.indexOf('香港') >= 0 || loc.indexOf('台湾') >= 0 || loc.indexOf('澳门') >= 0) {
      return false;
    }
    // 省份名兜底：ipip 有时不给「中国」前缀，只给「江苏 无锡 电信」
    const provinces: string[] = ['北京', '天津', '河北', '山西', '内蒙古', '辽宁', '吉林', '黑龙江',
      '上海', '江苏', '浙江', '安徽', '福建', '江西', '山东', '河南', '湖北', '湖南', '广东',
      '广西', '海南', '重庆', '四川', '贵州', '云南', '西藏', '陕西', '甘肃', '青海', '宁夏', '新疆'];
    let hit: boolean = false;
    provinces.forEach((item: string) => {
      if (loc.indexOf(item) >= 0) {
        hit = true;
      }
    });
    return hit || loc.indexOf('中国') === 0;
  }

  /** 归属只留「国家 + 省级」：城市和运营商一行放不下；重复段（如「新加坡 新加坡」）合并掉 */
  static shortLoc(loc: string): string {
    const text: string = loc.trim();
    if (text.length === 0) {
      return '';
    }
    const seg: string[] = text.split(' ');
    const uniq: string[] = [];
    seg.forEach((item: string) => {
      if (item.length > 0 && uniq.indexOf(item) < 0) {
        uniq.push(item);
      }
    });
    if (uniq.length === 0) {
      return '';
    }
    if (uniq.length <= 2) {
      return uniq.join(' ');
    }
    return uniq[0] + ' ' + uniq[1];
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

  /** 数据变了：版本号 +1 让分组缓存失效，并重建列表数据源。 */
  bump(): void {
    this.stamp = this.stamp + 1;
    this.refreshRows();
  }

  /**
   * 点选节点：只改「旧选中」「新选中」两行并精确通知，
   * 不重建行数组、不触发整页 build —— 这是切换节点手感的关键。
   */
  selectNode(nodeIndex: number, fromFailover: boolean = false): void {
    if (nodeIndex === this.selected || nodeIndex < 0) {
      return;
    }
    if (!fromFailover) {
      // 用户自己点的节点：清空自动切换计数，给他完整的重试额度
      this.failoverCount = 0;
      this.failoverTried = [];
    }
    const prev: number = this.selected;
    // 换了节点就换了出口，上一个节点的带宽结果不再代表现在
    if (this.speedInfo.length > 0) {
      this.speedInfo = '';
    }
    this.selected = nodeIndex;
    this.dataSource.markSelected(prev, false);
    this.dataSource.markSelected(nodeIndex, true);
    // 已经连着的时候点了别的节点：直接切过去，别再让用户自己停一次开一次
    if (this.reconnecting) {
      // 正在切换：记一笔，这一轮 connect 会读最新的 selected
      this.pendingSwitch = true;
    } else if (this.running) {
      this.switchToSelected();
    }
  }

  /** 连点几下节点时不要每下都重连，停手 0.8 秒后再切到最终选中的那个 */
  switchToSelected(): void {
    if (this.switchTimer >= 0) {
      clearTimeout(this.switchTimer);
    }
    const name: string = this.selected >= 0 && this.selected < this.profiles.length ?
      this.profiles[this.selected].name : '';
    this.setStatus('准备切换到 ' + name);
    this.switchTimer = setTimeout(() => {
      this.switchTimer = -1;
      this.reconnectSoon();
      // 换了节点，出口 IP 会变：等重连完成再重新测一次
      this.exitEmptyStreak = 0;
      this.exitBlocked = false;
      this.scheduleExitRefresh(3200, 1);
    }, 800);
  }

  /** 按当前数据重建列表行：分组头 + 展开的节点（受分页限制）+「再显示」。 */
  /**
   * LazyForEach 的行 key。凡是会影响这一行显示的值都必须进来：
   * 延迟、选中、折叠状态、剩余数量、节点数。少一个，那一项变了也不会重绘
   * （测速后延迟不显示、不重排，就是这么来的）。
   */
  rowKey(row: NodeRow): string {
    return row.key + '|' + String(row.delay) + '|' + String(row.moreLeft) + '|' +
      String(row.groupCount) + '|' + (row.selected ? '1' : '0') + '|' +
      (row.checked ? 'c' : 'u') + '|' + (row.groupOpen ? 'o' : 'c');
  }

  refreshRows(): void {
    this.dataSource.setRows(this.buildRows());
  }

  buildRows(): NodeRow[] {
    const rows: NodeRow[] = [];
    const groups: NodeGroup[] = this.groupList();
    groups.forEach((group: NodeGroup) => {
      const head: NodeRow = new NodeRow();
      head.kind = 0;
      // key 里带上标题：用户改名后 key 变化，LazyForEach 才会重建这一行
      head.key = 'h:' + group.key + ':' + group.title;
      head.groupKey = group.key;
      head.groupTitle = group.title;
      head.groupCount = group.indices.length;
      head.groupOpen = this.groupOpen(group);
      head.firstInBlock = true;
      // 订阅配额/到期：手动分组没有配额信息
      const quota: SubQuota | undefined = this.subQuota.get(group.key);
      head.quotaText = quota !== undefined ? Index.quotaTextOf(quota) : '';
      // 折叠着、或组里没节点：这一行就是整块的头尾
      head.lastInBlock = !head.groupOpen || group.indices.length === 0;
      rows.push(head);
      if (!head.groupOpen) {
        return;
      }
      const limit: number = this.nodeLimit(group);
      const shown: number[] = group.indices.slice(0, limit);
      const hasMore: boolean = group.indices.length > limit;
      shown.forEach((index: number, pos: number) => {
        const p: Profile = this.profiles[index];
        const row: NodeRow = new NodeRow();
        row.kind = 1;
        row.key = 'n:' + p.id;
        row.groupKey = group.key;
        row.nodeIndex = index;
        row.name = p.name;
        row.delay = p.delay;
        row.delayTested = p.delayTested !== undefined ? p.delayTested : false;
        row.speed = p.speed !== undefined ? p.speed : -1;
        row.addr = p.type.toUpperCase() + ' · ' + p.server + ':' + String(p.port);
        row.selected = index === this.selected;
        row.checked = this.checkedIds.has(p.id);
        row.firstInBlock = false;
        row.lastInBlock = !hasMore && pos === shown.length - 1;
        rows.push(row);
      });
      if (hasMore) {
        const more: NodeRow = new NodeRow();
        more.kind = 2;
        more.key = 'm:' + group.key;
        more.groupKey = group.key;
        more.moreLeft = group.indices.length - limit;
        more.firstInBlock = false;
        more.lastInBlock = true;
        rows.push(more);
      }
    });
    return rows;
  }

  /** 按 subId 归组：手动节点一组，每个订阅链接一组。结果按 profiles 引用缓存，避免每秒重绘都重算一遍。 */
  groupList(): NodeGroup[] {
    if (this.cacheProfiles === this.profiles && this.cacheSort === this.sortByDelay) {
      return this.cacheGroups;
    }
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
        // 用户改过名就用他自己的名字，否则取订阅链接的 host
        const custom: string | undefined = this.groupNames.get(key);
        group.title = custom !== undefined && custom.length > 0 ? custom : Index.subTitle(key);
        byKey.set(key, group);
        subs.push(group);
      }
      group.indices.push(index);
    });
    // 已登记但当前没有节点的分组（手动空分组、拉取失败的订阅）也显示出来，
    // 否则新建的手动分组在列表里看不到，删除入口也找不到
    this.groupNames.forEach((name: string, key: string) => {
      if (key.length === 0 || byKey.has(key)) {
        return;
      }
      const g: NodeGroup = new NodeGroup();
      g.key = key;
      g.title = name.length > 0 ? name : Index.subTitle(key);
      byKey.set(key, g);
      subs.push(g);
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
    this.cacheProfiles = this.profiles;
    this.cacheSort = this.sortByDelay;
    this.cacheGroups = result;
    return result;
  }

  /** 组内按延迟从低到高排；没测出结果（-1）或带宽测速失败的沉到组尾，其余保持原相对顺序。 */
  sortIndices(group: NodeGroup): void {
    if (!this.sortByDelay || group.indices.length < 2) {
      return;
    }
    const origin: number[] = group.indices.slice();
    // 原位置查表：几百个节点时每次比较都做 indexOf 会把排序拖成 O(n² log n)
    const pos: Map<number, number> = new Map<number, number>();
    origin.forEach((value: number, at: number) => {
      pos.set(value, at);
    });
    group.indices.sort((a: number, b: number) => {
      // 可用节点按延迟升序；测速不通的（延迟 -1 或带宽测速失败 speed=0）
      // 一律沉到组尾，用 999999 统一兜住，组内相对顺序仍按原位置稳定
      const pa0: Profile = this.profiles[a];
      const pb0: Profile = this.profiles[b];
      const da: number = (pa0.delay >= 0 && pa0.speed !== 0) ? pa0.delay : 999999;
      const db: number = (pb0.delay >= 0 && pb0.speed !== 0) ? pb0.delay : 999999;
      if (da !== db) {
        return da - db;
      }
      const pa: number = pos.get(a) !== undefined ? pos.get(a) as number : 0;
      const pb: number = pos.get(b) !== undefined ? pos.get(b) as number : 0;
      return pa - pb;
    });
  }

  /** 订阅分组的自定义名称：存 group-names.json，[[订阅URL, 名字], ...] */
  loadGroupNames(): void {
    const text: string = FileStore.readText2(this.filesDir, 'group-names.json');
    if (text.length === 0) {
      return;
    }
    try {
      const pairs: string[][] = JSON.parse(text) as string[][];
      pairs.forEach((pair: string[]) => {
        if (pair.length >= 2 && pair[0].length > 0) {
          this.groupNames.set(pair[0], pair[1]);
        }
      });
    } catch (err) {
    }
  }

  saveGroupNames(): void {
    const pairs: string[][] = [];
    this.groupNames.forEach((name: string, key: string) => {
      pairs.push([key, name]);
    });
    FileStore.writeText2(this.filesDir, 'group-names.json', JSON.stringify(pairs));
  }

  openRename(key: string): void {
    this.renameKey = key;
    const custom: string | undefined = this.groupNames.get(key);
    this.renameText = custom !== undefined ? custom : '';
  }

  closeRename(): void {
    this.renameKey = '';
    this.renameText = '';
  }

  /** 留空 = 恢复成默认的 host 名，方便随时改回去。 */
  saveRename(): void {
    const key: string = this.renameKey;
    if (key.length === 0) {
      return;
    }
    const name: string = this.renameText.trim();
    if (name.length === 0) {
      this.groupNames.delete(key);
    } else {
      this.groupNames.set(key, name);
    }
    this.saveGroupNames();
    // 分组名不进 profiles 引用，缓存得住就刷不出来，这里强制失效
    this.cacheProfiles = undefined;
    this.cacheGroups = [];
    this.closeRename();
    this.bump();
    this.toast.showToast({ message: name.length === 0 ? '已恢复默认名称' : '已重命名为「' + name + '」' });
  }

  // ---------- 分组新建 / 删除 ----------

  openNewGroup(): void {
    this.gName = '';
    this.gUrl = '';
    this.groupPanel = true;
  }

  closeNewGroup(): void {
    this.groupPanel = false;
    this.gName = '';
    this.gUrl = '';
  }

  /**
   * 保存新分组：名称必填；订阅链接留空则只建一个空分组壳（后续可在编辑面板挂节点）。
   * 链接填写时先登记分组名，再走与「导入订阅」相同的拉取流程。
   */
  saveNewGroup(): void {
    const name: string = this.gName.trim();
    const url: string = this.gUrl.trim();
    if (name.length === 0) {
      this.toast.showToast({ message: '分组名称不能为空' });
      return;
    }
    if (url.length > 0 && !url.toLowerCase().startsWith('https://')) {
      this.toast.showToast({ message: '订阅链接必须是 https 开头' });
      return;
    }
    if (url.length === 0) {
      // 手动分组：key 加 manual: 前缀，与订阅 URL 区分开
      const key: string = 'manual:' + String(Date.now());
      this.groupNames.set(key, name);
      this.saveGroupNames();
      this.cacheProfiles = undefined;
      this.cacheGroups = [];
      this.closeNewGroup();
      this.bump();
      this.toast.showToast({ message: '已创建分组「' + name + '」' });
      return;
    }
    this.groupNames.set(url, name);
    this.saveGroupNames();
    this.closeNewGroup();
    this.subInput = url;
    this.importSubscription();
  }

  /** 删除整组：先弹确认，列出组内节点数。 */
  deleteGroup(key: string): void {
    if (key.length === 0) {
      return;
    }
    const count: number = this.profiles.filter((p: Profile) => p.subId === key).length;
    const title: string = this.groupNames.get(key) !== undefined ?
      this.groupNames.get(key) as string : Index.subTitle(key);
    AlertDialog.show({
      title: '删除分组',
      message: '将删除「' + title + '」下全部 ' + String(count) + ' 个节点，不可恢复。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#C62828',
        action: () => {
          this.doDeleteGroup(key);
        }
      }
    });
  }

  private doDeleteGroup(key: string): void {
    const prev: Profile | undefined = this.selected >= 0 && this.selected < this.profiles.length
      ? this.profiles[this.selected] : undefined;
    const list: Profile[] = this.profiles.filter((p: Profile) => p.subId !== key);
    this.groupNames.delete(key);
    this.subQuota.delete(key);
    this.groupPage.delete(key);
    this.openedKeys = this.openedKeys.filter((k: string) => k !== key);
    this.closedKeys = this.closedKeys.filter((k: string) => k !== key);
    this.saveGroupNames();
    FileStore.saveSubQuota(this.filesDir, this.subQuota);
    if (prev !== undefined) {
      const hit: number = this.findProfileByIdentity(list, prev);
      this.selected = hit >= 0 ? hit : -1;
    }
    this.saveAll(list);
    this.cacheProfiles = undefined;
    this.cacheGroups = [];
    this.bump();
    this.toast.showToast({ message: '已删除分组' });
    this.reconnectSoon();
  }

  // ---------- 清空全部 ----------

  /** 一键清空：节点与订阅分组全部删除；分流规则、分应用名单保留。 */
  clearAllProfiles(): void {
    AlertDialog.show({
      title: '清空全部节点',
      message: '将删除全部节点与订阅分组（分流规则、分应用名单保留），不可恢复。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: '#C62828',
        action: () => {
          this.doClearAll();
        }
      }
    });
  }

  private doClearAll(): void {
    this.saveAll([]);
    this.groupNames.clear();
    this.subQuota.clear();
    this.groupPage.clear();
    this.openedKeys = [];
    this.closedKeys = [];
    this.saveGroupNames();
    FileStore.saveSubQuota(this.filesDir, this.subQuota);
    this.selected = -1;
    this.cacheProfiles = undefined;
    this.cacheGroups = [];
    this.bump();
    this.toast.showToast({ message: '已清空全部节点' });
    // 清空后没有可连节点：断开隧道，避免内核挂在已失效的配置上
    this.disconnect();
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

  /** 每个分组默认只渲染 PAGE_SIZE 个节点，避免几百项一次性建出来卡住主线程。 */
  static PAGE_SIZE: number = 80;

  private groupPage: Map<string, number> = new Map<string, number>();

  nodeLimit(group: NodeGroup): number {
    const page: number | undefined = this.groupPage.get(group.key);
    if (page !== undefined && page > 0) {
      return page;
    }
    return Index.PAGE_SIZE;
  }

  moreNodes(key: string): void {
    const group: NodeGroup | undefined = this.nodeGroupByKey(key);
    if (group === undefined) {
      return;
    }
    const current: number = this.nodeLimit(group);
    this.groupPage.set(group.key, current + Index.PAGE_SIZE);
    this.pageSeq = this.pageSeq + 1;
    this.bump();
  }

  nodeGroupByKey(key: string): NodeGroup | undefined {
    const groups: NodeGroup[] = this.groupList();
    for (let i = 0; i < groups.length; i++) {
      if (groups[i].key === key) {
        return groups[i];
      }
    }
    return undefined;
  }

  toggleKey(key: string): void {
    const group: NodeGroup | undefined = this.nodeGroupByKey(key);
    if (group !== undefined) {
      this.toggleGroup(group);
    }
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

  /** 复制节点分享链接到剪贴板；原始 link 缺失时按字段现场重建。 */
  copyLink(index: number): void {
    const p: Profile = this.profiles[index];
    let link: string = p.link;
    if (link.length === 0) {
      try {
        link = ProxyLink.toLink(p);
      } catch (err) {
        this.toast.showToast({ message: '该节点无法生成链接' });
        return;
      }
    }
    if (link.length === 0) {
      this.toast.showToast({ message: '该节点无法生成链接' });
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, link);
    pasteboard.getSystemPasteboard().setDataSync(data);
    this.toast.showToast({ message: '链接已复制' });
  }

  /** 带响应头的 GET：httpGet 的底层版本，订阅配额解析需要读 subscription-userinfo 头。 */
  async httpGetRaw(url: string, timeoutMs: number): Promise<FetchResult> {
    const empty: FetchResult = { body: '', headers: new Map<string, string>() };
    // 兜底：所有拉取一律只走 https。订阅与规则链接走明文时 token 和节点凭据
    // 会被同一网络里的中间人读走，响应还能被改写。出口探测两个地址本来就是 https，
    // 测速走 NAPI 的 proxyDelay 不经过这里，因此不受影响。
    if (!url.toLowerCase().startsWith('https://')) {
      hilog.error(0x0001, 'V2rayM-UI', 'httpGet refused: not https');
      return empty;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING,
        header: { 'User-Agent': 'V2rayM-harmony/1.0' }
      });
      if (resp.responseCode !== 200) {
        // 不打印 url：订阅链接里带 token，落到系统日志等于把凭据写进日志
        hilog.error(0x0001, 'V2rayM-UI', 'httpGet code=%{public}d', resp.responseCode);
        FileStore.appendLog(this.filesDir, 'httpGet non-200: ' + String(resp.responseCode));
        return empty;
      }
      const headers: Map<string, string> = new Map<string, string>();
      try {
        const rawHeader: Record<string, string> = resp.header as Record<string, string>;
        if (rawHeader !== undefined && rawHeader !== null) {
          Object.keys(rawHeader).forEach((k: string) => {
            headers.set(k.toLowerCase(), String(rawHeader[k]));
          });
        }
      } catch (err) {
      }
      // 某些版本 result 会是 ArrayBuffer，直接 String() 只会得到 "[object ArrayBuffer]"
      const raw: string | ArrayBuffer = resp.result as string | ArrayBuffer;
      let body: string;
      if (typeof raw === 'string') {
        body = raw as string;
      } else {
        const decoder = util.TextDecoder.create('utf-8');
        body = decoder.decodeToString(new Uint8Array(raw as ArrayBuffer));
      }
      return { body: body, headers: headers };
    } catch (err) {
      const be = err as BusinessError;
      hilog.error(0x0001, 'V2rayM-UI', 'httpGet fail code=%{public}d msg=%{public}s',
        be.code !== undefined ? be.code : -1, String(be.message));
      FileStore.appendLog(this.filesDir, 'httpGet err: code=' +
        String(be.code !== undefined ? be.code : -1) + ' msg=' + String(be.message));
      return empty;
    } finally {
      req.destroy();
    }
  }

  async httpGet(url: string, timeoutMs: number): Promise<string> {
    const res: FetchResult = await this.httpGetRaw(url, timeoutMs);
    return res.body;
  }

  /**
   * 解析 subscription-userinfo 响应头。格式：
   * upload=..., download=..., total=..., expire=...（expire 为 Unix 秒，可缺省）。
   * 任一字段缺失按 0 处理；整头缺失返回 undefined。
   */
  private static parseSubQuota(headerValue: string): SubQuota | undefined {
    if (headerValue.trim().length === 0) {
      return undefined;
    }
    const quota: SubQuota = { upload: 0, download: 0, total: 0, expire: 0 };
    const parts: string[] = headerValue.split(',');
    let hit: boolean = false;
    parts.forEach((part: string) => {
      const kv: string[] = part.trim().split('=');
      if (kv.length !== 2) {
        return;
      }
      const key: string = kv[0].trim().toLowerCase();
      const num: number = Number.parseInt(kv[1].trim());
      const value: number = Number.isNaN(num) ? 0 : num;
      if (key === 'upload') { quota.upload = value; hit = true; }
      else if (key === 'download') { quota.download = value; hit = true; }
      else if (key === 'total') { quota.total = value; hit = true; }
      else if (key === 'expire') { quota.expire = value; hit = true; }
    });
    return hit ? quota : undefined;
  }

  /** 落盘并缓存一组订阅配额；url 为空不写。 */
  private saveQuota(url: string, quota: SubQuota | undefined): void {
    if (url.length === 0) {
      return;
    }
    if (quota === undefined) {
      return;
    }
    this.subQuota.set(url, quota);
    FileStore.saveSubQuota(this.filesDir, this.subQuota);
  }

  /** 配额展示文案：已用/总量 + 剩余；无总量只显示已用；到期时间另起一段。 */
  private static quotaTextOf(quota: SubQuota): string {
    const used: number = quota.upload + quota.download;
    let text: string;
    if (quota.total > 0) {
      const remain: number = Math.max(0, quota.total - used);
      text = '已用 ' + Index.human(used) + ' / ' + Index.human(quota.total) +
        ' · 剩 ' + Index.human(remain);
    } else {
      text = '已用 ' + Index.human(used);
    }
    if (quota.expire > 0) {
      const d: Date = new Date(quota.expire * 1000);
      const mm: string = String(d.getMonth() + 1).padStart(2, '0');
      const dd: string = String(d.getDate()).padStart(2, '0');
      text += ' · 到期 ' + d.getFullYear() + '-' + mm + '-' + dd;
    }
    return text;
  }

  /**
   * 下载测速专用：只关心「实际下载了多少字节、用了多久」，不做内容解码。
   * 返回 [字节数, 耗时毫秒]；失败返回 [0, 耗时]。只走 https（理由同 httpGet）。
   */
  async httpGetBytes(url: string, timeoutMs: number): Promise<number[]> {
    const started: number = Date.now();
    if (!url.toLowerCase().startsWith('https://')) {
      return [0, 0];
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: { 'User-Agent': 'V2rayM-harmony/1.0' }
      });
      const ms: number = Date.now() - started;
      if (resp.responseCode !== 200) {
        FileStore.appendLog(this.filesDir, 'speedtest non-200: ' + String(resp.responseCode));
        return [0, ms];
      }
      const raw: ArrayBuffer = resp.result as ArrayBuffer;
      let bytes: number = 0;
      if (raw !== undefined && raw !== null) {
        bytes = raw.byteLength;
      }
      return [bytes, ms];
    } catch (err) {
      const be = err as BusinessError;
      FileStore.appendLog(this.filesDir, 'speedtest err: code=' +
        String(be.code !== undefined ? be.code : -1) + ' msg=' + String(be.message));
      return [0, Date.now() - started];
    } finally {
      req.destroy();
    }
  }

  /** 测速端点预检：HEAD 只看状态码，不拉内容，成本远低于直接下载。 */
  async httpHead(url: string, timeoutMs: number): Promise<boolean> {
    if (!url.toLowerCase().startsWith('https://')) {
      return false;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.HEAD,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        header: { 'User-Agent': 'V2rayM-harmony/1.0' }
      });
      const code: number = resp.responseCode;
      return code === 200 || code === 206;
    } catch (err) {
      return false;
    } finally {
      req.destroy();
    }
  }

  /**
   * 挑一个当前节点真能访问的测速端点，返回下标；全都不通返回 -1。
   * 并发 HEAD 三个小文件候选，取第一个 200 的；全都不通时再顺序 GET 兜底
   * （有些 CDN 不接受 HEAD）。
   */
  /** 按当前测速包大小设置，返回第 ti 个候选端点的计时下载地址。 */
  private speedTestUrl(ti: number, bytes?: number): string {
    const n: number = bytes !== undefined ? bytes : this.settings.speedBytes;
    if (ti === 0) {
      return 'https://speed.cloudflare.com/__down?bytes=' + String(n);
    }
    if (ti === 1) {
      return n >= 10485760 ? 'https://speed.hetzner.de/10MB.bin' : 'https://speed.hetzner.de/1MB.bin';
    }
    return n >= 10485760 ? 'https://proof.ovh.net/files/10Mb.dat' : 'https://proof.ovh.net/files/1Mb.dat';
  }

  /**
   * 并发下载：conns 个连接同时拉同一 URL，汇总字节数，墙钟取最慢一枪。
   * 返回 [总字节, 墙钟毫秒]。用于 Speedtest 式多连接吞吐测量。
   */
  private async parallelDownload(url: string, conns: number, timeoutMs: number): Promise<number[]> {
    const started: number = Date.now();
    const workers: Promise<number[]>[] = [];
    for (let i = 0; i < conns; i++) {
      workers.push(this.httpGetBytes(url, timeoutMs));
    }
    const results: number[][] = await Promise.all(workers);
    let total: number = 0;
    let maxMs: number = 0;
    results.forEach((r: number[]) => {
      total = total + r[0];
      if (r[1] > maxMs) {
        maxMs = r[1];
      }
    });
    const wall: number = Math.max(maxMs, Date.now() - started);
    return [total, wall];
  }

  private async pickSpeedIndex(): Promise<number> {
    const a: Promise<boolean> = this.httpHead(SPEED_PROBES[0], 4000);
    const b: Promise<boolean> = this.httpHead(SPEED_PROBES[1], 4000);
    const c: Promise<boolean> = this.httpHead(SPEED_PROBES[2], 4000);
    const ok: boolean[] = await Promise.all([a, b, c]);
    for (let i = 0; i < ok.length; i++) {
      if (ok[i]) {
        FileStore.appendLog(this.filesDir, 'speedtest endpoint #' + String(i) + ': ' + this.speedTestUrl(i));
        return i;
      }
    }
    FileStore.appendLog(this.filesDir, 'speedtest: no endpoint passed HEAD, try GET fallback');
    // 只试第一个端点、10s 上界：三个都轮流试要 24s，用户等不起（真机 09:48 实测 28s 才出结果）
    const small: number[] = await this.httpGetBytes(SPEED_PROBES[0], 10000);
    if (small[0] > 0) {
      return 0;
    }
    return -1;
  }

  /**
   * 带宽测速（参考 v2rayH 的 Speedtest 式做法，做简化版）：
   * 选端点 → 小文件预热 → 大文件计时 → 换算 KB/s。
   * 必须已连接：未连接时请求走本机宽带，测出来的是宽带而不是节点。
   */
  async speedTestCurrent(): Promise<void> {
    if (this.speedBusy) {
      return;
    }
    if (!this.running) {
      this.toast.showToast({ message: '请先连接节点再测带宽' });
      return;
    }
    if (this.selected < 0 || this.selected >= this.profiles.length) {
      return;
    }
    const idx: number = this.selected;
    const name: string = this.profiles[idx].name;
    this.speedBusy = true;
    this.speedInfo = '测速中…';
    FileStore.appendLog(this.filesDir, 'speedtest start: ' + name);
    if (!this.speedEligible(this.profiles[idx])) {
      FileStore.appendLog(this.filesDir, 'speedtest warn: ' + name + ' 延迟不通，结果可能不准');
    }
    try {
      const ti: number = await this.pickSpeedIndex();
      if (ti < 0) {
        this.markSpeedFail(idx, name, 'no reachable endpoint');
        return;
      }
      // 预热：先把 TCP/TLS 慢启动跑掉，这一枪不计时
      await this.httpGetBytes(SPEED_PROBES[ti], 12000);
      let got: number[];
      if (ti === 0) {
        // Cloudflare 端点支持 bytes 参数：4 连接各取 1/4，总流量与单连接相当，
        // 多连接并发吞吐更接近 Speedtest 式实测；固定文件端点不支持分片，退回单连接
        const per: number = Math.max(102400, Math.floor(this.settings.speedBytes / 4));
        got = await this.parallelDownload(this.speedTestUrl(ti, per), 4, 20000);
      } else {
        got = await this.httpGetBytes(this.speedTestUrl(ti), 20000);
      }
      if (got[0] <= 0) {
        // 大文件超时（慢节点下 5MB 可能读不完）：退回小文件计时，宁可精度低也别没结果
        got = await this.httpGetBytes(SPEED_PROBES[ti], 12000);
      }
      const bytes: number = got[0];
      const ms2: number = got[1];
      if (bytes <= 0 || ms2 <= 0) {
        this.markSpeedFail(idx, name, 'download timeout');
        return;
      }
      const kbPerSec: number = Math.round(bytes / 1024 * 1000 / ms2);
      // 选中节点可能在测速期间被切走：只回写到发起时的那个节点
      for (let i = 0; i < this.profiles.length; i++) {
        const p: Profile = this.profiles[i];
        if (p.name === name && i === idx) {
          p.speed = kbPerSec;
          break;
        }
      }
      FileStore.saveProfiles(this.filesDir, this.profiles);
      this.bump();
      const text: string = Index.speedText(kbPerSec);
      this.speedInfo = text;
      FileStore.appendLog(this.filesDir, 'speedtest done: ' + name + ' ' + text);
      this.toast.showToast({ message: name + ' 带宽 ' + text });
    } finally {
      this.speedBusy = false;
    }
  }

  /**
   * 是否适合进入下载测速：延迟测速已跑过且不通（-1）的节点默认排除，
   * 避免在死节点上白跑大文件下载。手动单点测速仍可强制发起。
   */
  private speedEligible(p: Profile): boolean {
    return !(p.delayTested && p.delay < 0);
  }

  /** 下载速率文案：>= 1024KB/s 换成 MB/s */
  static speedText(kb: number): string {
    if (kb < 0) {
      return '';
    }
    if (kb === 0) {
      return '不通';
    }
    if (kb >= 1024) {
      return (Math.round(kb / 1024 * 10) / 10).toFixed(1) + 'MB/s';
    }
    return String(kb) + 'KB/s';
  }

  /**
   * 测速失败的节点留下 0 标记（区别于 -1 未测）：真机 11-14 09:48 那个
   * 台湾节点能握手、出口探测第 5 枪也能通，但累计下行只有 15KB、三个测速
   * 端点全挂 —— 这种「能连不能跑」的节点必须能在列表里一眼认出来。
   */
  private markSpeedFail(idx: number, name: string, reason: string): void {
    for (let i = 0; i < this.profiles.length; i++) {
      if (i === idx && this.profiles[i].name === name) {
        this.profiles[i].speed = 0;
        break;
      }
    }
    FileStore.saveProfiles(this.filesDir, this.profiles);
    this.bump();
    this.speedInfo = '不通';
    FileStore.appendLog(this.filesDir, 'speedtest fail: ' + name + ' (' + reason + ')');
    this.toast.showToast({ message: name + ' 测速不通' });
  }

  /**
   * 出口 IP 归属。已连接时代理生效、本应用自身没被 protect，
   * 这里的 HTTP 请求就是经节点出去的，返回的 IP 即节点出口，不是本地宽带。
   */
  scheduleExitRefresh(delayMs: number, attempt: number): void {
    setTimeout(() => {
      this.refreshExit(attempt);
    }, delayMs);
  }

  async refreshExit(attempt: number): Promise<void> {
    const seq: number = ++this.exitSeq;
    this.exitBusy = true;
    // 刚点连接 / 刚切节点时 running 还没翻过来，先等隧道，最多约 4 秒
    let waited: number = 0;
    while (!this.running && waited < 5 && seq === this.exitSeq) {
      await Index.sleep(600);
      waited++;
    }
    if (seq !== this.exitSeq) {
      return;
    }
    if (!this.running) {
      // 等待窗口内隧道没起来（断开中 / 刚断开）：此时请求走的是家宽，
      // 探出来的会是「中国 江苏」这种直连出口。宁可显示空，也不能把它当成节点出口
      // —— 这正是之前界面一直停在「中国江苏」的原因（09:32:23 那枪）。
      this.exitBusy = false;
      if (this.exitInfo.length > 0) {
        this.exitInfo = '';
      }
      return;
    }
    let text: string = '';
    let suspect: boolean = false;
    if (this.running) {
      const res: ExitProbe = await this.probeExit();
      text = res.text;
      suspect = res.suspect;
      FileStore.appendLog(this.filesDir, 'exit probe #' + String(attempt) +
        ' suspect=' + String(suspect) + ' -> ' + text);
    }
    if (seq !== this.exitSeq) {
      return;
    }
    // 拿到任一非空结果（真出口或归属判定）都说明探测链路通了，清空连续失败计数
    if (text.length > 0) {
      this.exitEmptyStreak = 0;
      this.exitBlocked = false;
    }
    if (text.length > 0 && !suspect) {
      // 非大陆归属 = 真出口，直接显示
      this.exitBusy = false;
      if (this.exitInfo !== text) {
        this.exitInfo = text;
      }
      return;
    }
    // 兜底：连续 12 枪（约 1 分钟）仍是中国大陆归属，说明这一枪不是「VPN 刚被回收、
    // 走了家宽」的短暂窗口，而是用户确实选了国内节点（或归属库误判）。照实显示，
    // 否则界面会永远停在「正在测出口 IP…」且无法手动重测。
    if (text.length > 0 && attempt >= 12) {
      FileStore.appendLog(this.filesDir, 'exit probe accept suspect after ' +
        String(attempt) + ' attempts: ' + text);
      this.exitBusy = false;
      if (this.exitInfo !== text) {
        this.exitInfo = text;
      }
      return;
    }
    // 空结果 = 隧道还没通；归属中国大陆 = 这一枪走了家宽直连（VPN 刚被回收那几秒会这样）。
    // 两种都不能显示成出口。实测冷启动时节点的中转链路要 20 秒以上才通，前几枪全是超时，
    // 所以前 6 枪按 2.5~4 秒紧凑重试，之后放慢到 8 秒继续重试（期间界面保持「正在测」）。
    if (this.running) {
      // 连续空结果达到上限：当前节点出站不通（死节点 / 被干扰），停止重试并提示换节点；
      // 否则在死节点上会每几秒无限转圈。手动点出口卡再重新探测。
      this.exitEmptyStreak++;
      if (this.exitEmptyStreak >= Index.EXIT_EMPTY_LIMIT) {
        FileStore.appendLog(this.filesDir, 'exit probe blocked after ' +
          String(this.exitEmptyStreak) + ' empty attempts, stop retrying');
        this.exitBusy = false;
        this.exitBlocked = true;
        // 记下熔断时刻与当时的累计下行：60s 后由 tickExitBlocked 判断是节点死
        // 还是后台探测被冻结（真机 03:32 熔断后白卡了 4 小时 37 分）
        this.exitBlockedAt = Date.now();
        this.exitBlockedDown = this.lastTotalDown;
        this.exitInfo = '出口探测超时，正在确认节点状态…';
        return;
      }
      const fast: boolean = attempt < 6;
      const delayMs: number = fast ? (text.length === 0 ? 2500 : 4000) : 8000;
      this.scheduleExitRefresh(delayMs, attempt + 1);
      return;
    }
    this.exitBusy = false;
    this.exitBlocked = false;
    if (this.exitInfo.length > 0) {
      this.exitInfo = '';
    }
  }

  /**
   * 长时任务保活统一委托给应用级单例 KeepAliveManager。
   * 旧实现把 bgRunning 放在组件实例里，只在 readState 的 false→true 边沿申请，
   * 真机 14:10/14:14 重连时该边沿丢失，整个后台期没有长时任务，扩展被回收。
   * 现在由单例以状态驱动方式统一申请、复核与释放。
   */
  private requestKeepAlive(): void {
    if (!this.settings.keepAlive) {
      return;
    }
    const uiContext = getContext(this) as common.UIAbilityContext;
    KeepAliveManager.getInstance().ensureRunning(uiContext, true)
      .catch((err: Error) => {
        FileStore.appendLog(this.filesDir, 'requestKeepAlive failed: ' + err.message);
      });
  }

  /** 低频复核：管理器内部 ≥30s 节流 + 冷却，force=false。 */
  private ensureKeepAlive(): void {
    if (!this.settings.keepAlive) {
      return;
    }
    const uiContext = getContext(this) as common.UIAbilityContext;
    KeepAliveManager.getInstance().ensureRunning(uiContext, false)
      .catch((err: Error) => {
        FileStore.appendLog(this.filesDir, 'ensureKeepAlive failed: ' + err.message);
      });
  }

  private releaseKeepAlive(): void {
    const uiContext = getContext(this) as common.UIAbilityContext;
    KeepAliveManager.getInstance().stop(uiContext)
      .catch((err: Error) => {
        FileStore.appendLog(this.filesDir, 'releaseKeepAlive failed: ' + err.message);
      });
  }

  async probeExit(): Promise<ExitProbe> {
    // 只打 v4-only 主源。启动初期隧道/DNS 未就绪时主源会失败，此时返回空，
    // 由上层 refreshExit 在 2.5 秒后自动重试——不要立刻 fallback 到双栈端点，
    // 那时候 mihomo 规则还没完全生效，fallback 请求可能走偏，返回错误的出口 IP
    // （实测：启动 5 秒内 fallback 到 api.ip.sb，拿到一个不属于选中节点的 Azure IP）。
    const primary: string = await this.httpGet(EXIT_URL_PRIMARY, 6000);
    const geoProbe: ExitProbe | undefined = Index.geoJsonToProbe(primary);
    if (geoProbe !== undefined) {
      FileStore.appendLog(this.filesDir, 'geoip raw: ' +
        primary.replace(/[\r\n]+/g, ' ').substring(0, 120));
      // 交叉校验：主源报了这个 IP，再问另一家 v4-only 端点看到的源地址。
      // 注意：有些机场节点是多后端负载均衡（实测同一条节点，不同出口 IP：
      // ip.sb 看到 Azure SG，另一家看到 First Server SG，都是真出口），
      // 两家不一致并不代表探测走偏——所以只记日志留证，不拦截显示。
      const crossRaw: string = await this.httpGet(EXIT_URL_CROSS, 6000);
      const cross: string = crossRaw.trim();
      FileStore.appendLog(this.filesDir, 'cross check: primary=' + geoProbe.ip +
        ' cross=' + (cross.length > 0 ? cross : '(empty)') +
        (cross.length > 0 && cross !== geoProbe.ip ? ' (multi-backend node, exit varies)' : ''));
      return geoProbe;
    }
    FileStore.appendLog(this.filesDir, 'geoip primary empty, will retry (len=' +
      String(primary.length) + ')');
    return { text: '', suspect: false, ip: '' };
  }

  /** 解析 geoip JSON（api.ip.sb/geoip），失败返回 undefined */
  private static geoJsonToProbe(raw: string): ExitProbe | undefined {
    if (raw.length === 0) {
      return undefined;
    }
    try {
      const geo = JSON.parse(raw) as ExitGeo;
      const ip: string = geo.ip !== undefined ? geo.ip : '';
      if (ip.length === 0) {
        return undefined;
      }
      const code: string = geo.country_code !== undefined ? geo.country_code.toUpperCase() : '';
      const parts: string[] = [];
      if (geo.country !== undefined && geo.country.length > 0) {
        parts.push(geoCn(geo.country));
      }
      if (geo.region !== undefined && geo.region.length > 0) {
        parts.push(geoCn(geo.region));
      }
      if (geo.city !== undefined && geo.city.length > 0) {
        parts.push(geoCn(geo.city));
      }
      const loc2: string = Index.shortLoc(parts.join(' '));
      const body: string = '出口 ' + Index.shortIp(ip) + (loc2.length > 0 ? ' · ' + loc2 : '');
      return { text: body, suspect: code === 'CN', ip: ip };
    } catch (err) {
      return undefined;
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
    // 重建前记住当前选中节点身份。同源节点被清空后再追加新节点，数组下标会重排；
    // 若只按下标钳制，selected 会漂移到列表里同下标的另一个节点（可能不通）。
    const prev: Profile | undefined = this.selected >= 0 && this.selected < this.profiles.length
      ? this.profiles[this.selected] : undefined;
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
    // 订阅返回空、或所有行都解析失败：绝不落盘。
    // 否则 filter 掉整组旧节点后 saveAll 会把该订阅清空并写进磁盘，一次网络抖动就丢节点。
    // 返回 0（而非 -1）：调用方据此提示「已保留原节点」；列表根本没变，显式把 selectedKept 归位为 true，
    // 避免沿用上一轮的陈旧值让 importSubscription 误触发重连。
    if (added === 0) {
      this.selectedKept = true;
      return 0;
    }
    this.saveAll(list);
    this.selectedKept = false;
    if (prev !== undefined) {
      const hit: number = this.findProfileByIdentity(list, prev);
      if (hit >= 0) {
        this.selected = hit;
        const cur: Profile = list[hit];
        // 只有 server+port+uuid 全等才算原节点原样保留；仅 server+port 命中说明凭据/端口变了，仍需重连
        this.selectedKept = cur.server === prev.server && cur.port === prev.port &&
          (cur.uuid || '') === (prev.uuid || '');
      } else {
        this.selected = 0;
      }
    }
    return added;
  }

  /**
   * 在新列表里按节点身份找回原选中项：优先 server+port+uuid，退到 server+port，再退到 name；找不到返回 -1。
   */
  private findProfileByIdentity(list: Profile[], prev: Profile): number {
    for (let i = 0; i < list.length; i++) {
      const p: Profile = list[i];
      if (p.server === prev.server && p.port === prev.port && (p.uuid || '') === (prev.uuid || '')) {
        return i;
      }
    }
    for (let i = 0; i < list.length; i++) {
      const p: Profile = list[i];
      if (p.server === prev.server && p.port === prev.port) {
        return i;
      }
    }
    for (let i = 0; i < list.length; i++) {
      if (list[i].name === prev.name) {
        return i;
      }
    }
    return -1;
  }

  /** 订阅导入序号：同一毫秒内多次导入也不会撞 id。 */
  static subSeqSeed: number = 0;
  static subSeq(): number {
    Index.subSeqSeed = Index.subSeqSeed + 1;
    return Index.subSeqSeed;
  }

  /** 订阅导入：支持 base64 或明文的一行一个分享链接，重导时覆盖同源节点。 */
  async importSubscription(): Promise<void> {
    if (this.updatingAll) {
      return;
    }
    const url: string = this.subInput.trim();
    // 只接受 https：明文 http 会把订阅 token 和节点凭据暴露给同一网络里的任何中间人，
    // 对方还能改写返回内容，塞进自己的节点或把域名改成直连。
    if (url.startsWith('http://')) {
      this.toast.showToast({ message: '订阅地址必须用 https，明文 http 会泄露 token' });
      return;
    }
    if (!url.startsWith('https://')) {
      this.toast.showToast({ message: '请填写 https 订阅链接' });
      return;
    }
    this.statusText = '正在拉取订阅…';
    const fetched: FetchResult =
      await this.httpGetRaw(url, 60000);
    const body: string = fetched.body;
    // 拉取期间可能开始了「全部更新」：已飞行的这次导入不能再 applySubContent，
    // 否则会在批量合并阶段多写一次盘并可能多触发一次重连。同时恢复上面设的进度文案。
    if (this.updatingAll) {
      this.statusText = this.running ? '已连接' : '未连接';
      return;
    }
    if (body.trim().length === 0) {
      this.toast.showToast({ message: '订阅拉取失败，检查链接或网络' });
      this.statusText = this.running ? '已连接' : '未连接';
      return;
    }
    const added: number = this.applySubContent(url, body);
    // 配额头只在内容解析成功后落盘：失败的响应不该覆盖上次记下的配额
    if (added > 0) {
      this.saveQuota(url, Index.parseSubQuota(fetched.headers.get('subscription-userinfo') || ''));
    }
    this.statusText = this.running ? '已连接' : '未连接';
    if (added < 0) {
      this.toast.showToast({ message: '订阅内容无法解析（非 base64 也非链接）' });
      return;
    }
    // 解析出 0 条：applySubContent 已保留旧节点且不落盘，别关抽屉、别误报导入成功、更别重连
    if (added === 0) {
      this.toast.showToast({ message: '订阅内容为空，未导入任何节点' });
      return;
    }
    this.drawerOpen = false;
    this.toast.showToast({ message: '订阅导入 ' + added + ' 个节点' });
    // 原选中节点原样保留时，当前隧道配置没变，不必断开重连
    if (!this.selectedKept) {
      this.reconnectSoon();
    }
  }

  /** 单个订阅分组更新：只刷新这个订阅的节点，其它分组不动。 */
  async refreshGroup(url: string): Promise<void> {
    if (this.updatingAll) {
      this.toast.showToast({ message: '正在全部更新，稍后再试' });
      return;
    }
    // 手动分组没有订阅链接，无需刷新；老版本允许 http 导入的订阅会落到这里
    if (url.startsWith('manual:')) {
      this.toast.showToast({ message: '手动分组没有订阅链接' });
      return;
    }
    if (!url.toLowerCase().startsWith('https://')) {
      this.toast.showToast({ message: '该订阅是明文 http，已拒绝更新；请改用 https 地址重新导入' });
      return;
    }
    this.statusText = '正在更新订阅…';
    const fetched: FetchResult =
      await this.httpGetRaw(url, 60000);
    const body: string = fetched.body;
    // 拉取期间可能开始了「全部更新」：已飞行的单组更新必须与批量合并互斥，
    // 否则会多写一次盘并可能多触发一次重连。同时恢复上面设的进度文案。
    if (this.updatingAll) {
      this.statusText = this.running ? '已连接' : '未连接';
      return;
    }
    if (body.trim().length === 0) {
      this.toast.showToast({ message: '订阅更新失败，检查网络' });
      this.statusText = this.running ? '已连接' : '未连接';
      return;
    }
    const added: number = this.applySubContent(url, body);
    if (added > 0) {
      this.saveQuota(url, Index.parseSubQuota(fetched.headers.get('subscription-userinfo') || ''));
    }
    this.statusText = this.running ? '已连接' : '未连接';
    // -1 是 base64 解码失败、0 是解析出 0 条节点，语义不同，分开提示别混淆
    if (added < 0) {
      this.toast.showToast({ message: '订阅内容无法解析' });
      return;
    }
    // added === 0：applySubContent 已保留旧节点且不落盘，别再误报「已更新 0 个节点」
    if (added === 0) {
      this.toast.showToast({ message: '订阅内容为空，已保留原节点' });
      return;
    }
    this.toast.showToast({ message: '已更新 ' + added + ' 个节点' });
    // 原选中节点原样保留时，当前隧道配置没变，不必断开重连
    if (!this.selectedKept) {
      this.reconnectSoon();
    }
  }

  /**
   * 纯解析订阅内容：把 body 解成节点数组，不碰 this.profiles、不落盘、不做名称去重。
   * 名称去重留到合并阶段统一做；返回空数组表示这次拉取或解析失败，合并时保留旧节点不动。
   */
  private parseSubNodes(url: string, body: string, idSeed: string): Profile[] {
    // 拉取失败/空响应直接判定该订阅失败，不必再对空串做一次无意义的 base64 解码
    if (body.trim().length === 0) {
      return [];
    }
    let content: string = body;
    if (!content.includes('://')) {
      try {
        content = ProxyLink.decodeBase64(content);
      } catch (err) {
        return [];
      }
    }
    const nodes: Profile[] = [];
    const lines: string[] = content.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const text: string = lines[i].trim();
      if (text.length === 0) {
        continue;
      }
      try {
        const fresh: Profile = ProxyLink.toProfile(text, idSeed + '_' + String(nodes.length), url);
        nodes.push(fresh);
      } catch (err) {
        // 单行链接格式不对就跳过，不影响其它行
      }
    }
    return nodes;
  }

  /**
   * 「全部更新」：并发拉取所有订阅 → 串行合并到临时数组 → 一次落盘 → 一次身份找回 → 一次重连判定。
   * 刻意不循环调用 refreshGroup：后者每个订阅都弹 toast、改 statusText、末尾 reconnectSoon，
   * N 个订阅会造成 N 次真实断线重连；applySubContent 每次都 filter 全量 + saveAll 重写整个
   * profiles + bump 重建列表，批量写会互相覆盖；且空内容时会把该组旧节点清空落盘。
   */
  async updateAllSubscriptions(): Promise<void> {
    if (this.updatingAll) {
      return;
    }
    if (this.testing) {
      this.toast.showToast({ message: '正在测速，稍后再更新订阅' });
      return;
    }
    // 直接遍历 profiles 按 subId 去重：groupList 依赖缓存且受折叠/分页影响，不能用于批量
    const seen: Set<string> = new Set<string>();
    const allUrls: string[] = [];
    for (let i = 0; i < this.profiles.length; i++) {
      const sub: string = this.profiles[i].subId !== undefined ? this.profiles[i].subId : '';
      if (sub.length === 0 || seen.has(sub)) {
        continue;
      }
      seen.add(sub);
      allUrls.push(sub);
    }
    if (allUrls.length === 0) {
      this.toast.showToast({ message: '还没有订阅，请先在左侧「订阅与导入」里添加' });
      return;
    }
    // 与 refreshGroup 语义一致：非 https 的旧订阅只计入跳过，绝不发起明文请求
    const targets: string[] = [];
    let skipped: number = 0;
    for (let i = 0; i < allUrls.length; i++) {
      if (allUrls[i].toLowerCase().startsWith('https://')) {
        targets.push(allUrls[i]);
      } else {
        skipped++;
      }
    }
    if (targets.length === 0) {
      this.toast.showToast({ message: '订阅均非 https 地址，请改用 https 重新导入' });
      return;
    }

    this.updatingAll = true;
    this.updDone = 0;
    this.updTotal = targets.length;
    this.updInfo = '已处理 0 · 待更新 ' + String(this.updTotal);
    let okSubs: number = 0;
    let failed: number = 0;
    let addedTotal: number = 0;

    try {
      // 并发拉取上限 3：照抄 runPool 的 cursor / worker / Promise.all 结构
      const bodies: Map<string, string> = new Map<string, string>();
      const quotaHeaders: Map<string, Map<string, string>> =
        new Map<string, Map<string, string>>();
      const cursor: number[] = [0];
      const emptyRaw: FetchResult = { body: '', headers: new Map<string, string>() };
      const worker = async (): Promise<void> => {
        while (true) {
          const at: number = cursor[0];
          cursor[0] = cursor[0] + 1;
          if (at >= targets.length) {
            return;
          }
          const url: string = targets[at];
          // 单请求超时：给每个 URL 一个确定上界，httpGet 的 promise 永不 settle 时
          // 61s 后返回 '' 判为该订阅失败，worker 继续推进，Promise.all 与 finally 必然执行。
          // 不用整体 race（超时后 worker 仍在飞行会游离写 bodies/updDone），也不加看门狗定时器。
          const timeout: Promise<FetchResult> =
            Index.sleep(61000).then((): FetchResult => emptyRaw);
          const fetched: FetchResult =
            await Promise.race([this.httpGetRaw(url, 60000), timeout]);
          bodies.set(url, fetched.body);
          quotaHeaders.set(url, fetched.headers);
          this.updDone = this.updDone + 1;
          // 「已处理」含拉取失败的请求，不表示成功；成功订阅数在汇总 toast 里单独统计
          this.updInfo = '已处理 ' + String(this.updDone) + ' · 待更新 ' +
            String(this.updTotal - this.updDone);
        }
      };
      const workers: Promise<void>[] = [];
      const count: number = Math.min(3, targets.length);
      for (let w = 0; w < count; w++) {
        workers.push(worker());
      }
      await Promise.all(workers);

      // prev 必须在拉取完成后才取：拉取期间状态可能已被用户操作改变
      const prev: Profile | undefined = this.selected >= 0 && this.selected < this.profiles.length
        ? this.profiles[this.selected] : undefined;

      // 串行合并到临时数组，全程不碰 this.profiles、不落盘
      let list: Profile[] = this.profiles.slice();
      const seq: string = String(Date.now()) + '_' + Index.subSeq();
      for (let i = 0; i < targets.length; i++) {
        const url: string = targets[i];
        const raw: string | undefined = bodies.get(url);
        const body: string = raw !== undefined ? raw as string : '';
        // 每个订阅用独立的 id 前缀，避免不同订阅的节点 id 相撞
        const nodes: Profile[] = this.parseSubNodes(url, body, seq + '_' + String(i));
        if (nodes.length === 0) {
          failed++;
          // 只记序号，不写订阅 URL：URL 带 token（见 httpGet 的注释）
          FileStore.appendLog(this.filesDir,
            'updateAll: sub #' + String(i) + ' fetch/parse empty, keep old nodes');
          continue;
        }
        list = list.filter((p: Profile) => p.subId !== url);
        for (let n = 0; n < nodes.length; n++) {
          const fresh: Profile = nodes[n];
          fresh.name = this.uniqueName(list, fresh.name);
          list.push(fresh);
        }
        const headers: Map<string, string> | undefined = quotaHeaders.get(url);
        this.saveQuota(url, Index.parseSubQuota(
          headers !== undefined ? (headers.get('subscription-userinfo') || '') : ''));
        okSubs++;
        addedTotal += nodes.length;
      }

      // 一次落盘：没有任何订阅成功时绝不写盘
      if (okSubs > 0) {
        // 前置计算：先只针对临时数组 list 找回身份并定好 selected，再调 saveAll。
        // saveAll 内部的 bump → refreshRows 会用当时的 selected 生成行 key 与 row.selected；
        // 若放到 saveAll 之后才赋值，选中高亮会停在钳制后的旧下标，直到下次刷新才纠正。
        // 这段同步代码中间没有 await，this.profiles 短暂仍是旧数组也不会触发 UI 刷新。
        let hit: number = -1;
        if (prev !== undefined) {
          hit = this.findProfileByIdentity(list, prev);
          this.selected = hit >= 0 ? hit : 0;
        }
        this.saveAll(list);
        // 一次重连判定，语义与 applySubContent 一致：
        // 仅 server+port 或 name 命中说明凭据变了，仍需重连
        if (prev !== undefined) {
          let kept: boolean = false;
          if (hit >= 0) {
            const cur: Profile = list[hit];
            kept = cur.server === prev.server && cur.port === prev.port &&
              (cur.uuid || '') === (prev.uuid || '');
          }
          this.selectedKept = kept;
          if (!kept) {
            this.reconnectSoon();
          }
        }
      } else {
        // 全部失败：列表根本没变，selectedKept 归位为 true（= 原选中节点原样保留、不必重连），
        // 否则残留的 false 会让后续操作误触发一次重连
        this.selectedKept = true;
      }

      // 全程只弹一个汇总 toast，互斥提示不在此路径内
      let msg: string = '';
      const bad: number = failed + skipped;
      if (okSubs === 0) {
        msg = '订阅更新失败，已保留原有节点 (' + String(bad) + ' 个失败/跳过)';
      } else {
        // 分母用 allUrls.length（含被跳过的明文 http 订阅），避免「3/3 个订阅 (2 个失败/跳过)」
        // 这种自相矛盾的文案；进度卡 updTotal 仍只反映实际发起的请求数 targets.length。
        msg = '已更新 ' + String(okSubs) + '/' + String(allUrls.length) + ' 个订阅 · 共 ' +
          String(addedTotal) + ' 个节点';
        if (bad > 0) {
          msg += ' (' + String(bad) + ' 个失败/跳过)';
        }
        // 内核只在启动时读一次配置：选中节点未变时不重连，新增节点要下次重连才生效
        msg += '，新节点下次重连后生效';
      }
      this.toast.showToast({ message: msg });
      FileStore.appendLog(this.filesDir, 'updateAll: ok=' + String(okSubs) + ' failed=' +
        String(failed) + ' skipped=' + String(skipped) + ' nodes=' + String(addedTotal));
    } catch (err) {
      // 只记固定文案，不写订阅 URL
      FileStore.appendLog(this.filesDir, 'updateAll: unexpected error');
      this.toast.showToast({ message: '订阅更新异常，已保留原有节点' });
    } finally {
      this.updatingAll = false;
      this.updInfo = '';
    }
  }

  /** 单个分组测速：只测这一组的节点。开跑前先弹确认框。 */
  async testGroup(group: NodeGroup): Promise<void> {
    if (this.updatingAll) {
      this.toast.showToast({ message: '正在全部更新，稍后再测速' });
      return;
    }
    if (!this.running) {
      this.toast.showToast({ message: '请先连接，内核起来后才能测速' });
      return;
    }
    if (this.testing) {
      return;
    }
    this.confirmTest(group.indices.length, () => {
      this.runGroupTest(group);
    });
  }

  private async runGroupTest(group: NodeGroup): Promise<void> {
    this.testing = true;
    this.testStop = false;
    this.testDone = 0;
    this.testTotal = group.indices.length;
    this.testInfo = '已测 0 · 待测 ' + String(this.testTotal);
    // 测速过程中先不排序，否则每测出一个结果整组就跳一次，根本看不清
    this.sortByDelay = false;
    this.bump();
    await this.runPool(group.indices, this.settings.testConcurrency);
    const stopped: boolean = this.testStop;
    this.testing = false;
    this.testStop = false;
    this.testInfo = '';
    this.sortByDelay = true;
    // 换一次引用：即使排序开关本来就是 true，也能让分组缓存失效、真正重排
    this.profiles = this.profiles.slice();
    this.bump();
    this.toast.showToast({ message: stopped ? '已停止测速' : '本组测速完成，已按延迟排序' });
  }

  /**
   * 测速前确认弹窗：显示待测节点数、并发数，说明超时节点自动跳过；
   * 批量延迟测试只打 generate_204 小包，不产生大流量。
   */
  private confirmTest(count: number, onOk: () => void): void {
    if (count <= 0) {
      this.toast.showToast({ message: '本组没有待测节点' });
      return;
    }
    AlertDialog.show({
      title: '开始测速',
      message: '待测 ' + String(count) + ' 个节点 · 并发 ' + String(this.settings.testConcurrency) +
        '\n超时/不通节点自动跳过并标记 -1，测速过程中可随时停止。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '开始测速',
        action: () => {
          onOk();
        }
      }
    });
  }

  /** 用户在进度卡点「停止」：批次间隙与单点轮询循环都会在下一拍退出。 */
  private stopTesting(): void {
    this.testStop = true;
  }

  /** 并发池：固定 concurrency 个 worker 从队列里取节点去测，测完更新进度。 */
  async runPool(indices: number[], concurrency: number): Promise<void> {
    const cursor: number[] = [0];
    const worker = async (): Promise<void> => {
      while (true) {
        // 停止标志在批次间隙生效：当前在飞的单点测速由 testOne 内部轮询退出
        if (this.testStop) {
          return;
        }
        const at: number = cursor[0];
        cursor[0] = cursor[0] + 1;
        if (at >= indices.length) {
          return;
        }
        await this.testOne(indices[at], true);
        this.testDone = this.testDone + 1;
        // 每 4 个节点统一刷新一次：bump 会重建列表行，让新的延迟值显示出来
        if (this.testDone % 4 === 0 || this.testDone >= this.testTotal) {
          this.testInfo = '已测 ' + String(this.testDone) + ' · 待测 ' +
            String(this.testTotal - this.testDone);
          this.bump();
        }
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
    // 删除前记住选中节点身份：删在它前面会让下标前移，删的就是它则回退到末位
    const prev: Profile | undefined = this.selected >= 0 && this.selected < this.profiles.length
      ? this.profiles[this.selected] : undefined;
    const list: Profile[] = this.profiles.slice();
    list.splice(index, 1);
    this.saveAll(list);
    if (prev !== undefined) {
      const hit: number = this.findProfileByIdentity(list, prev);
      if (hit >= 0) {
        this.selected = hit;
      } else if (this.selected >= list.length) {
        this.selected = list.length - 1;
      }
    }
    this.toast.showToast({ message: '已删除' });
    this.reconnectSoon();
  }

  // ---------- 多选批量 ----------

  /** 当前勾选节点对应的当前下标（id → 下标，删除/刷新后下标漂移也不影响）。 */
  private checkedIndices(): number[] {
    const out: number[] = [];
    this.profiles.forEach((item: Profile, index: number) => {
      if (this.checkedIds.has(item.id)) {
        out.push(index);
      }
    });
    return out;
  }

  /** 进入 / 退出多选；退出时清空勾选。 */
  private toggleMultiMode(): void {
    this.multiMode = !this.multiMode;
    if (!this.multiMode) {
      this.checkedIds.clear();
      this.checkedCount = 0;
    }
    this.bump();
  }

  private toggleChecked(index: number): void {
    const p: Profile | undefined = this.profiles[index];
    if (p === undefined) {
      return;
    }
    if (this.checkedIds.has(p.id)) {
      this.checkedIds.delete(p.id);
    } else {
      this.checkedIds.add(p.id);
    }
    this.checkedCount = this.checkedIds.size;
    this.bump();
  }

  /** 多选模式下点行是勾选，否则是选中节点。 */
  private onNodeTap(row: NodeRow): void {
    if (this.multiMode) {
      this.toggleChecked(row.nodeIndex);
    } else {
      this.selectNode(row.nodeIndex);
    }
  }

  /** 批量测延迟：复用通用并发池，按勾选集合跑。 */
  private batchTestDelay(): void {
    if (this.testing) {
      return;
    }
    if (!this.running) {
      this.toast.showToast({ message: '请先连接，内核起来后才能测速' });
      return;
    }
    const indices: number[] = this.checkedIndices();
    if (indices.length === 0) {
      this.toast.showToast({ message: '未勾选节点' });
      return;
    }
    this.confirmTest(indices.length, () => {
      this.runIndicesTest(indices);
    });
  }

  private async runIndicesTest(indices: number[]): Promise<void> {
    this.testing = true;
    this.testStop = false;
    this.testDone = 0;
    this.testTotal = indices.length;
    this.testInfo = '已测 0 · 待测 ' + String(this.testTotal);
    this.sortByDelay = false;
    this.bump();
    await this.runPool(indices, this.settings.testConcurrency);
    const stopped: boolean = this.testStop;
    this.testing = false;
    this.testStop = false;
    this.testInfo = '';
    this.sortByDelay = true;
    this.profiles = this.profiles.slice();
    this.bump();
    this.toast.showToast({ message: stopped ? '已停止测速' : '批量测速完成，已按延迟排序' });
  }

  /** 批量导出链接：拼进剪贴板；原始 link 缺失时按字段现场重建。 */
  private batchExportLinks(): void {
    const indices: number[] = this.checkedIndices();
    if (indices.length === 0) {
      this.toast.showToast({ message: '未勾选节点' });
      return;
    }
    const lines: string[] = [];
    let failed: number = 0;
    indices.forEach((i: number) => {
      const p: Profile = this.profiles[i];
      let link: string = p.link;
      if (link.length === 0) {
        try {
          link = ProxyLink.toLink(p);
        } catch (err) {
          failed = failed + 1;
        }
      }
      if (link.length > 0) {
        lines.push(link);
      }
    });
    if (lines.length === 0) {
      this.toast.showToast({ message: '勾选节点无可用链接' });
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, lines.join('\n'));
    pasteboard.getSystemPasteboard().setDataSync(data);
    this.toast.showToast({ message: '已复制 ' + String(lines.length) + ' 条链接' +
      (failed > 0 ? '（' + String(failed) + ' 条无法生成）' : '') });
  }

  private batchDelete(): void {
    const indices: number[] = this.checkedIndices();
    if (indices.length === 0) {
      this.toast.showToast({ message: '未勾选节点' });
      return;
    }
    AlertDialog.show({
      title: '批量删除',
      message: '确定删除勾选的 ' + String(indices.length) + ' 个节点？此操作不可恢复。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: () => {
          this.batchDeleteNow();
        }
      }
    });
  }

  private batchDeleteNow(): void {
    const prev: Profile | undefined = this.selected >= 0 && this.selected < this.profiles.length
      ? this.profiles[this.selected] : undefined;
    const ids: Set<string> = new Set<string>();
    this.checkedIds.forEach((id: string) => { ids.add(id); });
    const list: Profile[] = this.profiles.filter((item: Profile) => !ids.has(item.id));
    this.saveAll(list);
    if (prev !== undefined) {
      const hit: number = this.findProfileByIdentity(list, prev);
      if (hit >= 0) {
        this.selected = hit;
      } else if (this.selected >= list.length) {
        this.selected = list.length - 1;
      }
    }
    this.checkedIds.clear();
    this.checkedCount = 0;
    this.multiMode = false;
    this.bump();
    this.toast.showToast({ message: '已删除 ' + String(ids.size) + ' 个节点' });
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
    this.eUsername = p.username;
    this.ePassword = p.password;
    this.eCipher = p.cipher;
    this.eNetwork = p.network;
    this.eTls = p.tls;
    this.eSni = p.sni;
    this.ePath = p.wsPath;
    this.eHost = p.wsHost;
    this.eAlpn = p.alpn;
    this.eInsecure = p.allowInsecure === true;
    this.eFingerprint = p.fingerprint;
    this.eFlow = p.flow;
    this.eGrpcService = p.grpcService;
    this.eRealityPbk = p.realityPbk;
    this.eRealitySid = p.realitySid;
    this.eAlterId = String(p.alterId);
    this.eKcpSeed = p.kcpSeed;
    this.eKcpHeader = p.kcpHeader;
    this.eXhttpMode = p.xhttpMode;
    this.eHttpUpgrade = p.httpUpgrade === true;
    this.eHttpUpgradeFastOpen = p.httpUpgradeFastOpen === true;
    this.eHy2Obfs = p.hy2Obfs;
    this.eHy2ObfsPassword = p.hy2ObfsPassword;
    this.eHy2Up = p.hy2Up;
    this.eHy2Down = p.hy2Down;
    this.eTuicCongestion = p.tuicCongestion;
    this.eTuicUdpMode = p.tuicUdpMode;
    this.eTuicReduceRtt = p.tuicReduceRtt === true;
    this.eTuicFastOpen = p.tuicFastOpen === true;
    this.eAnytlsMetadata = p.anytlsMetadata;
    // httpupgrade 在模型里是 ws + 布尔标志，编辑器里单独成一个传输选项展示。
    this.eNetwork = p.httpUpgrade ? 'httpupgrade' : p.network;
  }

  addNew(): void {
    this.editing = this.profiles.length;
    this.editNew = true;
    this.eName = '';
    this.eType = 'vless';
    this.eServer = '';
    this.ePort = '443';
    this.eUuid = '';
    this.eUsername = '';
    this.ePassword = '';
    this.eCipher = '';
    this.eNetwork = 'ws';
    this.eTls = true;
    this.eSni = '';
    this.ePath = '';
    this.eHost = '';
    this.eAlpn = '';
    this.eInsecure = false;
    this.eFingerprint = '';
    this.eFlow = '';
    this.eGrpcService = '';
    this.eRealityPbk = '';
    this.eRealitySid = '';
    this.eAlterId = '0';
    this.eKcpSeed = '';
    this.eKcpHeader = '';
    this.eXhttpMode = '';
    this.eHttpUpgrade = false;
    this.eHttpUpgradeFastOpen = false;
    this.eHy2Obfs = '';
    this.eHy2ObfsPassword = '';
    this.eHy2Up = '';
    this.eHy2Down = '';
    this.eTuicCongestion = '';
    this.eTuicUdpMode = '';
    this.eTuicReduceRtt = false;
    this.eTuicFastOpen = false;
    this.eAnytlsMetadata = '';
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
    p.username = this.eUsername.trim();
    p.password = this.ePassword;
    p.cipher = this.eCipher.trim();
    p.tls = this.eTls;
    p.sni = this.eSni.trim();
    p.wsPath = this.ePath;
    p.wsHost = this.eHost.trim();
    p.alpn = this.eAlpn.trim();
    p.allowInsecure = this.eInsecure;
    p.fingerprint = this.eFingerprint;
    p.flow = this.eFlow.trim();
    p.grpcService = this.eGrpcService.trim();
    p.realityPbk = this.eRealityPbk.trim();
    p.realitySid = this.eRealitySid.trim();
    const aid: number = Number.parseInt(this.eAlterId);
    p.alterId = Number.isNaN(aid) ? 0 : aid;
    p.kcpSeed = this.eKcpSeed.trim();
    p.kcpHeader = this.eKcpHeader.trim();
    p.xhttpMode = this.eXhttpMode.trim();
    p.hy2Obfs = this.eHy2Obfs.trim();
    p.hy2ObfsPassword = this.eHy2ObfsPassword.trim();
    p.hy2Up = this.eHy2Up.trim();
    p.hy2Down = this.eHy2Down.trim();
    p.tuicCongestion = this.eTuicCongestion.trim();
    p.tuicUdpMode = this.eTuicUdpMode.trim();
    p.tuicReduceRtt = this.eTuicReduceRtt;
    p.tuicFastOpen = this.eTuicFastOpen;
    p.anytlsMetadata = this.eAnytlsMetadata.trim();
    // httpupgrade 在模型里是 ws + v2ray-http-upgrade 布尔；编辑器单独成项。
    if (this.eNetwork === 'httpupgrade') {
      p.network = 'ws';
      p.httpUpgrade = true;
      p.httpUpgradeFastOpen = this.eHttpUpgradeFastOpen;
    } else {
      p.network = this.eNetwork;
      p.httpUpgrade = false;
      p.httpUpgradeFastOpen = false;
    }
    p.link = ProxyLink.toLink(p);
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
  async testOne(index: number, silent: boolean = false): Promise<void> {
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
    // 内核侧测速超时 5 秒，扩展桥扫描间隔 1.5 秒；这里最多等 10 秒（20 × 500ms），
    // 等不到就回填 -1。死节点不该占着并发槽拖垮整批排序。
    let stopped: boolean = false;
    for (let i = 0; i < 20; i++) {
      await Index.sleep(500);
      // 用户点了停止：立刻退出轮询，清理请求/结果文件，节点保持未测状态（灰显 —）
      if (this.testStop) {
        stopped = true;
        break;
      }
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
    if (stopped) {
      return;
    }
    // 回填延迟。批量测速时由 runPool 每几个节点统一刷新一次列表，
    // 单点测速则立刻刷新。
    this.profiles[index].delay = delay;
    // 跑过就算测过：delay 仍为 -1 时，列表会显示红色 -1 而不是「—」
    this.profiles[index].delayTested = true;
    if (!silent) {
      this.bump();
    }
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
    if (this.updatingAll) {
      return;
    }
    if (!this.running) {
      this.toast.showToast({ message: '请先连接，内核起来后才能测速' });
      return;
    }
    if (this.testing) {
      return;
    }
    this.confirmTest(this.profiles.length, () => {
      this.runAllTest();
    });
  }

  private async runAllTest(): Promise<void> {
    this.testing = true;
    this.testStop = false;
    this.testDone = 0;
    this.testTotal = this.profiles.length;
    this.testInfo = '已测 0 · 待测 ' + String(this.testTotal);
    this.sortByDelay = false;
    this.bump();
    const all: number[] = [];
    for (let i = 0; i < this.profiles.length; i++) {
      all.push(i);
    }
    await this.runPool(all, this.settings.testConcurrency);
    const stopped: boolean = this.testStop;
    this.testing = false;
    this.testStop = false;
    this.testInfo = '';
    this.sortByDelay = true;
    this.profiles = this.profiles.slice();
    this.bump();
    this.toast.showToast({ message: stopped ? '已停止测速' : '测速完成，已按延迟排序' });
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
      // 测速不通统一显示原始值 -1（红色，见节点行 fontColor），比「—」更直白，
      // 也和排序里「-1 沉底」的规则对得上
      return '-1';
    }
    return String(value) + ' ms';
  }

  /** 清除本机运行日志（ui.log + vpn.log）。系统日志 hilog 归系统所有，应用无权清理。 */
  clearRunLog(): void {
    FileStore.clearLogs(this.filesDir);
    this.toast.showToast({ message: '运行日志已清除' });
  }

  // ---------- 应用内日志查看器 ----------

  private openLogs(): void {
    this.logPanel = true;
    this.refreshLogs();
  }

  private switchLogChannel(channel: string): void {
    this.logChannel = channel;
    this.refreshLogs();
  }

  private refreshLogs(): void {
    const text: string = FileStore.readText(FileStore.logPathOf(this.filesDir, this.logChannel));
    const raw: string[] = text.split('\n');
    const lines: string[] = [];
    raw.forEach((line: string) => {
      const clean: string = line.replace(/\r$/, '');
      if (clean.trim().length > 0) {
        lines.push(clean);
      }
    });
    // 最新在前：环形日志文件本身按时间正序写，界面倒序展示
    lines.reverse();
    this.logLines = lines;
    this.logMsg = lines.length > 0 ? String(lines.length) + ' 行 · 最新在前' : '暂无日志';
  }

  private clearChannelLog(): void {
    FileStore.removeFile(FileStore.logPathOf(this.filesDir, this.logChannel));
    this.refreshLogs();
  }

  // ---------- 分流规则 ----------

  // ---------- 分应用代理 ----------

  openAppScope(): void {
    const scope: AppScope = FileStore.loadAppScope(this.filesDir);
    this.appMode = scope.mode;
    let text: string = '';
    scope.packages.forEach((pkg: string, i: number) => {
      text = text + (i === 0 ? '' : '\n') + pkg;
    });
    this.appPkgs = text;
    this.appScopePanel = true;
    this.drawerOpen = false;
  }

  saveAppScopeConfig(): void {
    const lines: string[] = this.appPkgs.split('\n');
    const pkgs: string[] = [];
    lines.forEach((line: string) => {
      const pkg: string = line.trim();
      if (pkg.length > 0 && pkgs.indexOf(pkg) < 0) {
        pkgs.push(pkg);
      }
    });
    const scope: AppScope = { mode: this.appMode, packages: pkgs };
    FileStore.saveAppScope(this.filesDir, scope);
    FileStore.appendLog(this.filesDir, 'app scope saved: mode=' + this.appMode +
      ' packages=' + String(pkgs.length));
    this.toast.showToast({ message: '已保存，重新连接后生效' });
  }

  openSettings(): void {
    this.settings = FileStore.loadSettings(this.filesDir);
    this.settingsPanel = true;
    this.drawerOpen = false;
  }

  saveSettingsConfig(): void {
    FileStore.saveSettings(this.filesDir, this.settings);
    FileStore.appendLog(this.filesDir, 'settings saved: concurrency=' +
      String(this.settings.testConcurrency) + ' speedBytes=' + String(this.settings.speedBytes) +
      ' autoConnect=' + String(this.settings.autoConnect) +
      ' failover=' + String(this.settings.failover) +
      ' keepAlive=' + String(this.settings.keepAlive) +
      ' autoUpdateOnStart=' + String(this.settings.autoUpdateOnStart));
    // 保活被关掉：释放已申请的长时任务；重新打开后下次连接边沿会再次申请
    if (!this.settings.keepAlive) {
      this.releaseKeepAlive();
    }
    this.toast.showToast({ message: '已保存' });
  }

  /** 局部更新测速/连接行为偏好，其余字段原样保留（ArkTS 对象字面量不做展开拷贝）。 */
  private patchSettings(patch: SettingsPatch): void {
    this.settings = {
      testConcurrency: patch.testConcurrency !== undefined ? patch.testConcurrency : this.settings.testConcurrency,
      speedBytes: patch.speedBytes !== undefined ? patch.speedBytes : this.settings.speedBytes,
      autoConnect: patch.autoConnect !== undefined ? patch.autoConnect : this.settings.autoConnect,
      failover: patch.failover !== undefined ? patch.failover : this.settings.failover,
      keepAlive: patch.keepAlive !== undefined ? patch.keepAlive : this.settings.keepAlive,
      autoUpdateOnStart: patch.autoUpdateOnStart !== undefined ? patch.autoUpdateOnStart : this.settings.autoUpdateOnStart
    };
  }

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

  // ---------- 路由快捷开关与域名清单 ----------

  private ruleIndexById(id: string): number {
    for (let i = 0; i < this.rules.length; i++) {
      if (this.rules[i].id === id) {
        return i;
      }
    }
    return -1;
  }

  private setRuleEnabled(id: string, on: boolean): void {
    const idx: number = this.ruleIndexById(id);
    if (idx < 0) {
      return;
    }
    const r: RuleItem = this.rules[idx];
    this.replaceRule(idx, {
      id: r.id, title: r.title, kind: r.kind, value: r.value, target: r.target, enabled: on
    });
  }

  /** 绕过中国大陆：内置「中国域名 + 中国 IP」两条直连规则同时启用视为开。 */
  private bypassCnOn(): boolean {
    const a: number = this.ruleIndexById('r_cn_site');
    const b: number = this.ruleIndexById('r_cn_ip');
    return a >= 0 && b >= 0 && this.rules[a].enabled && this.rules[b].enabled;
  }

  private toggleBypassCn(on: boolean): void {
    this.setRuleEnabled('r_cn_site', on);
    this.setRuleEnabled('r_cn_ip', on);
    this.persistRules();
  }

  /** 广告拦截规则缺失时补一条 category-ads-all 走 REJECT，返回其下标。 */
  private ensureAdRule(): number {
    let idx: number = this.ruleIndexById('r_ads');
    if (idx >= 0) {
      return idx;
    }
    const rule: RuleItem = {
      id: 'r_ads', title: '拦截广告域名', kind: 'GEOSITE',
      value: 'category-ads-all', target: 'REJECT', enabled: true
    };
    const list: RuleItem[] = this.rules.slice();
    list.splice(1, 0, rule);
    this.rules = list;
    return this.ruleIndexById('r_ads');
  }

  private blockAdsOn(): boolean {
    const idx: number = this.ruleIndexById('r_ads');
    return idx >= 0 && this.rules[idx].enabled;
  }

  private toggleBlockAds(on: boolean): void {
    if (on) {
      this.ensureAdRule();
    }
    this.setRuleEnabled('r_ads', on);
    this.persistRules();
  }

  private persistRules(): void {
    FileStore.saveRules(this.filesDir, this.rules);
    this.reconnectSoon();
  }

  private domainRules(prefix: string): RuleItem[] {
    return this.rules.filter((r: RuleItem) => r.id.startsWith(prefix));
  }

  private normalizeDomain(raw: string): string {
    let v: string = raw.trim().toLowerCase();
    v = v.replace(/^https?:\/\//, '');
    v = v.split('/')[0];
    v = v.replace(/^[.\s]+/, '');
    return ConfigBuilder.safeValue('DOMAIN-SUFFIX', v);
  }

  private addDomainToList(prefix: string, target: string, label: string, input: string): void {
    const value: string = this.normalizeDomain(input);
    if (value.length === 0) {
      this.toast.showToast({ message: '请填写域名，例如 example.com' });
      return;
    }
    const dup: boolean = this.rules.some((r: RuleItem) => r.id.startsWith(prefix) && r.value === value);
    if (dup) {
      this.toast.showToast({ message: '该域名已在清单中' });
      return;
    }
    const rule: RuleItem = {
      id: prefix + value, title: label + ' ' + value, kind: 'DOMAIN-SUFFIX',
      value: value, target: target, enabled: true
    };
    const list: RuleItem[] = this.rules.slice();
    list.push(rule);
    this.rules = list;
    this.persistRules();
  }

  private removeDomainFromList(prefix: string, value: string): void {
    const list: RuleItem[] = this.rules.filter(
      (r: RuleItem) => !(r.id.startsWith(prefix) && r.value === value));
    this.rules = list;
    this.persistRules();
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

  // ---------- 全量备份 / 还原 ----------

  /** 汇总当前全部本机配置为备份载荷。 */
  private buildBackupPayload(): BackupPayload {
    const groupNames: Record<string, string> = {};
    this.groupNames.forEach((name: string, key: string) => {
      groupNames[key] = name;
    });
    const subQuota: Record<string, SubQuota> = {};
    this.subQuota.forEach((quota: SubQuota, key: string) => {
      subQuota[key] = quota;
    });
    const selected: Profile | null =
      this.selected >= 0 && this.selected < this.profiles.length ? this.profiles[this.selected] : null;
    return {
      version: 1,
      app: 'V2rayM',
      createdAt: Date.now(),
      profiles: this.profiles,
      groupNames: groupNames,
      subQuota: subQuota,
      rules: this.rules,
      appScope: FileStore.loadAppScope(this.filesDir),
      settings: this.settings,
      rulesSrc: this.ruleUrl,
      selected: selected
    };
  }

  /** 解析并校验备份 JSON；结构不符返回 null。 */
  private parseBackup(text: string): BackupPayload | null {
    if (text.trim().length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(text) as BackupPayload;
      if (parsed === null || parsed.app !== 'V2rayM' || parsed.profiles === undefined) {
        return null;
      }
      if (!(parsed.profiles instanceof Array)) {
        return null;
      }
      return parsed;
    } catch (err) {
      return null;
    }
  }

  /** 把备份载荷写回本机存储并刷新界面；调用方需先做覆盖确认。 */
  private applyBackup(payload: BackupPayload): void {
    const list: Profile[] = payload.profiles;
    this.profiles = list;
    FileStore.saveProfiles(this.filesDir, list);

    this.groupNames.clear();
    if (payload.groupNames !== undefined) {
      Object.keys(payload.groupNames).forEach((k: string) => {
        this.groupNames.set(k, String(payload.groupNames[k]));
      });
    }
    this.saveGroupNames();

    this.subQuota.clear();
    if (payload.subQuota !== undefined) {
      Object.keys(payload.subQuota).forEach((k: string) => {
        this.subQuota.set(k, payload.subQuota[k]);
      });
    }
    FileStore.saveSubQuota(this.filesDir, this.subQuota);

    this.rules = payload.rules !== undefined ? payload.rules : [];
    this.rulesLimit = 50;
    FileStore.saveRules(this.filesDir, this.rules);

    const scope: AppScope = payload.appScope !== undefined ? payload.appScope : { mode: 'all', packages: [] };
    FileStore.saveAppScope(this.filesDir, scope);
    this.appMode = scope.mode;
    this.appPkgs = scope.packages.join('\n');

    this.settings = payload.settings !== undefined ? payload.settings : FileStore.loadSettings(this.filesDir);
    FileStore.saveSettings(this.filesDir, this.settings);

    const src: string = payload.rulesSrc !== undefined ? payload.rulesSrc : '';
    FileStore.writeText2(this.filesDir, 'rules-src.txt', src);
    this.syncRuleUrlFromStore();

    this.selected = -1;
    if (payload.selected !== undefined && payload.selected !== null && list.length > 0) {
      this.selected = this.findProfileByIdentity(list, payload.selected);
    }
    if (this.selected < 0 && list.length > 0) {
      this.selected = 0;
    }

    this.groupPage.clear();
    this.openedKeys = [];
    this.closedKeys = [];
    this.cacheProfiles = undefined;
    this.cacheGroups = [];
    this.bump();
    this.reconnectSoon();
  }

  /** 导出全量备份到用户选择的文件；同时更新一份本机快照。 */
  async exportBackupToFile(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const doc = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSaveOptions();
      const stamp: string = Index.backupStamp();
      options.newFileNames = ['v2raym-backup-' + stamp + '.json'];
      const uris: string[] = await doc.save(options);
      if (uris.length === 0) {
        return;
      }
      const payload: BackupPayload = this.buildBackupPayload();
      const content: string = JSON.stringify(payload, null, 2);
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.writeSync(file.fd, content);
      fileIo.closeSync(file);
      FileStore.writeText2(this.filesDir, 'backup-snapshot.json', content);
      this.toast.showToast({ message: '已导出备份（' + String(payload.profiles.length) + ' 个节点）' });
    } catch (err) {
      this.toast.showToast({ message: '导出失败：' + String(err) });
    }
  }

  /** 从文件导入备份：覆盖当前节点、分组、规则、名单与偏好。 */
  async importBackupFromFile(): Promise<void> {
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
      const payload: BackupPayload | null = this.parseBackup(text);
      if (payload === null) {
        this.toast.showToast({ message: '文件不是有效的 V2rayM 备份' });
        return;
      }
      AlertDialog.show({
        title: '从备份还原',
        message: '将用备份覆盖当前全部节点、分组、分流规则、分应用名单与偏好（共 ' +
          String(payload.profiles.length) + ' 个节点），当前本机配置会被替换。',
        autoCancel: true,
        primaryButton: { value: '取消', action: () => { } },
        secondaryButton: {
          value: '还原',
          fontColor: '#C62828',
          action: () => {
            this.applyBackup(payload);
            this.toast.showToast({ message: '已从备份还原' });
          }
        }
      });
    } catch (err) {
      this.toast.showToast({ message: '导入失败：' + String(err) });
    }
  }

  /** 还原本机最近一次导出时留下的快照。 */
  restoreLocalSnapshot(): void {
    const text: string = FileStore.readText2(this.filesDir, 'backup-snapshot.json');
    const payload: BackupPayload | null = this.parseBackup(text);
    if (payload === null) {
      this.toast.showToast({ message: '还没有本机备份快照，请先导出一次备份' });
      return;
    }
    AlertDialog.show({
      title: '还原本机快照',
      message: '将用本机最近一次备份覆盖当前全部配置（' +
        String(payload.profiles.length) + ' 个节点），当前配置会被替换。',
      autoCancel: true,
      primaryButton: { value: '取消', action: () => { } },
      secondaryButton: {
        value: '还原',
        fontColor: '#C62828',
        action: () => {
          this.applyBackup(payload);
          this.toast.showToast({ message: '已还原本机快照' });
        }
      }
    });
  }

  static backupStamp(): string {
    const d: Date = new Date();
    const pad = (n: number): string => n < 10 ? '0' + String(n) : String(n);
    return String(d.getFullYear()) + pad(d.getMonth() + 1) + pad(d.getDate()) + '-' +
      pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
  }

  // ---------- Geo 资源管理（B5） ----------

  openGeo(): void {
    this.geoPanel = true;
    this.drawerOpen = false;
    this.refreshGeoInfo();
  }

  private geoPath(which: string): string {
    return FileStore.ensureDir(this.filesDir) + '/' + which + '.dat';
  }

  private static formatGeoSize(bytes: number): string {
    if (bytes <= 0) {
      return '未找到';
    }
    if (bytes >= 1048576) {
      return (bytes / 1048576).toFixed(1) + ' MB';
    }
    return Math.round(bytes / 1024) + ' KB';
  }

  private refreshGeoInfo(): void {
    this.geoIpText = Index.geoStatText(this.geoPath('geoip'));
    this.geoSiteText = Index.geoStatText(this.geoPath('geosite'));
  }

  private static geoStatText(path: string): string {
    try {
      const stat = fileIo.statSync(path);
      // Stat.mtime 单位是秒（与看门狗/保活模块一致），×1000 再交给 Date 当毫秒解析
      const d: Date = new Date(stat.mtime * 1000);
      const pad = (n: number): string => n < 10 ? '0' + String(n) : String(n);
      const t: string = String(d.getFullYear()) + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
        ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
      return Index.formatGeoSize(stat.size) + ' · ' + t;
    } catch (err) {
      return '未找到';
    }
  }

  private async httpGetArrayBuffer(url: string, timeoutMs: number): Promise<ArrayBuffer | null> {
    if (!url.toLowerCase().startsWith('https://')) {
      return null;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: { 'User-Agent': 'V2rayM-harmony/1.0' }
      });
      if (resp.responseCode !== 200) {
        FileStore.appendLog(this.filesDir, 'geo download non-200: ' + String(resp.responseCode));
        return null;
      }
      const raw: ArrayBuffer = resp.result as ArrayBuffer;
      if (raw === undefined || raw === null || raw.byteLength === 0) {
        return null;
      }
      return raw;
    } catch (err) {
      const be = err as BusinessError;
      FileStore.appendLog(this.filesDir, 'geo download err: code=' +
        String(be.code !== undefined ? be.code : -1) + ' msg=' + String(be.message));
      return null;
    } finally {
      req.destroy();
    }
  }

  private writeGeoBytes(which: string, data: ArrayBuffer): void {
    const target: string = this.geoPath(which);
    const file = fileIo.openSync(target,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, data);
    fileIo.closeSync(file);
    // 元数据落盘有短暂延迟，先刷一次、300ms 后再刷一次，避免面板时间停留在旧值
    this.refreshGeoInfo();
    setTimeout(() => { this.refreshGeoInfo(); }, 300);
  }

  async downloadGeo(which: string): Promise<void> {
    if (this.geoBusy) {
      return;
    }
    const url: string = which === 'geoip' ? GEOIP_URL : GEOSITE_URL;
    this.geoBusy = true;
    this.geoMsg = '正在下载 ' + which + '.dat …';
    try {
      const buf: ArrayBuffer | null = await this.httpGetArrayBuffer(url, 60000);
      if (buf === null) {
        this.geoMsg = '下载失败：网络不可达或返回非 200，可改用本地文件替换';
        this.toast.showToast({ message: '下载失败' });
        return;
      }
      this.writeGeoBytes(which, buf);
      this.refreshGeoInfo();
      this.geoMsg = '已更新 ' + which + '.dat（' + Index.formatGeoSize(buf.byteLength) + '），重连后生效';
      this.reconnectSoon();
      this.toast.showToast({ message: '已更新 Geo 资源' });
    } finally {
      this.geoBusy = false;
    }
  }

  async replaceGeoFromFile(which: string): Promise<void> {
    if (this.geoBusy) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const doc = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const uris: string[] = await doc.select(options);
      if (uris.length === 0) {
        return;
      }
      const buf: ArrayBuffer | null = Index.readUriBytes(uris[0]);
      if (buf === null || buf.byteLength === 0) {
        this.geoMsg = '读取文件失败';
        this.toast.showToast({ message: '读取文件失败' });
        return;
      }
      this.writeGeoBytes(which, buf);
      this.refreshGeoInfo();
      this.geoMsg = '已从本地文件替换 ' + which + '.dat，重连后生效';
      this.reconnectSoon();
      this.toast.showToast({ message: '已替换 Geo 资源' });
    } catch (err) {
      this.geoMsg = '替换失败：' + String(err);
      this.toast.showToast({ message: '替换失败' });
    }
  }

  restoreBuiltinGeo(which: string): void {
    if (this.geoBusy) {
      return;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const raw: Uint8Array = context.resourceManager.getRawFileContentSync(which + '.dat');
      const buf: ArrayBuffer = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
      this.writeGeoBytes(which, buf);
      this.refreshGeoInfo();
      this.geoMsg = '已恢复内置 ' + which + '.dat，重连后生效';
      this.reconnectSoon();
      this.toast.showToast({ message: '已恢复内置资源' });
    } catch (err) {
      this.geoMsg = '恢复内置失败：' + String(err);
    }
  }

  static readUriBytes(uri: string): ArrayBuffer | null {
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(uri);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      return buffer;
    } catch (err) {
      return null;
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
    if (url.startsWith('http://')) {
      this.ruleMsg = '规则订阅地址必须用 https';
      this.toast.showToast({ message: '规则订阅地址必须用 https，明文 http 会被篡改' });
      return;
    }
    if (!url.startsWith('https://')) {
      this.ruleMsg = '请先填写 https 规则订阅地址';
      this.toast.showToast({ message: '请先填写 https 规则订阅地址' });
      return;
    }
    this.ruleMsg = '正在拉取规则订阅…';
    const body: string = await this.httpGet(url, 15000);
    hilog.info(0x0000, 'V2rayM-UI', 'rule fetched, bytes=%{public}d', body.length);
    if (body.trim().length === 0) {
      this.ruleMsg = '拉取失败：没有收到内容（HTTP 未返回或链接不可达）';
      this.toast.showToast({ message: '规则拉取失败，检查链接或网络' });
      return;
    }
    const parsed: RuleItem[] = ConfigBuilder.parseRules(body, Index.targetHintFromUrl(url));
    hilog.info(0x0000, 'V2rayM-UI', 'rule parsed=%{public}d', parsed.length);
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

  /**
   * 连接入口互斥：自动恢复定时器、用户点击、节点切换重连可能同一秒并发，
   * 旧实现无互斥，出现同秒两次 startVpnExtensionAbility（22:40:22/25、
   * 06:47:01/02）并伴随 onCreate→onDestroy→onCreate。这里串行化所有入口，
   * finally 保证任何提前 return 路径都复位 connecting。
   */
  async connect(fromRecover: boolean = false): Promise<void> {
    if (this.connecting) {
      FileStore.appendLog(this.filesDir, 'connect: skipped, another connect in progress');
      return;
    }
    this.connecting = true;
    try {
      await this.connectInternal(fromRecover);
    } finally {
      this.connecting = false;
    }
  }

  /** 实际连接流程；只由 connect() 调用，保证入口互斥与状态复位。 */
  private async connectInternal(fromRecover: boolean): Promise<void> {
    if (this.running) {
      // 断开：先给界面反馈，再等系统真拆干净
      this.busy = true;
      this.setStatus('正在断开…');
      try {
        await this.disconnect();
      } finally {
        this.busy = false;
      }
      return;
    }
    if (this.selected < 0 || this.selected >= this.profiles.length) {
      this.toast.showToast({ message: '请先选择一个节点' });
      return;
    }
    // 用户主动发起连接：清除「主动停止」标记并允许立即申请长时任务。
    // 自动恢复（fromRecover=true）不改该标记，其前提是 canAutoRecover() 已放行。
    if (!fromRecover) {
      KeepAliveManager.getInstance().setUserStopped(false);
      // 用户主动连接：故障转移额度与已试节点清空
      this.failoverCount = 0;
      this.failoverTried = [];
      // 取消挂起的自动恢复：否则它稍后触发 connect(true) 时 running 已为 true，
      // 会误走进「断开」分支，把用户刚连上的 VPN 又断掉。
      if (this.recoverTimer >= 0) {
        clearTimeout(this.recoverTimer);
        this.recoverTimer = -1;
      }
      this.recovering = false;
      this.lostCount = 0;
      this.recoverAttempt = 0;
    }
    this.busy = true;
    this.setStatus('正在连接…');
    try {
      // 系统里还挂着上一轮的 VPN（扩展被强杀后常见）时先清掉，
      // 否则新实例 create 会撞 2203002「系统已有 VPN」。
      if (await this.hasSystemVpn()) {
        FileStore.appendLog(this.filesDir, 'connect: stale vpn found, stopping first');
        await this.stopExtension();
        const gone: boolean = await this.waitVpnGone(3000);
        // 去重：拆干净后系统 VPN 又立刻出现，说明另一路已拉起扩展。
        // 本轮不再 startVpnExtensionAbility，杜绝同秒双 start 与
        // onCreate→onDestroy→onCreate；入口 connecting 互斥是另一道保险。
        if (gone && (await this.hasSystemVpn())) {
          FileStore.appendLog(this.filesDir,
            'connect: vpn alive after stale cleanup, skip duplicate start');
          return;
        }
      }
      const config: string = ConfigBuilder.build(this.profiles, this.selected, this.rules);
      FileStore.writeText(FileStore.configPath(this.filesDir), config);
      const want: Want = {
        bundleName: BUNDLE_NAME,
        abilityName: EXT_ABILITY
      };
      FileStore.appendLog(this.filesDir, 'start vpn extension');
      await vpnExtension.startVpnExtensionAbility(want);
      // 每次建连成功都显式申请一次长时任务（force）。真机 14:10/14:14 两次
      // 重连完全没有 started/failed 日志，根源就是旧实现只靠 readState 的
      // false→true 边沿，组件内 running 与状态文件不同步时边沿会丢失。
      // 这里独立于任何边沿兜底，确保后台期一定有长时任务保护。
      this.requestKeepAlive();
      this.statusText = '正在启动内核…';
    } catch (err) {
      const message: string = String(err);
      FileStore.appendLog(this.filesDir, 'start vpn extension failed: ' + message);
      this.toast.showToast({ message: '启动失败：' + message });
      this.statusText = message;
    } finally {
      this.busy = false;
    }
  }

  /** 只发一次 stop 请求，不判断结果。 */
  private async stopExtension(): Promise<boolean> {
    try {
      const want: Want = {
        bundleName: BUNDLE_NAME,
        abilityName: EXT_ABILITY
      };
      await vpnExtension.stopVpnExtensionAbility(want);
      return true;
    } catch (err) {
      FileStore.appendLog(this.filesDir, 'stopVpnExtensionAbility failed: ' + String(err));
      return false;
    }
  }

  /** 轮询等待系统真的把 VPN 通道拆掉（扩展 onDestroy 是异步的，固定 sleep 不可靠）。 */
  private async waitVpnGone(timeoutMs: number): Promise<boolean> {
    const steps: number = Math.max(1, Math.floor(timeoutMs / 400));
    for (let i = 0; i < steps; i++) {
      if (!(await this.hasSystemVpn())) {
        return true;
      }
      await Index.sleep(400);
    }
    return !(await this.hasSystemVpn());
  }

  /**
   * 断开：发 stop -> 等系统拆掉通道 -> 以「系统是否还有 VPN」为准更新界面。
   * 之前只发 stop 就把 running 置 false，或 stop 抛错就停在「停止代理」，
   * 两种都会让界面和真实状态对不上（停不掉 / 假连接）。
   */
  async disconnect(): Promise<void> {
    FileStore.appendLog(this.filesDir, 'disconnect requested');
    // 用户主动停止：先落盘标记（杀进程不丢）。这是自动恢复与保活重申请的
    // 唯一硬门禁，保证手动断开后不会被自动重连抢回去。
    KeepAliveManager.getInstance().setUserStopped(true);
    // 取消可能挂起的自动恢复，避免它把用户主动断开的连接又拉起来
    if (this.recoverTimer >= 0) {
      clearTimeout(this.recoverTimer);
      this.recoverTimer = -1;
    }
    this.recovering = false;
    this.lostCount = 0;
    this.recoverAttempt = 0;
    // 断开即重置故障转移额度
    this.failoverCount = 0;
    this.failoverTried = [];
    // 显式释放长时任务：本函数会先把 running 置 false 并写 state.json，
    // readState() 的 true→false 边沿会因此丢失，不能只依赖它来 stop。
    this.releaseKeepAlive();
    let stopped: boolean = false;
    for (let attempt = 0; attempt < 2; attempt++) {
      if (await this.stopExtension()) {
        stopped = true;
        break;
      }
      await Index.sleep(300);
    }
    await this.waitVpnGone(4000);
    const stillThere: boolean = await this.hasSystemVpn();
    if (!stillThere) {
      this.running = false;
      this.statusText = '未连接';
      this.totalText = '';
      this.exitSeq++;
      this.exitBusy = false;
      this.exitEmptyStreak = 0;
      this.exitBlocked = false;
      this.exitInfo = '';
      FileStore.writeText(FileStore.statePath(this.filesDir), '{"running":false,"message":"未连接"' + FileStore.userStoppedField(this.filesDir) + '}');
      FileStore.appendLog(this.filesDir,
        'disconnect done, stopped=' + String(stopped));
      return;
    }
    // 通道还在：说明确实没断开，保留「停止代理」让用户能再点一次
    FileStore.appendLog(this.filesDir, 'disconnect incomplete, vpn still alive');
    this.toast.showToast({ message: '断开未完成，请再点一次或重启应用' });
  }

  /**
   * 节点增删改后：内核只在启动时读一次配置，所以连接中改动要自动重连才生效。
   * 必须先确认旧通道拆干净再拉起，否则新旧两个扩展同时活着会断流。
   */
  private reconnectSoon(): void {
    if (!this.running) {
      return;
    }
    if (this.reconnecting) {
      // 已经在切换了：记一下，等这一轮结束再用最新选中的节点切一次
      this.pendingSwitch = true;
      return;
    }
    this.reconnecting = true;
    this.setStatus('正在切换节点…');
    this.disconnect().then(() => {
      return this.waitVpnGone(5000);
    }).then(() => {
      this.reconnecting = false;
      this.pendingSwitch = false;
      return this.connect();
    }).catch(() => {
      this.reconnecting = false;
      this.pendingSwitch = false;
    });
  }

  // ---------- UI ----------
  @Builder
  field(label: string, value: string, onChange: (v: string) => void) {
    Row({ space: 8 }) {
      Text(label).fontSize(15).width(80).fontColor('#4A4A4A')
      TextInput({ text: value })
        .layoutWeight(1)
        .height(42)
        .fontSize(15)
        .onChange((v: string) => {
          onChange(v);
        })
    }.width('100%')
  }

  @Builder
  chip(label: string, current: string, onTap: () => void) {
    Text(label)
      .fontSize(14)
      .padding({ left: 13, right: 13, top: 8, bottom: 8 })
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
            Text('协议').fontSize(15).width(80).fontColor('#4A4A4A')
            Row({ space: 8 }) {
              this.chip('vless', this.eType, () => { this.eType = 'vless'; })
              this.chip('vmess', this.eType, () => { this.eType = 'vmess'; })
              this.chip('trojan', this.eType, () => { this.eType = 'trojan'; })
              this.chip('ss', this.eType, () => { this.eType = 'ss'; })
              this.chip('hysteria2', this.eType, () => { this.eType = 'hysteria2'; })
              this.chip('tuic', this.eType, () => { this.eType = 'tuic'; })
              this.chip('anytls', this.eType, () => { this.eType = 'anytls'; })
              this.chip('socks5', this.eType, () => { this.eType = 'socks5'; })
              this.chip('http', this.eType, () => { this.eType = 'http'; })
            }.layoutWeight(1)
          }.width('100%')

          this.field('服务器', this.eServer, (v: string) => { this.eServer = v; })
          this.field('端口', this.ePort, (v: string) => { this.ePort = v; })
          if (this.eType === 'vless' || this.eType === 'vmess' || this.eType === 'tuic') {
            this.field('UUID', this.eUuid, (v: string) => { this.eUuid = v; })
          }
          if (this.eType === 'vmess') {
            this.field('alterId', this.eAlterId, (v: string) => { this.eAlterId = v; })
          }
          if (this.eType === 'vmess' || this.eType === 'ss') {
            this.field('加密方式', this.eCipher, (v: string) => { this.eCipher = v; })
          }
          if (this.eType === 'trojan' || this.eType === 'ss' || this.eType === 'hysteria2'
            || this.eType === 'tuic' || this.eType === 'anytls'
            || this.eType === 'socks5' || this.eType === 'http') {
            this.field('密码', this.ePassword, (v: string) => { this.ePassword = v; })
          }
          if (this.eType === 'socks5' || this.eType === 'http') {
            this.field('用户名', this.eUsername, (v: string) => { this.eUsername = v; })
          }
          if (this.eType === 'vless') {
            this.field('flow', this.eFlow, (v: string) => { this.eFlow = v; })
          }
          if (this.eType === 'hysteria2') {
            this.field('上行带宽', this.eHy2Up, (v: string) => { this.eHy2Up = v; })
            this.field('下行带宽', this.eHy2Down, (v: string) => { this.eHy2Down = v; })
            this.field('混淆类型', this.eHy2Obfs, (v: string) => { this.eHy2Obfs = v; })
            this.field('混淆密码', this.eHy2ObfsPassword, (v: string) => { this.eHy2ObfsPassword = v; })
          }
          if (this.eType === 'tuic') {
            this.field('拥塞控制', this.eTuicCongestion, (v: string) => { this.eTuicCongestion = v; })
            this.field('UDP 中继', this.eTuicUdpMode, (v: string) => { this.eTuicUdpMode = v; })
            Row({ space: 8 }) {
              Text('reduce-rtt').fontSize(15).width(80).fontColor('#4A4A4A')
              Toggle({ type: ToggleType.Switch, isOn: this.eTuicReduceRtt })
                .onChange((on: boolean) => { this.eTuicReduceRtt = on; })
            }.width('100%')
            Row({ space: 8 }) {
              Text('fast-open').fontSize(15).width(80).fontColor('#4A4A4A')
              Toggle({ type: ToggleType.Switch, isOn: this.eTuicFastOpen })
                .onChange((on: boolean) => { this.eTuicFastOpen = on; })
            }.width('100%')
          }
          if (this.eType === 'anytls') {
            this.field('client-metadata', this.eAnytlsMetadata, (v: string) => { this.eAnytlsMetadata = v; })
          }

          Row({ space: 8 }) {
            Text('传输').fontSize(15).width(80).fontColor('#4A4A4A')
            Row({ space: 8 }) {
              this.chip('tcp', this.eNetwork, () => { this.eNetwork = 'tcp'; })
              this.chip('ws', this.eNetwork, () => { this.eNetwork = 'ws'; })
              this.chip('grpc', this.eNetwork, () => { this.eNetwork = 'grpc'; })
              this.chip('h2', this.eNetwork, () => { this.eNetwork = 'h2'; })
              this.chip('kcp', this.eNetwork, () => { this.eNetwork = 'kcp'; })
              this.chip('http', this.eNetwork, () => { this.eNetwork = 'http'; })
              this.chip('xhttp', this.eNetwork, () => { this.eNetwork = 'xhttp'; })
              this.chip('httpupgrade', this.eNetwork, () => { this.eNetwork = 'httpupgrade'; })
            }.layoutWeight(1)
          }.width('100%')

          Row({ space: 8 }) {
            Text('TLS').fontSize(15).width(80).fontColor('#4A4A4A')
            Toggle({ type: ToggleType.Switch, isOn: this.eTls })
              .onChange((on: boolean) => {
                this.eTls = on;
              })
          }.width('100%')

          if (this.eTls) {
            this.field('SNI', this.eSni, (v: string) => { this.eSni = v; })
            Row({ space: 8 }) {
              Text('指纹').fontSize(15).width(80).fontColor('#4A4A4A')
              Scroll() {
                Row({ space: 8 }) {
                  this.chip('默认', this.eFingerprint, () => { this.eFingerprint = ''; })
                  this.chip('chrome', this.eFingerprint, () => { this.eFingerprint = 'chrome'; })
                  this.chip('edge', this.eFingerprint, () => { this.eFingerprint = 'edge'; })
                  this.chip('safari', this.eFingerprint, () => { this.eFingerprint = 'safari'; })
                  this.chip('ios', this.eFingerprint, () => { this.eFingerprint = 'ios'; })
                  this.chip('android', this.eFingerprint, () => { this.eFingerprint = 'android'; })
                }
              }.scrollable(ScrollDirection.Horizontal).layoutWeight(1)
            }.width('100%')
            this.field('ALPN', this.eAlpn, (v: string) => { this.eAlpn = v; })
            Row({ space: 8 }) {
              Text('不安全证书').fontSize(15).width(80).fontColor('#4A4A4A')
              Toggle({ type: ToggleType.Switch, isOn: this.eInsecure })
                .onChange((on: boolean) => {
                  this.eInsecure = on;
                })
            }.width('100%')
            if (this.eType === 'vless') {
              this.field('REALITY 公钥', this.eRealityPbk, (v: string) => { this.eRealityPbk = v; })
              this.field('REALITY short-id', this.eRealitySid, (v: string) => { this.eRealitySid = v; })
            }
          }
          if (this.eNetwork === 'grpc') {
            this.field('gRPC 服务名', this.eGrpcService, (v: string) => { this.eGrpcService = v; })
          }
          if (this.eNetwork === 'kcp') {
            this.field('mKCP seed', this.eKcpSeed, (v: string) => { this.eKcpSeed = v; })
            this.field('mKCP 伪装头', this.eKcpHeader, (v: string) => { this.eKcpHeader = v; })
          }
          if (this.eNetwork === 'xhttp') {
            this.field('路径', this.ePath, (v: string) => { this.ePath = v; })
            this.field('Host', this.eHost, (v: string) => { this.eHost = v; })
            this.field('xhttp 模式', this.eXhttpMode, (v: string) => { this.eXhttpMode = v; })
          }
          if (this.eNetwork === 'http' || this.eNetwork === 'h2') {
            this.field('路径', this.ePath, (v: string) => { this.ePath = v; })
            this.field('Host', this.eHost, (v: string) => { this.eHost = v; })
          }
          if (this.eNetwork === 'ws' || this.eNetwork === 'httpupgrade') {
            this.field('路径', this.ePath, (v: string) => { this.ePath = v; })
            this.field('Host', this.eHost, (v: string) => { this.eHost = v; })
          }
          if (this.eNetwork === 'httpupgrade') {
            Row({ space: 8 }) {
              Text('fast-open').fontSize(15).width(80).fontColor('#4A4A4A')
              Toggle({ type: ToggleType.Switch, isOn: this.eHttpUpgradeFastOpen })
                .onChange((on: boolean) => { this.eHttpUpgradeFastOpen = on; })
            }.width('100%')
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

  // 左滑露出的操作：编辑 / 删除；平时不占位，避免点选节点时误触
  @Builder
  nodeSwipe(index: number) {
    Row() {
      Button('复制')
        .height('100%')
        .width(92)
        .fontSize(15)
        .borderRadius(0)
        .backgroundColor('#2E7D32')
        .fontColor('#FFFFFF')
        .onClick(() => {
          this.copyLink(index);
        })
      Button('编辑')
        .height('100%')
        .width(92)
        .fontSize(15)
        .borderRadius(0)
        .backgroundColor('#0A59F7')
        .fontColor('#FFFFFF')
        .onClick(() => {
          this.openEdit(index);
        })
      Button('删除')
        .height('100%')
        .width(92)
        .fontSize(15)
        .borderRadius(0)
        .backgroundColor('#E84026')
        .fontColor('#FFFFFF')
        .onClick(() => {
          this.removeProfile(index);
        })
    }
    .height('100%')
  }

  /** 节点行的正文（名称 / 延迟 / 地址），两种卡片共用 */
  @Builder
  nodeContent(row: NodeRow) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(row.name).fontSize(17).maxLines(1).layoutWeight(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 三种状态分开显示：
        //   测过不通（带宽测速失败或延迟测速失败）→ 红色 -1
        //   测过且通 → 延迟毫秒（<1500ms 绿色）
        //   没测过 → 灰色「—」，不标 -1，避免 861 个节点满屏红色
        Text((row.speed === 0 || (row.delayTested && row.delay < 0)) ? '-1' :
          (row.delay >= 0 ? String(row.delay) + ' ms' : '—'))
          .fontSize(15)
          .fontColor((row.speed === 0 || (row.delayTested && row.delay < 0)) ? '#D93026' :
            (row.delay >= 0 && row.delay < 1500 ? '#2E7D32' : '#8A8A8A'))
          .onClick(() => {
            this.testOne(row.nodeIndex);
          })

        // 带宽测速成功才额外显示下降速率；不通的情况上面已经用 -1 表示了
        if (row.speed > 0) {
          Text('↓' + Index.speedText(row.speed))
            .fontSize(13)
            .fontColor('#0A59F7')
        }

        if (row.selected) {
          Text('✓').fontSize(17).fontColor('#0A59F7')
        }
      }
      .width('100%')

      Text(row.addr)
        .fontSize(14).fontColor('#5F5F5F').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  nodeRow(row: NodeRow) {
    Row({ space: 10 }) {
      if (this.multiMode) {
        Row() {
          Text(row.checked ? '✓' : '').fontSize(14).fontColor('#FFFFFF')
        }
        .width(22)
        .height(22)
        .borderRadius(11)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(row.checked ? '#0A59F7' : '#FFFFFF')
        .border({ width: 1.5, color: row.checked ? '#0A59F7' : '#B9C0CC' })
      }
      if (row.groupKey.length === 0) {
        // 手动节点：一张一张独立的卡片
        Column() {
          this.nodeContent(row)
        }
        .layoutWeight(1)
        .padding(12)
        .borderRadius(10)
        .backgroundColor((row.selected || row.checked) ? '#EAF1FF' : '#F5F5F5')
        .margin({ top: 8 })
      } else {
        // 订阅组：同组节点连成一整块，和上面的组头共用一块底色
        Column() {
          this.nodeContent(row)
        }
        .layoutWeight(1)
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .borderRadius({
          topLeft: row.firstInBlock ? 12 : 0,
          topRight: row.firstInBlock ? 12 : 0,
          bottomLeft: row.lastInBlock ? 12 : 0,
          bottomRight: row.lastInBlock ? 12 : 0
        })
        .backgroundColor((row.selected || row.checked) ? '#E3ECFF' : '#F5F7FC')
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onNodeTap(row);
    })
  }

  @Builder
  groupHeaderRow(row: NodeRow) {
    // 手动节点组只有一个「测速」，压成一行；订阅组要放改名/更新/测速，用两行，
    // 免得标题被按钮挤成「订阅 · …」，改名后自己也看不全
    if (row.groupKey.length === 0) {
      Row({ space: 10 }) {
        Text(row.groupTitle)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#2E2E2E')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick(() => {
            this.toggleKey(row.groupKey);
          })
        Text(String(row.groupCount) + ' 个')
          .fontSize(13)
          .fontColor('#5F6B7A')
        Row() {
          Image($r('app.media.ic_bolt')).width(20).height(20).objectFit(ImageFit.Contain)
        }
        .width(36)
        .height(36)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#D8E6FF')
        .borderRadius(18)
        .border({ width: 1, color: '#C2D8FF' })
        .onClick(() => {
          this.testGroupByKey(row.groupKey);
        })
      }
      .width('100%')
      .padding({ left: 4, right: 8, top: 8, bottom: 6 })
      .margin({ top: 10 })
    } else {
      Column() {
        Row({ space: 6 }) {
          Text(row.groupOpen ? '▾' : '▸')
            .fontSize(20)
            .fontColor('#2E2E2E')
            .height(34)
            .width(24)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.toggleKey(row.groupKey);
            })
          Text(row.groupTitle)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#2E2E2E')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .maxFontScale(1)
            .onClick(() => {
              this.toggleKey(row.groupKey);
            })
          Text((this.sortByDelay && row.groupCount > 1 ? '↓ ' : '') +
            String(row.groupCount) + ' 个')
            .fontSize(12)
            .fontColor(this.sortByDelay && row.groupCount > 1 ? '#2E7D32' : '#5F6B7A')
            .onClick(() => {
              this.toggleKey(row.groupKey);
            })

          // 改名：铅笔（描边轮廓 + 笔尖分界线）
          Row() {
            Image($r('app.media.ic_pencil')).width(18).height(18).objectFit(ImageFit.Contain)
          }
          .width(32)
          .height(32)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#F1F5FF')
          .borderRadius(16)
          .border({ width: 1, color: '#DCE7FF' })
          .onClick(() => {
            this.openRename(row.groupKey);
          })

          // 更新：半圆箭头
          Row() {
            Image($r('app.media.ic_refresh')).width(18).height(18).objectFit(ImageFit.Contain)
          }
          .width(32)
          .height(32)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#F1F5FF')
          .borderRadius(16)
          .border({ width: 1, color: '#DCE7FF' })
          .onClick(() => {
            this.refreshGroup(row.groupKey);
          })

          // 测速：闪电
          Row() {
            Image($r('app.media.ic_bolt')).width(18).height(18).objectFit(ImageFit.Contain)
          }
          .width(32)
          .height(32)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#D8E6FF')
          .borderRadius(16)
          .border({ width: 1, color: '#C2D8FF' })
          .onClick(() => {
            this.testGroupByKey(row.groupKey);
          })

          // 删除整组：红色 ✕，先弹确认再删
          Row() {
            Text('✕').fontSize(16).fontColor('#C62828')
          }
          .width(32)
          .height(32)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#FDECEA')
          .borderRadius(16)
          .border({ width: 1, color: '#F5C6C2' })
          .onClick(() => {
            this.deleteGroup(row.groupKey);
          })
        }
        .width('100%')

        // 订阅配额/到期第二行：无配额信息（手动组或订阅未返回）时不占位
        if (row.quotaText.length > 0) {
          Text(row.quotaText)
            .fontSize(12)
            .fontColor('#5F6B7A')
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 30, top: 2 })
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .margin({ top: 10 })
      // 整块底色：组头和组内节点同色，连起来就是一块卡片，组与组之间一眼分得开
      .backgroundColor('#F5F7FC')
      .borderRadius({
        topLeft: 12,
        topRight: 12,
        bottomLeft: row.lastInBlock ? 12 : 0,
        bottomRight: row.lastInBlock ? 12 : 0
      })
    }
  }

  @Builder
  moreRow(row: NodeRow) {
    Row() {
      Text('再显示 ' + String(Index.PAGE_SIZE) + ' 个（共 ' +
        String(row.moreLeft + this.nodeLimitOf(row.groupKey)) + ' 个）')
        .fontSize(15).fontColor('#0A59F7')
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 10, bottom: 12 })
    .backgroundColor('#F5F7FC')
    .borderRadius({ bottomLeft: 12, bottomRight: 12 })
    .onClick(() => {
      this.moreNodes(row.groupKey);
    })
  }

  nodeLimitOf(key: string): number {
    const group: NodeGroup | undefined = this.nodeGroupByKey(key);
    if (group === undefined) {
      return 0;
    }
    return this.nodeLimit(group);
  }

  testGroupByKey(key: string): void {
    const group: NodeGroup | undefined = this.nodeGroupByKey(key);
    if (group !== undefined) {
      this.testGroup(group);
    }
  }

  @Builder
  drawer() {
    Row() {
      Scroll() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text('订阅与导入').fontSize(19).fontWeight(FontWeight.Bold)
            Text('按订阅分组 · 可单独更新/测速').fontSize(13).fontColor('#5A5A5A')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)

          Button('关闭')
            .fontSize(14)
            .height(34)
            .width(72)
            .padding({ left: 0, right: 0 })
            .backgroundColor('#F0F0F0')
            .fontColor('#333333')
            .onClick(() => {
              this.drawerOpen = false;
            })
        }.width('100%')

        TextInput({ text: this.subInput, placeholder: '订阅链接 https://…' })
          .width('100%')
          .height(44)
          .fontSize(14)
          .onChange((v: string) => {
            this.subInput = v;
          })

        Button('从订阅链接导入')
          .width('100%')
          .height(44)
          .fontSize(15)
          .enabled(!this.updatingAll)
          .onClick(() => {
            this.importSubscription();
          })

        Text('单条链接').fontSize(14).fontColor('#5A5A5A')

        TextArea({ text: this.linkInput, placeholder: '粘贴 vmess:// vless:// ss:// trojan:// socks5:// http:// 链接，一行一个' })
          .width('100%')
          .height(110)
          .fontSize(13)
          .onChange((value: string) => {
            this.linkInput = value;
          })

        Row({ space: 10 }) {
          Button('剪贴板导入').layoutWeight(1).height(40).fontSize(14)
            .backgroundColor('#F0F0F0').fontColor('#333333')
            .onClick(() => {
              this.importFromClipboard();
            })
          Button('解析导入').layoutWeight(1).height(40).fontSize(14)
            .onClick(() => {
              this.importFromText();
            })
        }.width('100%')

        Text('导入后写进 core.yaml；连接状态下自动重连生效。')
          .fontSize(13)
          .fontColor('#5A5A5A')

        Button('设置')
          .width('100%')
          .height(44)
          .fontSize(15)
          .backgroundColor('#EAF1FF')
          .fontColor('#0A59F7')
          .onClick(() => {
            this.openSettings();
          })

        Text('测速选项、连接行为、分应用代理、分流规则、Geo 资源、分组、日志、备份还原、清空节点都在设置页里。')
          .fontSize(13)
          .fontColor('#5A5A5A')

        Blank()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
      .width('72%')
      .height('100%')
      .padding(16)
      .backgroundColor('#FFFFFF')
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
  appModeBtn(label: string, mode: string) {
    Button(label)
      .height(38)
      .fontSize(14)
      .layoutWeight(1)
      .backgroundColor(this.appMode === mode ? '#0A59F7' : '#F0F0F0')
      .fontColor(this.appMode === mode ? '#FFFFFF' : '#333333')
      .onClick(() => {
        this.appMode = mode;
      })
  }

  @Builder
  appScopePanelView() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Button('返回')
          .width(76)
          .height(38)
          .fontSize(14)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.appScopePanel = false;
          })
        Text('分应用代理')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button('保存')
          .width(84)
          .height(38)
          .fontSize(14)
          .backgroundColor('#0A59F7')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.saveAppScopeConfig();
          })
      }
      .width('100%')

      Text('全部走代理：不限制。仅代理选中：只有名单内应用走隧道，其余直连。排除选中：名单内应用直连，其余走隧道。')
        .fontSize(13)
        .fontColor('#5A5A5A')

      Row({ space: 8 }) {
        this.appModeBtn('全部走代理', 'all')
        this.appModeBtn('仅代理选中', 'allow')
        this.appModeBtn('排除选中', 'block')
      }
      .width('100%')

      TextArea({ placeholder: '每行一个包名，例如 com.tencent.mm', text: this.appPkgs })
        .height(220)
        .width('100%')
        .fontSize(14)
        .backgroundColor('#F5F5F5')
        .onChange((value: string) => {
          this.appPkgs = value;
        })

      Text('包名可在系统「设置 → 应用和服务」里查看。本应用没有枚举其它应用的权限，因此不做自动勾选。')
        .fontSize(12)
        .fontColor('#8A8A8A')

      Text('改动后需要重新连接代理才会生效。模式为「全部走代理」时名单不生效。')
        .fontSize(12)
        .fontColor('#B26A00')

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  geoBlock(which: string, label: string, info: string) {
    Column({ space: 8 }) {
      Row() {
        Text(label).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
        Text(info).fontSize(12).fontColor('#5A5A5A')
      }.width('100%')
      Row({ space: 8 }) {
        Button('在线更新')
          .layoutWeight(1).height(38).fontSize(13)
          .backgroundColor('#F0F0F0').fontColor('#333333')
          .enabled(!this.geoBusy)
          .onClick(() => { this.downloadGeo(which); })
        Button('本地替换')
          .layoutWeight(1).height(38).fontSize(13)
          .backgroundColor('#F0F0F0').fontColor('#333333')
          .enabled(!this.geoBusy)
          .onClick(() => { this.replaceGeoFromFile(which); })
        Button('恢复内置')
          .layoutWeight(1).height(38).fontSize(13)
          .backgroundColor('#F0F0F0').fontColor('#333333')
          .enabled(!this.geoBusy)
          .onClick(() => { this.restoreBuiltinGeo(which); })
      }.width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F7F7F7')
    .borderRadius(12)
  }

  @Builder
  geoPanelView() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Button('返回')
          .width(76).height(38).fontSize(14)
          .backgroundColor('#F0F0F0').fontColor('#333333')
          .onClick(() => { this.geoPanel = false; })
        Text('Geo 资源').fontSize(19).fontWeight(FontWeight.Bold).layoutWeight(1)
      }.width('100%')

      Text('geoip.dat（IP 库）/ geosite.dat（域名库）由内核启动时读取；在线更新走默认源，' +
        '若本机网络访问受限，可用本地 .dat 文件替换。替换后会自动重连生效。')
        .fontSize(13).fontColor('#5A5A5A')

      this.geoBlock('geoip', 'geoip.dat · IP 库', this.geoIpText)
      this.geoBlock('geosite', 'geosite.dat · 域名库', this.geoSiteText)

      Text(this.geoMsg).fontSize(13).fontColor('#B26A00')

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  settingsPanelView() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Button('返回')
          .width(76)
          .height(38)
          .fontSize(14)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.settingsPanel = false;
          })
        Text('设置')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button('保存')
          .width(84)
          .height(38)
          .fontSize(14)
          .backgroundColor('#0A59F7')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.saveSettingsConfig();
          })
      }
      .width('100%')

      Scroll() {
        Column({ space: 6 }) {
          // ---- 测速 ----
          this.settingSection('测速')
          Text('延迟测速并发：同时发起的测速请求数。并发太高可能被节点限流，太低则整组测速慢。')
            .fontSize(13)
            .fontColor('#5A5A5A')
            .width('100%')
          Row({ space: 8 }) {
            Text('6')
              .fontSize(14)
              .padding({ left: 13, right: 13, top: 8, bottom: 8 })
              .borderRadius(8)
              .backgroundColor(this.settings.testConcurrency === 6 ? '#EAF1FF' : '#F2F2F2')
              .fontColor(this.settings.testConcurrency === 6 ? '#0A59F7' : '#333333')
              .onClick(() => { this.patchSettings({ testConcurrency: 6 }); })
            Text('12')
              .fontSize(14)
              .padding({ left: 13, right: 13, top: 8, bottom: 8 })
              .borderRadius(8)
              .backgroundColor(this.settings.testConcurrency === 12 ? '#EAF1FF' : '#F2F2F2')
              .fontColor(this.settings.testConcurrency === 12 ? '#0A59F7' : '#333333')
              .onClick(() => { this.patchSettings({ testConcurrency: 12 }); })
            Text('24')
              .fontSize(14)
              .padding({ left: 13, right: 13, top: 8, bottom: 8 })
              .borderRadius(8)
              .backgroundColor(this.settings.testConcurrency === 24 ? '#EAF1FF' : '#F2F2F2')
              .fontColor(this.settings.testConcurrency === 24 ? '#0A59F7' : '#333333')
              .onClick(() => { this.patchSettings({ testConcurrency: 24 }); })
          }
          .width('100%')

          Text('带宽测速包大小：下载文件越大测速越准；慢节点建议选小一档，避免大文件读不完超时。')
            .fontSize(13)
            .fontColor('#5A5A5A')
            .width('100%')
          Row({ space: 8 }) {
            Text('1 MB')
              .fontSize(14)
              .padding({ left: 13, right: 13, top: 8, bottom: 8 })
              .borderRadius(8)
              .backgroundColor(this.settings.speedBytes === 1048576 ? '#EAF1FF' : '#F2F2F2')
              .fontColor(this.settings.speedBytes === 1048576 ? '#0A59F7' : '#333333')
              .onClick(() => { this.patchSettings({ speedBytes: 1048576 }); })
            Text('5 MB')
              .fontSize(14)
              .padding({ left: 13, right: 13, top: 8, bottom: 8 })
              .borderRadius(8)
              .backgroundColor(this.settings.speedBytes === 5242880 ? '#EAF1FF' : '#F2F2F2')
              .fontColor(this.settings.speedBytes === 5242880 ? '#0A59F7' : '#333333')
              .onClick(() => { this.patchSettings({ speedBytes: 5242880 }); })
            Text('10 MB')
              .fontSize(14)
              .padding({ left: 13, right: 13, top: 8, bottom: 8 })
              .borderRadius(8)
              .backgroundColor(this.settings.speedBytes === 10485760 ? '#EAF1FF' : '#F2F2F2')
              .fontColor(this.settings.speedBytes === 10485760 ? '#0A59F7' : '#333333')
              .onClick(() => { this.patchSettings({ speedBytes: 10485760 }); })
          }
          .width('100%')

          // ---- 连接行为 ----
          this.settingSection('连接行为')
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text('自动连接').fontSize(15).fontColor('#1A1A1A')
              Text('冷启动 / 掉线后自动重连').fontSize(12).fontColor('#5A5A5A')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.autoConnect })
              .onChange((v: boolean) => { this.patchSettings({ autoConnect: v }); })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text('故障转移').fontSize(15).fontColor('#1A1A1A')
              Text('当前节点无流量时自动切换到其他可用节点').fontSize(12).fontColor('#5A5A5A')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.failover })
              .onChange((v: boolean) => { this.patchSettings({ failover: v }); })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text('后台保活').fontSize(15).fontColor('#1A1A1A')
              Text('连接期间申请长时任务，降低后台被系统回收的概率').fontSize(12).fontColor('#5A5A5A')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.keepAlive })
              .onChange((v: boolean) => { this.patchSettings({ keepAlive: v }); })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          // ---- 订阅 ----
          this.settingSection('订阅')
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text('启动时自动更新').fontSize(15).fontColor('#1A1A1A')
              Text('打开应用后静默更新所有带链接的订阅分组').fontSize(12).fontColor('#5A5A5A')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.autoUpdateOnStart })
              .onChange((v: boolean) => { this.patchSettings({ autoUpdateOnStart: v }); })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          // ---- 代理与分流 ----
          this.settingSection('代理与分流')
          this.settingEntry('分应用代理', '全部走代理 / 仅白名单 / 排除黑名单，手动填包名', false,
            () => { this.openAppScope(); })
          this.settingEntry('分流规则', '逐条编辑规则，可从网址更新规则集并导出/导入 JSON', false,
            () => { this.openRules(); })
          this.settingEntry('Geo 资源', '查看 geoip/geosite 大小与时间，在线更新或本地文件替换', false,
            () => { this.openGeo(); })

          // ---- 节点与分组 ----
          this.settingSection('节点与分组')
          this.settingEntry('新建分组', '名称 + 订阅链接；链接留空则建手动分组', false,
            () => { this.openNewGroup(); })

          // ---- 运行日志 ----
          this.settingSection('运行日志')
          this.settingEntry('查看运行日志', '界面 / VPN / 看门狗三通道，各保留最近 240 行', false,
            () => { this.openLogs(); })
          this.settingEntry('清除运行日志', '删除三条通道的日志文件', false,
            () => { this.clearRunLog(); })

          // ---- 备份与还原 ----
          this.settingSection('备份与还原')
          this.settingEntry('导出全量备份', '节点、分组名、配额、规则、分应用名单与测速偏好', false,
            () => { this.exportBackupToFile(); })
          this.settingEntry('从备份文件还原', '选择备份 JSON 覆盖当前配置', false,
            () => { this.importBackupFromFile(); })
          this.settingEntry('还原本机快照', '回滚到上次本机自动保存的快照', false,
            () => { this.restoreLocalSnapshot(); })

          // ---- 危险操作 ----
          this.settingSection('危险操作')
          this.settingEntry('清空全部节点', '删除全部节点与订阅分组；分流规则与分应用名单保留', true,
            () => { this.clearAllProfiles(); })

          // ---- 关于 ----
          this.settingSection('关于')
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text('内核版本').fontSize(15).fontColor('#1A1A1A')
              Text('mihomo 单内核').fontSize(12).fontColor('#5A5A5A')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(this.coreVersion.length > 0 ? this.coreVersion : '—')
              .fontSize(14)
              .fontColor('#5A5A5A')
          }
          .width('100%')
          .padding({ top: 10, bottom: 10, left: 12, right: 12 })
          .borderRadius(10)
          .backgroundColor('#F7F8FA')

          Blank().height(8)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .alignItems(HorizontalAlign.Start)
  }

  /** 设置页分区标题。 */
  @Builder
  settingSection(title: string) {
    Text(title)
      .fontSize(15)
      .fontWeight(FontWeight.Bold)
      .fontColor('#1A1A1A')
      .width('100%')
      .margin({ top: 14, bottom: 2 })
  }

  /** 设置页入口行：标题 + 说明 + 右侧箭头，点击进入子面板。 */
  @Builder
  settingEntry(title: string, desc: string, danger: boolean, onTap: () => void) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(title).fontSize(15).fontColor(danger ? '#C62828' : '#1A1A1A')
        if (desc.length > 0) {
          Text(desc).fontSize(12).fontColor('#5A5A5A')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(18)
        .fontColor('#9A9A9A')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .borderRadius(10)
    .backgroundColor('#F7F8FA')
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  rulesPanel() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Button('返回')
          .width(76)
          .height(38)
          .fontSize(14)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.saveRuleSrcFromInput();
            this.rulePanel = false;
            this.ruleEditing = -1;
          })
        Text('分流规则')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button('保存')
          .width(84)
          .height(38)
          .fontSize(14)
          .onClick(() => {
            this.saveRulesNow();
          })
      }.width('100%')

      Text('从上到下逐条匹配，命中即停；地址栏默认内置推荐规则集，换成自己的规则订阅网址后会记住。')
        .fontSize(13)
        .fontColor('#5A5A5A')
        .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.ruleUrl, placeholder: '内置推荐规则集 / 规则订阅地址 https://…' })
          .layoutWeight(1)
          .height(42)
          .fontSize(13)
          .enterKeyType(EnterKeyType.Go)
          .onChange((v: string) => {
            this.ruleUrl = v;
          })
          .onSubmit((key: EnterKeyType) => {
            this.importRulesFromUrl();
          })
        Button('网址更新')
          .width(120)
          .height(42)
          .fontSize(14)
          .onClick(() => {
            this.importRulesFromUrl();
          })
      }.width('100%')

      Row({ space: 8 }) {
        Button('文件导入')
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.importRulesFromFile();
          })
        Button('导出规则')
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.exportRulesToFile();
          })
      }.width('100%')

      Divider().margin({ top: 6, bottom: 2 })
      Text('快捷开关')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('绕过中国大陆').fontSize(15).fontColor('#1A1A1A')
          Text('国内域名与 IP 直连，不走代理').fontSize(12).fontColor('#5A5A5A')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.bypassCnOn() })
          .onChange((v: boolean) => { this.toggleBypassCn(v); })
      }
      .width('100%')
      .padding({ top: 6, bottom: 6 })

      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('拦截广告').fontSize(15).fontColor('#1A1A1A')
          Text('category-ads-all 广告域名直接阻断').fontSize(12).fontColor('#5A5A5A')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.blockAdsOn() })
          .onChange((v: boolean) => { this.toggleBlockAds(v); })
      }
      .width('100%')
      .padding({ top: 6, bottom: 6 })

      Text('直连域名（命中后直连）')
        .fontSize(14)
        .fontColor('#333333')
        .width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.directDomInput, placeholder: '域名，例如 example.com' })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .onChange((v: string) => { this.directDomInput = v; })
        Button('添加')
          .width(80)
          .height(40)
          .fontSize(14)
          .onClick(() => {
            this.addDomainToList('direct_dom:', 'DIRECT', '直连域名', this.directDomInput);
            this.directDomInput = '';
          })
      }.width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.domainRules('direct_dom:'), (rule: RuleItem) => {
          Row({ space: 6 }) {
            Text(rule.value).fontSize(13).fontColor('#2E7D32')
            Text('✕').fontSize(14).fontColor('#E84026')
              .onClick(() => { this.removeDomainFromList('direct_dom:', rule.value); })
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .margin({ right: 8, bottom: 8 })
          .backgroundColor('#EAF4EC')
          .borderRadius(10)
        }, (rule: RuleItem) => rule.id)
      }.width('100%')

      Text('强制代理域名（命中后走代理）')
        .fontSize(14)
        .fontColor('#333333')
        .width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.proxyDomInput, placeholder: '域名，例如 example.com' })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .onChange((v: string) => { this.proxyDomInput = v; })
        Button('添加')
          .width(80)
          .height(40)
          .fontSize(14)
          .onClick(() => {
            this.addDomainToList('proxy_dom:', 'PROXY', '代理域名', this.proxyDomInput);
            this.proxyDomInput = '';
          })
      }.width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.domainRules('proxy_dom:'), (rule: RuleItem) => {
          Row({ space: 6 }) {
            Text(rule.value).fontSize(13).fontColor('#0A59F7')
            Text('✕').fontSize(14).fontColor('#E84026')
              .onClick(() => { this.removeDomainFromList('proxy_dom:', rule.value); })
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .margin({ right: 8, bottom: 8 })
          .backgroundColor('#EAF1FF')
          .borderRadius(10)
        }, (rule: RuleItem) => rule.id)
      }.width('100%')

      Text(this.ruleMsg.length > 0 ? this.ruleMsg : '手动改规则后点右上角「保存」；也可以整份从文件或网址覆盖')
        .fontSize(13)
        .fontColor(this.ruleMsg.length > 0 ? '#0A59F7' : '#5A5A5A')
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
                  .fontSize(16)
                  .fontColor(rule.enabled ? '#222222' : '#8C8C8C')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(rule.kind + (rule.value.length > 0 ? ',' + rule.value : '') + ',' + rule.target)
                  .fontSize(13)
                  .fontColor('#5F5F5F')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)

              Text(rule.target)
                .fontSize(13)
                .fontColor(rule.target === 'DIRECT' ? '#2E7D32' :
                  (rule.target === 'PROXY' ? '#0A59F7' : '#E84026'))
                .backgroundColor('#FFFFFF')
                .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                .borderRadius(8)
                .onClick(() => {
                  this.cycleTarget(index);
                })

              Text('编辑')
                .fontSize(14)
                .fontColor('#0A59F7')
                .onClick(() => {
                  this.openRuleEdit(index);
                })
              Text('删除')
                .fontSize(14)
                .fontColor('#E84026')
                .onClick(() => {
                  this.removeRule(index);
                })
            }
            .width('100%')
            .padding(12)
            .backgroundColor('#F7F7F7')
            .borderRadius(10)
          }, (rule: RuleItem, index: number) => rule.id + '|' + rule.kind + '|' + rule.value + '|' +
            rule.target + '|' + (rule.enabled ? '1' : '0') + '|' + rule.title)

          if (this.rules.length > this.rulesLimit) {
            Button('再显示 50 条（共 ' + String(this.rules.length) + ' 条）')
              .width('100%')
              .height(40)
              .fontSize(14)
              .backgroundColor('#EAF1FF')
              .fontColor('#0A59F7')
              .onClick(() => {
                this.rulesLimit = this.rulesLimit + 50;
              })
          }

          Button('恢复默认规则集')
            .width('100%')
            .height(40)
            .fontSize(14)
            .backgroundColor('#FFF4F2')
            .fontColor('#E84026')
            .onClick(() => {
              this.resetRules();
            })

          Button('+ 添加规则')
            .width('100%')
            .height(40)
            .fontSize(14)
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
          Text('规则编辑').fontSize(19).fontWeight(FontWeight.Bold).width('100%')

      Row({ space: 8 }) {
        Text('名称').fontSize(14).width(56)
        TextInput({ text: this.rTitle, placeholder: '显示名，如「代理 Google」' })
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .onChange((v: string) => {
            this.rTitle = v;
          })
      }.width('100%')

      Text('类型').fontSize(14).width('100%')
      Row({ space: 8 }) {
        Button('GEOSITE').layoutWeight(1).height(38).fontSize(14)
          .backgroundColor(this.rKind === 'GEOSITE' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rKind === 'GEOSITE' ? '#FFFFFF' : '#333333')
          .padding(0)
          .onClick(() => {
            this.rKind = 'GEOSITE';
          })
        Button('GEOIP').layoutWeight(1).height(38).fontSize(14)
          .backgroundColor(this.rKind === 'GEOIP' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rKind === 'GEOIP' ? '#FFFFFF' : '#333333')
          .padding(0)
          .onClick(() => {
            this.rKind = 'GEOIP';
          })
        Button('DOMAIN').layoutWeight(1).height(38).fontSize(14)
          .backgroundColor(this.rKind === 'DOMAIN-SUFFIX' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rKind === 'DOMAIN-SUFFIX' ? '#FFFFFF' : '#333333')
          .padding(0)
          .onClick(() => {
            this.rKind = 'DOMAIN-SUFFIX';
          })
        Button('IP-CIDR').layoutWeight(1).height(38).fontSize(14)
          .backgroundColor(this.rKind === 'IP-CIDR' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rKind === 'IP-CIDR' ? '#FFFFFF' : '#333333')
          .padding(0)
          .onClick(() => {
            this.rKind = 'IP-CIDR';
          })
        Button('MATCH').layoutWeight(1).height(38).fontSize(14)
          .backgroundColor(this.rKind === 'MATCH' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rKind === 'MATCH' ? '#FFFFFF' : '#333333')
          .padding(0)
          .onClick(() => {
            this.rKind = 'MATCH';
          })
      }.width('100%')
      Text('GEOSITE 域名库 / GEOIP IP 库 / DOMAIN 单个域名 / IP-CIDR 网段 / MATCH 兜底')
        .fontSize(12)
        .fontColor('#7A7A7A')
        .width('100%')

      Row({ space: 8 }) {
        Text('内容').fontSize(14).width(56)
        TextInput({ text: this.rValue, placeholder: 'cn / CN / google.com / 10.0.0.0/8' })
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .enabled(this.rKind !== 'MATCH')
          .onChange((v: string) => {
            this.rValue = v;
          })
      }.width('100%')

      Text('策略').fontSize(14).width('100%')
      Row({ space: 8 }) {
        Button('直连 DIRECT').layoutWeight(1).height(38).fontSize(14)
          .backgroundColor(this.rTarget === 'DIRECT' ? '#2E7D32' : '#F0F0F0')
          .fontColor(this.rTarget === 'DIRECT' ? '#FFFFFF' : '#333333')
          .onClick(() => {
            this.rTarget = 'DIRECT';
          })
        Button('代理 PROXY').layoutWeight(1).height(38).fontSize(14)
          .backgroundColor(this.rTarget === 'PROXY' ? '#0A59F7' : '#F0F0F0')
          .fontColor(this.rTarget === 'PROXY' ? '#FFFFFF' : '#333333')
          .onClick(() => {
            this.rTarget = 'PROXY';
          })
        Button('阻断 REJECT').layoutWeight(1).height(38).fontSize(14)
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

  @Builder
  renamePanel() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
          Text('重命名分组').fontSize(19).fontWeight(FontWeight.Bold).width('100%')

          Text('给这个订阅分组起个好认的名字（比如「香港 3 条」「便宜机场」）。只改显示，不影响订阅和节点本身。')
            .fontSize(13)
            .fontColor('#7A7A7A')
            .width('100%')

          Row({ space: 8 }) {
            Text('默认').fontSize(14).width(56).fontColor('#8C8C8C')
            Text(Index.subTitle(this.renameKey))
              .fontSize(14)
              .fontColor('#8C8C8C')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%')

          TextInput({ text: this.renameText, placeholder: '新名字，留空则恢复默认' })
            .width('100%')
            .height(46)
            .fontSize(16)
            .onChange((v: string) => {
              this.renameText = v;
            })

          Text('留空后保存 = 恢复成上面的默认名').fontSize(12).fontColor('#9A9A9A').width('100%')

          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .height(46)
              .fontSize(16)
              .backgroundColor('#F0F0F0')
              .fontColor('#333333')
              .onClick(() => {
                this.closeRename();
              })
            Button('保存')
              .layoutWeight(1)
              .height(46)
              .fontSize(16)
              .onClick(() => {
                this.saveRename();
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

  // ---------- 日志查看器面板 ----------

  @Builder
  logPanelView() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Button('返回')
          .width(76)
          .height(38)
          .fontSize(14)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.logPanel = false;
          })
        Text('运行日志')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button('刷新')
          .height(38)
          .fontSize(14)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.refreshLogs();
          })
        Button('清空')
          .height(38)
          .fontSize(14)
          .backgroundColor('#FDECEA')
          .fontColor('#C62828')
          .onClick(() => {
            this.clearChannelLog();
          })
      }
      .width('100%')

      // 三通道切换：ui=界面进程，vpn=扩展/VPN 进程，watchdog=看门狗
      Row({ space: 8 }) {
        this.logTab('界面', 'ui')
        this.logTab('VPN', 'vpn')
        this.logTab('看门狗', 'watchdog')
        Blank()
        Text(this.logMsg).fontSize(12).fontColor('#8A8F99')
      }
      .width('100%')

      Scroll() {
        Column({ space: 4 }) {
          if (this.logLines.length === 0) {
            Text('暂无日志').fontSize(14).fontColor('#9A9A9A').padding(16)
          }
          ForEach(this.logLines, (line: string) => {
            Text(line)
              .fontSize(12)
              .fontColor('#333333')
              .width('100%')
              .wordBreak(WordBreak.BREAK_ALL)
          }, (line: string, idx: number) => this.logChannel + '#' + String(idx) + '#' + line)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#F7F8FA')
      .borderRadius(10)
      .padding(10)
    }
    .padding(16)
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  @Builder
  logTab(label: string, channel: string) {
    Button(label)
      .height(34)
      .fontSize(13)
      .backgroundColor(this.logChannel === channel ? '#0A59F7' : '#F0F0F0')
      .fontColor(this.logChannel === channel ? '#FFFFFF' : '#333333')
      .onClick(() => {
        this.switchLogChannel(channel);
      })
  }

  // ---------- 新建分组面板 ----------

  @Builder
  groupPanelView() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Button('返回')
          .width(76)
          .height(38)
          .fontSize(14)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.closeNewGroup();
          })
        Text('新建分组')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
      }
      .width('100%')

      Text('分组名称：在列表里显示的标题，方便自己辨认。')
        .fontSize(13)
        .fontColor('#7A7A7A')
        .width('100%')
      TextInput({ text: this.gName, placeholder: '例如：香港 专线' })
        .width('100%')
        .height(46)
        .fontSize(16)
        .onChange((v: string) => {
          this.gName = v;
        })

      Text('订阅链接：留空则建一个手动分组；填写后保存即拉取订阅节点。链接必须是 https。')
        .fontSize(13)
        .fontColor('#7A7A7A')
        .width('100%')
      TextInput({ text: this.gUrl, placeholder: 'https://…（可留空）' })
        .width('100%')
        .height(46)
        .fontSize(14)
        .onChange((v: string) => {
          this.gUrl = v;
        })

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(46)
          .fontSize(16)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.closeNewGroup();
          })
        Button('保存')
          .layoutWeight(1)
          .height(46)
          .fontSize(16)
          .onClick(() => {
            this.saveNewGroup();
          })
      }
      .width('100%')

      Blank()
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
            Text('V2rayM').fontSize(21).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            Text(this.summary).fontSize(13).fontColor('#FFE3E3')
            if (this.coreVersion.length > 0) {
              Text('内核 ' + this.coreVersion).fontSize(12).fontColor('#FFE3E3')
            }
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 8, right: 12, top: 10, bottom: 10 })
        .borderRadius(14)
        .backgroundColor('#8B3A3A')

        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text(this.statusText).fontSize(15).fontColor(this.running ? '#2E7D32' : '#5A5A5A')
            Blank()
            // 中间空白处放本次累计：小灰字
            if (this.totalText.length > 0) {
              Text(this.totalText)
                .fontSize(13)
                .fontColor('#8A8F99')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .width('100%')
          // 状态行自己一块：已连接浅绿、未连接浅灰，带描边和阴影，一眼看到现在是什么状态
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .borderRadius(10)
          .backgroundColor(this.running ? '#EAF6EA' : '#F2F3F5')
          .border({ width: 1, color: this.running ? '#CFE8CF' : '#E2E4E8' })
          .shadow({ radius: 8, color: '#14000000', offsetX: 0, offsetY: 2 })

          // 本次会话时长与会话内上下行差值（连上瞬间记基线，断开即清空）
          if (this.running && this.sessionText.length > 0) {
            Text(this.sessionText)
              .fontSize(13)
              .fontColor('#5A5A5A')
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 12, right: 12 })
          }

          // 长时任务连续申请失败时给出可见提示，不再静默地显示「已连接」
          if (this.keepAliveWarn.length > 0) {
            Text(this.keepAliveWarn)
              .fontSize(12)
              .fontColor('#B26A00')
              .width('100%')
              .padding({ left: 12, right: 12 })
          }

          if (this.running) {
            // 出口 IP + 国家地区单独占一行：和流量挤在一起时地区会被省略掉。
            // 右侧空处放带宽测速入口：必须已连接才有意义（未连接测的是本机宽带）。
            Row({ space: 8 }) {
              Text(this.exitInfo.length > 0 ? this.exitInfo :
                (this.exitBusy ? '正在测出口 IP…' :
                  (this.speedBusy ? '正在测带宽…' : '点此测出口 IP')))
                .fontSize(14)
                .fontColor(this.exitBlocked ? '#7A7A7A' : (this.exitInfo.length > 0 ? '#2E7D32' : '#7A7A7A'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick(() => {
                  if (!this.exitBusy) {
                    this.exitEmptyStreak = 0;
                    this.exitBlocked = false;
                    this.exitBlockedAt = 0;
                    this.refreshExit(1);
                  }
                })
              Text(this.speedBusy ? '测速中' : (this.speedInfo.length > 0 ? this.speedInfo : '带宽测速'))
                .fontSize(12)
                .fontColor(this.speedInfo === '不通' ? '#D93026' : '#0A59F7')
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .borderRadius(6)
                .backgroundColor(this.speedInfo === '不通' ? '#FBE3E2' : '#DCE7FF')
                .onClick(() => {
                  if (!this.speedBusy) {
                    this.speedTestCurrent();
                  }
                })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .borderRadius(10)
            .backgroundColor(this.exitBlocked ? '#F2F3F5' : '#EAF6EA')
            .border({ width: 1, color: this.exitBlocked ? '#E2E4E8' : '#CFE8CF' })
            .shadow({ radius: 8, color: '#14000000', offsetX: 0, offsetY: 2 })
          }

          // 测速进度单独一张卡：和流量计数挤一行会被省略号吃掉；测速中可点「停止」
          if (this.testInfo.length > 0) {
            Row({ space: 10 }) {
              Text(this.testInfo).fontSize(14).fontColor('#B25B3E')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.testing) {
                Button('停止')
                  .height(30)
                  .fontSize(13)
                  .backgroundColor('#C62828')
                  .fontColor('#FFFFFF')
                  .onClick(() => {
                    this.stopTesting();
                  })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .borderRadius(10)
            .backgroundColor('#FBF1EC')
            .border({ width: 1, color: '#EDD6C9' })
            .shadow({ radius: 8, color: '#14000000', offsetX: 0, offsetY: 2 })
          }

          // 全部更新进度：与测速进度同款橙色卡片
          if (this.updInfo.length > 0) {
            Text(this.updInfo).fontSize(14).fontColor('#B25B3E')
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 12, right: 12, top: 9, bottom: 9 })
              .borderRadius(10)
              .backgroundColor('#FBF1EC')
              .border({ width: 1, color: '#EDD6C9' })
              .shadow({ radius: 8, color: '#14000000', offsetX: 0, offsetY: 2 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Row({ space: 8 }) {
          Button('添加节点').layoutWeight(1).height(38).fontSize(13)
            .padding({ left: 2, right: 2 })
            .backgroundColor('#F0F0F0').fontColor('#333333')
            .onClick(() => {
              this.addNew();
            })
          Button(this.updatingAll ? '更新中…' : '全部更新').layoutWeight(1).height(38).fontSize(13)
            .padding({ left: 2, right: 2 })
            .backgroundColor('#F0F0F0').fontColor('#333333')
            .enabled(!this.updatingAll && !this.testing)
            .onClick(() => {
              this.updateAllSubscriptions();
            })
          Button(this.testing ? '测速中…' : '全部测速').layoutWeight(1).height(38).fontSize(13)
            .padding({ left: 2, right: 2 })
            .backgroundColor('#F0F0F0').fontColor('#333333')
            .enabled(!this.testing && !this.updatingAll)
            .onClick(() => {
              this.testAll();
            })
          Button(this.multiMode ? '退出多选' : '多选').layoutWeight(1).height(38).fontSize(13)
            .padding({ left: 2, right: 2 })
            .backgroundColor(this.multiMode ? '#DCE7FF' : '#F0F0F0')
            .fontColor('#0A59F7')
            .enabled(!this.testing)
            .onClick(() => {
              this.toggleMultiMode();
            })
        }.width('100%')

        // 多选工具条：勾选数量 + 批量测延迟 / 导出 / 删除
        if (this.multiMode) {
          Row({ space: 8 }) {
            Text('已选 ' + String(this.checkedCount) + ' 个')
              .fontSize(14)
              .fontColor('#2E2E2E')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Button('测延迟').height(34).fontSize(13)
              .backgroundColor('#2E7D32').fontColor('#FFFFFF')
              .enabled(!this.testing)
              .onClick(() => { this.batchTestDelay(); })
            Button('导出').height(34).fontSize(13)
              .backgroundColor('#0A59F7').fontColor('#FFFFFF')
              .onClick(() => { this.batchExportLinks(); })
            Button('删除').height(34).fontSize(13)
              .backgroundColor('#E84026').fontColor('#FFFFFF')
              .onClick(() => { this.batchDelete(); })
          }
          .width('100%')
          .padding({ left: 4, right: 4, top: 8, bottom: 4 })
        }

        List({ space: 0 }) {
          // LazyForEach：只创建屏幕内可见的行，几百个节点也不会拖慢主线程
          LazyForEach(this.dataSource, (row: NodeRow) => {
            if (row.kind === 1) {
              ListItem() {
                this.nodeRow(row)
              }
              .width('100%')
              .swipeAction({ end: (): void => { this.nodeSwipe(row.nodeIndex) } })
            } else if (row.kind === 0) {
              ListItem() {
                this.groupHeaderRow(row)
              }
              .width('100%')
            } else {
              ListItem() {
                this.moreRow(row)
              }
              .width('100%')
            }
          }, (row: NodeRow) => this.rowKey(row))
        }
        .layoutWeight(1)
        .width('100%')

        // 代理开关：放在最底部，单手拇指就能够到
        Row() {
          Button(this.busy ? (this.running ? '正在断开…' : '正在连接…') :
            (this.running ? '停止代理' : '开启代理'))
            .layoutWeight(1)
            .height(50)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .enabled(!this.busy)
            .backgroundColor(this.running ? '#E84026' : '#0A59F7')
            .fontColor('#FFFFFF')
            .onClick(() => {
              if (this.busy) {
                return;
              }
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

      // 设置页先挂载：它是各子面板（分应用/分流/Geo/日志/分组）的父层，
      // 必须排在子面板之前，否则全屏白底会把子面板盖住，表现为「点了没反应」。
      if (this.settingsPanel) {
        this.settingsPanelView()
      }

      if (this.rulePanel) {
        this.rulesPanel()
      }

      if (this.appScopePanel) {
        this.appScopePanelView()
      }

      if (this.geoPanel) {
        this.geoPanelView()
      }

      if (this.rulePanel && this.ruleEditing >= 0) {
        this.ruleEditPanel()
      }

      if (this.editing >= 0) {
        this.editPanel()
      }

      if (this.renameKey.length > 0) {
        this.renamePanel()
      }

      if (this.logPanel) {
        this.logPanelView()
      }

      if (this.groupPanel) {
        this.groupPanelView()
      }
    }
    .width('100%')
    .height('100%')
  }
}
