import { common, Want } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vpnExtension, http, connection } from '@kit.NetworkKit';
import { PromptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { ProxyLink } from '../core/ProxyLink';
import { Profile, CoreState, DelayBody, DelayReq, DelayRes, RuleItem } from '../core/Model';
import { ConfigBuilder } from '../core/ConfigBuilder';
import { FileStore } from '../core/FileStore';
import { KeepAliveManager } from '../core/KeepAliveManager';

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
  addr: string = '';
  selected: boolean = false;
  moreLeft: number = 0;
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
    copy.addr = src.addr;
    copy.selected = flag;
    copy.moreLeft = src.moreLeft;
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
  /** 连续多少枪全空后停止重试（约 1 分钟），避免死节点上无限转圈 */
  static readonly EXIT_EMPTY_LIMIT: number = 8;
  @State summary: string = 'mihomo 内核 · 国内直连 / 国外代理';
  @State linkInput: string = '';
  @State subInput: string = '';
  @State testing: boolean = false;
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

  // 订阅分组改名：key = 订阅 URL，value = 用户自己起的名字（存 group-names.json）
  @State renameKey: string = '';
  @State renameText: string = '';
  private groupNames: Map<string, string> = new Map<string, string>();

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
    if (mgr.isUserStopped() || !mgr.canAutoRecover()) {
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
  selectNode(nodeIndex: number): void {
    if (nodeIndex === this.selected || nodeIndex < 0) {
      return;
    }
    const prev: number = this.selected;
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
      String(row.groupCount) + '|' + (row.selected ? '1' : '0') + '|' + (row.groupOpen ? 'o' : 'c');
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
        row.addr = p.type.toUpperCase() + ' · ' + p.server + ':' + String(p.port);
        row.selected = index === this.selected;
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

  /** 组内按延迟从低到高排；没测出结果（-1）的沉到组尾，其余保持原相对顺序。 */
  sortIndices(group: NodeGroup): void {
    if (!this.sortByDelay || group.indices.length < 2) {
      return;
    }
    const origin: number[] = group.indices.slice();
    // 原位置查表：392 个节点时每次比较都做 indexOf 会把排序拖成 O(n² log n)
    const pos: Map<number, number> = new Map<number, number>();
    origin.forEach((value: number, at: number) => {
      pos.set(value, at);
    });
    group.indices.sort((a: number, b: number) => {
      const da: number = this.profiles[a].delay >= 0 ? this.profiles[a].delay : 999999;
      const db: number = this.profiles[b].delay >= 0 ? this.profiles[b].delay : 999999;
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

  async httpGet(url: string, timeoutMs: number): Promise<string> {
    // 兜底：所有拉取一律只走 https。订阅与规则链接走明文时 token 和节点凭据
    // 会被同一网络里的中间人读走，响应还能被改写。出口探测两个地址本来就是 https，
    // 测速走 NAPI 的 proxyDelay 不经过这里，因此不受影响。
    if (!url.toLowerCase().startsWith('https://')) {
      hilog.error(0x0001, 'V2rayNG-UI', 'httpGet refused: not https');
      return '';
    }
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
        // 不打印 url：订阅链接里带 token，落到系统日志等于把凭据写进日志
        hilog.error(0x0001, 'V2rayNG-UI', 'httpGet code=%{public}d', resp.responseCode);
        FileStore.appendLog(this.filesDir, 'httpGet non-200: ' + String(resp.responseCode));
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
      hilog.error(0x0001, 'V2rayNG-UI', 'httpGet fail code=%{public}d msg=%{public}s',
        be.code !== undefined ? be.code : -1, String(be.message));
      FileStore.appendLog(this.filesDir, 'httpGet err: code=' +
        String(be.code !== undefined ? be.code : -1) + ' msg=' + String(be.message));
      return '';
    } finally {
      req.destroy();
    }
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
        this.exitInfo = '当前节点无可用出口，请切换节点';
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
    const uiContext = getContext(this) as common.UIAbilityContext;
    KeepAliveManager.getInstance().ensureRunning(uiContext, true)
      .catch((err: Error) => {
        FileStore.appendLog(this.filesDir, 'requestKeepAlive failed: ' + err.message);
      });
  }

  /** 低频复核：管理器内部 ≥30s 节流 + 冷却，force=false。 */
  private ensureKeepAlive(): void {
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
    // 老版本允许 http 导入的订阅会落到这里；手动节点组没有刷新按钮，传进来的必然是订阅地址
    if (!url.toLowerCase().startsWith('https://')) {
      this.toast.showToast({ message: '该订阅是明文 http，已拒绝更新；请改用 https 地址重新导入' });
      return;
    }
    this.statusText = '正在更新订阅…';
    const body: string = await this.httpGet(url, 15000);
    if (body.trim().length === 0) {
      this.toast.showToast({ message: '订阅更新失败，检查网络' });
      this.statusText = this.running ? '已连接' : '未连接';
      return;
    }
    const added: number = this.applySubContent(url, body);
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
    this.updInfo = '已更新 0 · 待更新 ' + String(this.updTotal);
    let okSubs: number = 0;
    let failed: number = 0;
    let addedTotal: number = 0;

    try {
      // 并发拉取上限 3：照抄 runPool 的 cursor / worker / Promise.all 结构
      const bodies: Map<string, string> = new Map<string, string>();
      const cursor: number[] = [0];
      const worker = async (): Promise<void> => {
        while (true) {
          const at: number = cursor[0];
          cursor[0] = cursor[0] + 1;
          if (at >= targets.length) {
            return;
          }
          const url: string = targets[at];
          const body: string = await this.httpGet(url, 15000);
          bodies.set(url, body);
          this.updDone = this.updDone + 1;
          this.updInfo = '已更新 ' + String(this.updDone) + ' · 待更新 ' +
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

  /** 单个分组测速：只测这一组的节点。 */
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
    this.testing = true;
    this.testDone = 0;
    this.testTotal = group.indices.length;
    this.testInfo = '已测 0 · 待测 ' + String(this.testTotal);
    // 测速过程中先不排序，否则每测出一个结果整组就跳一次，根本看不清
    this.sortByDelay = false;
    this.bump();
    await this.runPool(group.indices, Index.TEST_CONCURRENCY);
    this.testing = false;
    this.testInfo = '';
    this.sortByDelay = true;
    // 换一次引用：即使排序开关本来就是 true，也能让分组缓存失效、真正重排
    this.profiles = this.profiles.slice();
    this.bump();
    this.toast.showToast({ message: '本组测速完成，已按延迟排序' });
  }

  /** 测速并发上限：内核侧是 goroutine，这里控制同时排队请求数。 */
  static TEST_CONCURRENCY: number = 24;

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
    for (let i = 0; i < 20; i++) {
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
    // 回填延迟。批量测速时由 runPool 每几个节点统一刷新一次列表，
    // 单点测速则立刻刷新。
    this.profiles[index].delay = delay;
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
    this.testing = true;
    this.testDone = 0;
    this.testTotal = this.profiles.length;
    this.testInfo = '已测 0 · 待测 ' + String(this.testTotal);
    this.sortByDelay = false;
    this.bump();
    const all: number[] = [];
    for (let i = 0; i < this.profiles.length; i++) {
      all.push(i);
    }
    await this.runPool(all, Index.TEST_CONCURRENCY);
    this.testing = false;
    this.testInfo = '';
    this.sortByDelay = true;
    this.profiles = this.profiles.slice();
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

  /** 清除本机运行日志（ui.log + vpn.log）。系统日志 hilog 归系统所有，应用无权清理。 */
  clearRunLog(): void {
    FileStore.clearLogs(this.filesDir);
    this.toast.showToast({ message: '运行日志已清除' });
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
    hilog.info(0x0000, 'V2rayNG-UI', 'rule fetched, bytes=%{public}d', body.length);
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
            Text('传输').fontSize(15).width(80).fontColor('#4A4A4A')
            Row({ space: 8 }) {
              this.chip('tcp', this.eNetwork, () => { this.eNetwork = 'tcp'; })
              this.chip('ws', this.eNetwork, () => { this.eNetwork = 'ws'; })
              this.chip('grpc', this.eNetwork, () => { this.eNetwork = 'grpc'; })
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

  // 左滑露出的操作：编辑 / 删除；平时不占位，避免点选节点时误触
  @Builder
  nodeSwipe(index: number) {
    Row() {
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

        Text(Index.delayText(row.delay))
          .fontSize(15)
          .fontColor(row.delay >= 0 && row.delay < 1500 ? '#2E7D32' : '#8A8A8A')
          .onClick(() => {
            this.testOne(row.nodeIndex);
          })

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
    if (row.groupKey.length === 0) {
      // 手动节点：一张一张独立的卡片
      Column() {
        this.nodeContent(row)
      }
      .width('100%')
      .padding(12)
      .borderRadius(10)
      .backgroundColor(row.selected ? '#EAF1FF' : '#F5F5F5')
      .margin({ top: 8 })
      .onClick(() => {
        this.selectNode(row.nodeIndex);
      })
    } else {
      // 订阅组：同组节点连成一整块，和上面的组头共用一块底色
      Column() {
        this.nodeContent(row)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .borderRadius({
        topLeft: row.firstInBlock ? 12 : 0,
        topRight: row.firstInBlock ? 12 : 0,
        bottomLeft: row.lastInBlock ? 12 : 0,
        bottomRight: row.lastInBlock ? 12 : 0
      })
      .backgroundColor(row.selected ? '#E3ECFF' : '#F5F7FC')
      .onClick(() => {
        this.selectNode(row.nodeIndex);
      })
    }
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
        Row({ space: 7 }) {
          Text(row.groupOpen ? '▾' : '▸')
            .fontSize(24)
            .fontColor('#2E2E2E')
            .height(34)
            .width(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.toggleKey(row.groupKey);
            })
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
          if (this.sortByDelay && row.groupCount > 1) {
            Text('↓')
              .fontSize(15)
              .fontColor('#2E7D32')
          }
          Text(String(row.groupCount) + ' 个')
            .fontSize(13)
            .fontColor('#5F6B7A')
            .onClick(() => {
              this.toggleKey(row.groupKey);
            })

          // 改名：铅笔（描边轮廓 + 笔尖分界线）
          Row() {
            Image($r('app.media.ic_pencil')).width(20).height(20).objectFit(ImageFit.Contain)
          }
          .width(36)
          .height(36)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#F1F5FF')
          .borderRadius(18)
          .border({ width: 1, color: '#DCE7FF' })
          .onClick(() => {
            this.openRename(row.groupKey);
          })

          // 更新：半圆箭头
          Row() {
            Image($r('app.media.ic_refresh')).width(20).height(20).objectFit(ImageFit.Contain)
          }
          .width(36)
          .height(36)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#F1F5FF')
          .borderRadius(18)
          .border({ width: 1, color: '#DCE7FF' })
          .onClick(() => {
            this.refreshGroup(row.groupKey);
          })

          // 测速：闪电
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
          .onClick(() => {
            this.importSubscription();
          })

        Text('单条链接').fontSize(14).fontColor('#5A5A5A')

        TextArea({ text: this.linkInput, placeholder: '粘贴 vmess:// vless:// ss:// trojan:// 链接，一行一个' })
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

        Button('设置 · 分流规则')
          .width('100%')
          .height(44)
          .fontSize(15)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.openRules();
          })

        Button('清除运行日志')
          .width('100%')
          .height(44)
          .fontSize(15)
          .backgroundColor('#F0F0F0')
          .fontColor('#333333')
          .onClick(() => {
            this.clearRunLog();
          })

        Text('运行日志只存在本机应用目录，记录连接状态与出口探测结果，保留最近 240 行。')
          .fontSize(13)
          .fontColor('#5A5A5A')

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
            Text('v2rayNG 鸿蒙版').fontSize(21).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            Text(this.summary).fontSize(13).fontColor('#FFE3E3')
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

          // 长时任务连续申请失败时给出可见提示，不再静默地显示「已连接」
          if (this.keepAliveWarn.length > 0) {
            Text(this.keepAliveWarn)
              .fontSize(12)
              .fontColor('#B26A00')
              .width('100%')
              .padding({ left: 12, right: 12 })
          }

          if (this.running) {
            // 出口 IP + 国家地区单独占一行：和流量挤在一起时地区会被省略掉
            Text(this.exitInfo.length > 0 ? this.exitInfo : (this.exitBusy ? '正在测出口 IP…' : '点此测出口 IP'))
              .fontSize(14)
              .fontColor(this.exitBlocked ? '#7A7A7A' : (this.exitInfo.length > 0 ? '#2E7D32' : '#7A7A7A'))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 12, right: 12, top: 9, bottom: 9 })
              .borderRadius(10)
              .backgroundColor(this.exitBlocked ? '#F2F3F5' : '#EAF6EA')
              .border({ width: 1, color: this.exitBlocked ? '#E2E4E8' : '#CFE8CF' })
              .shadow({ radius: 8, color: '#14000000', offsetX: 0, offsetY: 2 })
              .onClick(() => {
                if (!this.exitBusy) {
                  this.exitEmptyStreak = 0;
                  this.exitBlocked = false;
                  this.refreshExit(1);
                }
              })
          }

          // 测速进度单独一张卡：和流量计数挤一行会被省略号吃掉
          if (this.testInfo.length > 0) {
            Text(this.testInfo).fontSize(14).fontColor('#B25B3E')
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
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

        Row({ space: 10 }) {
          Button('添加节点').layoutWeight(1).height(38).fontSize(14)
            .backgroundColor('#F0F0F0').fontColor('#333333')
            .onClick(() => {
              this.addNew();
            })
          Button(this.updatingAll ? '更新中…' : '全部更新').layoutWeight(1).height(38).fontSize(14)
            .backgroundColor('#F0F0F0').fontColor('#333333')
            .enabled(!this.updatingAll && !this.testing)
            .onClick(() => {
              this.updateAllSubscriptions();
            })
          Button(this.testing ? '测速中…' : '全部测速').layoutWeight(1).height(38).fontSize(14)
            .backgroundColor('#F0F0F0').fontColor('#333333')
            .enabled(!this.testing && !this.updatingAll)
            .onClick(() => {
              this.testAll();
            })
        }.width('100%')

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

      if (this.rulePanel) {
        this.rulesPanel()
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
    }
    .width('100%')
    .height('100%')
  }
}
