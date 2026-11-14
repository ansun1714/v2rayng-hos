/**
 * 长时任务（连续任务）统一管理，应用级单例。
 *
 * 真机 vpn.log 实测结论（本类要修掉的问题）：
 * - 旧实现把申请挂在 Index 组件 readState() 的 running false→true 边沿上，
 *   而 bgRunning 只是组件实例布尔量。14:10 / 14:14 两次重连既没有
 *   「continuous task started (ui)」也没有「failed code=」，说明 requestKeepAlive()
 *   根本没被调用，整个 69 分钟后台期没有长时任务，扩展进程被系统回收。
 * - 15:34:21 的「stop failed code=9800005」说明组件内布尔量与系统实际状态
 *   并不同步，不能再拿它当唯一真值。
 *
 * 因此这里把状态收敛到进程内唯一单例，由 UIAbilityContext 调用后台任务 API，
 * 采用「状态驱动 + 低频复核」而不是「边沿触发」，并集中管理用户主动停止意图、
 * 冷却窗口与自动恢复门禁。
 */
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError, Callback } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { connection } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { FileStore } from './FileStore';
import { AppSettings } from './Model';

const BUNDLE_NAME: string = 'com.maoxu.v2rayng';
const ENTRY_ABILITY: string = 'EntryAbility';
/** 常态复核间隔：≥30s 真调一次 startBackgroundRunning，作为系统侧任务的健康探针 */
const ENSURE_INTERVAL_MS: number = 30000;
/** stop 成功后的冷却窗口（官方要求不得在停止后立即再次申请） */
const COOLDOWN_MS: number = 30000;
/** state.json 心跳阈值：扩展 statsTimer 每 8s 重写一次状态文件，
 * 超过 30s（≈3.75 个写入周期）没更新即判定扩展进程已死 */
const HEARTBEAT_STALE_MS: number = 30000;
/** 连续失败达到该次数即认为保活不可用，供界面提示，不再静默 */
const WARN_STREAK: number = 2;

/** 冷启动自愈判定所需的 state.json 字段（其余统计字段忽略，兼容字段缺失）。 */
interface ColdStartState {
  running?: boolean;
  message?: string;
  userStopped?: boolean;
}

export class KeepAliveManager {
  private static instance: KeepAliveManager | undefined = undefined;

  private filesDir: string = '';
  /** 最近一次申请/复核是否成功（仅作参考，不是系统真值） */
  private keepAliveOk: boolean = false;
  private lastEnsureAt: number = 0;
  private bgCooldownUntil: number = 0;
  /** 用户主动停止：自动恢复与重申请的唯一硬门禁，持久化在 state.json */
  private userStopped: boolean = false;
  private failStreak: number = 0;
  private ensuring: boolean = false;
  private lastStopAt: number = 0;
  private loaded: boolean = false;
  /** 冷启动自愈：进程内只登记一次，避免 Index 与 EntryAbility 重复触发 */
  private coldStartHealDone: boolean = false;
  /** 待页面消费的自愈请求：EntryAbility 不能直接调页面的 scheduleRecover() */
  private coldStartHealPending: boolean = false;
  /** 保存 UIAbilityContext：continuousTaskCancel 回调里要用它立即重申请 */
  private ctx: common.UIAbilityContext | undefined = undefined;
  /** 取消监听句柄：保证 off 时传同一引用，避免重复注册 */
  private cancelListener: Callback<backgroundTaskManager.ContinuousTaskCancelInfo> | undefined =
    undefined;
  /** 是否已注册取消监听（进程内一次） */
  private cancelRegistered: boolean = false;

  private constructor() {
  }

  /** 请使用 getInstance()，保证进程内状态唯一。 */
  static getInstance(): KeepAliveManager {
    if (KeepAliveManager.instance === undefined) {
      KeepAliveManager.instance = new KeepAliveManager();
    }
    return KeepAliveManager.instance;
  }

  /**
   * 注入 UIAbilityContext 并恢复用户意图（幂等，可重复调用）。
   * userStopped 存于 state.json，字段缺失按 false 处理，兼容旧版本状态文件。
   */
  init(ctx: common.UIAbilityContext): void {
    this.filesDir = ctx.filesDir;
    // 取消回调里拿不到 ctx，必须在这里留一份引用，才能「被取消后立即重申请」
    this.ctx = ctx;
    this.registerCancelListener();
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    this.userStopped = FileStore.readUserStopped(this.filesDir);
  }

  /**
   * 注册连续任务取消回调（API 15+，签名见
   * @ohos.resourceschedule.backgroundTaskManager.d.ts L427）。
   * 为什么必须有：真机 11-13 挂机断连后 state.json 残留 running:true、且没有任何
   * 定时器日志，此前完全看不到「系统把长时任务取消了」这件事。ContinuousTaskCancelReason
   * 里明确有 SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED（dataTransfer 模式低速被取消），
   * 夜间几乎无流量时最容易命中——这条监听把「静默丢失」变成「可观测 + 可自愈」。
   */
  private registerCancelListener(): void {
    if (this.cancelRegistered) {
      return;
    }
    const listener: Callback<backgroundTaskManager.ContinuousTaskCancelInfo> =
      (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
        this.onContinuousTaskCancelled(info);
      };
    try {
      // 幂等：重复 on 同一个 type 会报 401（参数错误），所以先 off 再 on
      if (this.cancelListener !== undefined) {
        backgroundTaskManager.off('continuousTaskCancel', this.cancelListener);
      }
      backgroundTaskManager.on('continuousTaskCancel', listener);
      this.cancelListener = listener;
      this.cancelRegistered = true;
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      FileStore.appendLog(this.filesDir, 'continuous task cancel listen failed code=' +
        String(be.code !== undefined ? be.code : -1));
    }
  }

  /** 连续任务被取消：记原因 → 置失效 → 立即重申请（用户主动停止时跳过）。 */
  private onContinuousTaskCancelled(info: backgroundTaskManager.ContinuousTaskCancelInfo): void {
    const reason: number = info.reason;
    FileStore.appendLog(this.filesDir, 'continuous task cancelled, reason=' + String(reason) +
      '(' + this.cancelReasonText(reason) + ') taskId=' + String(info.id));
    this.keepAliveOk = false;
    this.noteTaskCancelled();
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined || !this.canAutoRecover()) {
      return;
    }
    this.ensureRunning(ctx, true).catch((err: Error) => {
      FileStore.appendLog(this.filesDir, 're-apply after cancel failed: ' + err.message);
    });
  }

  /** 取消原因码 → 可读文案（枚举值见 ContinuousTaskCancelReason，API 15） */
  private cancelReasonText(reason: number): string {
    switch (reason) {
      case backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL:
        return 'user_cancel';
      case backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL:
        return 'system_cancel';
      case backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION:
        return 'user_cancel_remove_notification';
      case backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED:
        return 'system_cancel_data_transfer_low_speed';
      case backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_USE_ILLEGALLY:
        return 'system_cancel_use_illegally';
      default:
        return 'other';
    }
  }

  /** VPN 是否真的在运行：以 state.json 为准，没有业务时不申请（一致性校验） */
  private vpnActive(): boolean {
    if (this.filesDir.length === 0) {
      return false;
    }
    const text: string = FileStore.readText(FileStore.statePath(this.filesDir));
    return text.indexOf('"running":true') >= 0;
  }

  /**
   * 确保长时任务处于申请状态。
   * force=true 用于「真正连上」「回到前台」等关键时点立即复核；常态由 ≥30s
   * 间隔节流，由 Index.readState() 在 running 为 true 期间周期性调用，不依赖边沿。
   * 门禁：canAutoRecover()（用户停止 / 冷却红线）、低频节流、并发互斥。
   * 不读 state.json 判断业务是否运行：扩展启动是异步的，连接成功瞬间状态文件
   * 可能还停在 running=false，读它会把这次申请误挡掉（这正是「漏申请」的一种）。
   * 调用方已保证时机：readState 只在 running=true 时调，connect 只在启动成功后调。
   */
  async ensureRunning(ctx: common.UIAbilityContext, force: boolean): Promise<void> {
    this.filesDir = ctx.filesDir;
    if (!this.loaded) {
      this.init(ctx);
    }
    const filesDir: string = ctx.filesDir;
    // 后台保活被用户关闭：不申请长时任务，也不进冷却/节流逻辑
    if (this.keepAliveDisabled()) {
      return;
    }
    if (!this.canAutoRecover()) {
      return;
    }
    const now: number = Date.now();
    // 节流放在任何 IO 之前：readState() 每 1s 调一次本方法，绝大多数调用只做
    // 时间戳比较就返回；force（连上瞬间 / 回到前台 / 任务被取消）立即真调一次。
    // ⚠ 这里刻意**不再**保留「keepAliveOk 已持有就直接返回」的盲短路：上一版
    // 正是它让系统侧任务被取消后永不重申请、永不报错，也把 onForeground 的
    // force 复核一起吃掉了，最终形成真机 11-13 23:23 之后「UI 说已连接、实际
    // 没有 :vpn」的静默假连接。重复申请由系统返回 9800005 兜底（见下方幂等分支）。
    if (!force && now - this.lastEnsureAt < ENSURE_INTERVAL_MS) {
      return;
    }
    if (this.ensuring) {
      return;
    }
    this.lastEnsureAt = now;
    this.ensuring = true;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: BUNDLE_NAME,
            abilityName: ENTRY_ABILITY
          }
        ],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      // 字符串数组写法真机已验证可成功（20:12:23），不要改成枚举或换 bgMode 类型
      await backgroundTaskManager.startBackgroundRunning(ctx, ['dataTransfer'], agent);
      this.keepAliveOk = true;
      this.failStreak = 0;
      FileStore.appendLog(filesDir, 'continuous task started (ui)');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      const code: number = be.code !== undefined ? be.code : -1;
      const msg: string = String(be.message);
      // 失败幂等：系统报「已申请过连续任务」说明任务实际在持有（force 路径与
      // 系统状态失同步的兜底），视为成功，不计失败、不增 failStreak。
      if (code === 9800005 && msg.indexOf('applied for a continuous task') !== -1) {
        const wasOk: boolean = this.keepAliveOk;
        // 先置 true 再返回，保证状态一致（不能提前 return 而不改状态）
        this.keepAliveOk = true;
        this.failStreak = 0;
        // 30s 周期的真复核每次都会命中这条，若每次都记会把 240 行环形日志冲掉，
        // 只在「从异常恢复为已持有」时记一笔。
        if (!wasOk) {
          FileStore.appendLog(filesDir, 'continuous task already applied, treat as ok');
        }
        return;
      }
      this.keepAliveOk = false;
      this.failStreak++;
      FileStore.appendLog(filesDir, 'continuous task failed code=' + String(code) +
        ' msg=' + msg);
    } finally {
      this.ensuring = false;
    }
  }

  /**
   * 释放长时任务。即使 keepAliveOk 为 false 也会尝试一次（真机 15:34:21
   * 证明布尔量与系统状态会失同步），仅以 2s 去重避免重复系统调用。
   * stop 成功后写 30s 冷却，规避「用户/系统停止后立即再次申请」红线。
   */
  async stop(ctx: common.UIAbilityContext): Promise<void> {
    this.filesDir = ctx.filesDir;
    const filesDir: string = ctx.filesDir;
    const now: number = Date.now();
    if (now - this.lastStopAt < 2000) {
      return;
    }
    this.lastStopAt = now;
    this.keepAliveOk = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      this.bgCooldownUntil = Date.now() + COOLDOWN_MS;
      FileStore.appendLog(filesDir, 'continuous task stopped (ui)');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      FileStore.appendLog(filesDir, 'continuous task stop failed code=' +
        String(be.code !== undefined ? be.code : -1));
    }
  }

  /**
   * 记录「用户主动开始 / 停止」。只允许在用户点击连接、停止代理时调用；
   * 自动恢复路径不得调用，避免把系统回收误判成用户意图。
   * 持久化到 state.json（与 running/message/up/down 共存，字段缺失按 false）。
   */
  setUserStopped(value: boolean): void {
    this.userStopped = value;
    if (this.filesDir.length > 0) {
      FileStore.writeUserStopped(this.filesDir, value);
    }
    if (!value) {
      // 用户主动重新开始：清零冷却，允许立即申请（官方允许「用户主动开始」）
      this.bgCooldownUntil = 0;
      this.failStreak = 0;
    }
  }

  /** 检出 VPN 丢失（疑似任务被系统取消）：只标记失效，不额外设冷却，
   * 让自动恢复按 5→10→20→60s 节退自行推进。 */
  noteTaskCancelled(): void {
    this.keepAliveOk = false;
  }

  /** 自动恢复 / 重新申请的统一门禁 */
  canAutoRecover(): boolean {
    if (this.userStopped) {
      return false;
    }
    return Date.now() > this.bgCooldownUntil;
  }

  /** 冷却剩余毫秒（无冷却时为 0），供自动恢复把冷却并入回退间隔 */
  cooldownRemaining(): number {
    return Math.max(0, this.bgCooldownUntil - Date.now());
  }

  /**
   * 读 settings.json 里的连接行为开关。字段缺失 / 文件不存在 / 解析失败一律按 true，
   * 兼容旧版本（旧 settings.json 只有并发与包大小）。
   */
  private settingsFlag(name: string): boolean {
    if (this.filesDir.length === 0) {
      return true;
    }
    const text: string = FileStore.readText(FileStore.settingsPath(this.filesDir));
    if (text.length === 0) {
      return true;
    }
    try {
      const st: AppSettings = JSON.parse(text) as AppSettings;
      let v: boolean | undefined;
      if (name === 'keepAlive') {
        v = st.keepAlive;
      } else if (name === 'autoConnect') {
        v = st.autoConnect;
      } else if (name === 'failover') {
        v = st.failover;
      }
      return v === undefined ? true : v === true;
    } catch (err) {
      return true;
    }
  }

  /** 后台保活开关是否关闭（关闭后不申请长时任务）。 */
  keepAliveDisabled(): boolean {
    return !this.settingsFlag('keepAlive');
  }

  /** 自动连接开关是否关闭（关闭后冷启动 / 掉线不自动重连）。 */
  autoConnectDisabled(): boolean {
    return !this.settingsFlag('autoConnect');
  }

  isUserStopped(): boolean {
    return this.userStopped;
  }

  isKeepAliveOk(): boolean {
    return this.keepAliveOk;
  }

  getFailStreak(): number {
    return this.failStreak;
  }

  /** 连续失败且 VPN 在运行 → 界面提示文案；否则空串（不再静默） */
  warningText(vpnRunning: boolean): string {
    if (this.userStopped || !vpnRunning || this.failStreak < WARN_STREAK) {
      return '';
    }
    return '后台保活未启用，切后台可能被系统断开';
  }

  /**
   * 系统里当前是否真的有 VPN 通道（权威判断，优于 state.json 的 running 文案）。
   * 与 Index.hasSystemVpn() 同实现：getAllNets + getNetCapabilities + BEARER_VPN。
   */
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
      FileStore.appendLog(this.filesDir, 'hasSystemVpn failed: ' + String(err));
    }
    return false;
  }

  /**
   * state.json 心跳是否过期。扩展的 statsTimer 每 8s 用 writeText 整文件重写一次
   * state.json（VpnExtAbility.startStatsLoop，L443-468），所以只要扩展活着，mtime
   * 最多 8s 就前进一次。扩展被 SIGKILL 时 onDestroy 不会执行，state.json 会永久
   * 残留 running:true —— 心跳是识别这种「假连接」最可靠的信号。
   * 阈值 30s（≈3.75 个写入周期），避开偶发 IO 卡顿误判。
   * ⚠ Stat.mtime 单位是**秒**，必须 ×1000 再与 Date.now()（毫秒）比较。
   */
  stateHeartbeatStale(filesDir: string): boolean {
    const path: string = FileStore.statePath(filesDir);
    const text: string = FileStore.readText(path);
    if (text.length === 0 || text.indexOf('"running":true') < 0) {
      return false;
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      const mtimeMs: number = stat.mtime * 1000;
      return Date.now() - mtimeMs > HEARTBEAT_STALE_MS;
    } catch (err) {
      return false;
    }
  }

  /**
   * state.json 是否声称「正在运行」。交叉校验的**前置条件**：只有在系统认为
   * 应该连着的时候，才允许把「系统里没有 VPN」当成异常去恢复。
   * 没有这一条，从未连接过的新装应用（running:false / 「未连接」/ userStopped:false）
   * 会在每次 onForeground 被误判成掉线并自动连上，属于严重误连。
   */
  stateSaysRunning(filesDir: string): boolean {
    const text: string = FileStore.readText(FileStore.statePath(filesDir));
    return text.indexOf('"running":true') >= 0;
  }

  /**
   * 异常来源标签，仅用于日志区分（'' = 无异常）：
   * - 'abnormal disconnect'：!running && message==='已断开'（扩展走了 onDestroy）
   * - 'stale heartbeat'：running===true 但 state.json mtime 超 30s 未更新
   *   （扩展被 SIGKILL，onDestroy 没跑，状态文件停在「已连接」）
   * 两种情况都要求 userStopped===false——用户主动停止的「未连接」+userStopped=true
   * 必须一律排除，绝不能被自动抢连回来。
   */
  abnormalKind(filesDir: string): string {
    const text: string = FileStore.readText(FileStore.statePath(filesDir));
    if (text.length === 0) {
      return '';
    }
    let running: boolean = false;
    let message: string = '';
    let userStopped: boolean = false;
    try {
      const state: ColdStartState = JSON.parse(text) as ColdStartState;
      running = state.running === undefined ? false : state.running;
      message = state.message === undefined ? '' : state.message;
      userStopped = state.userStopped === undefined ? false : state.userStopped;
    } catch (err) {
      return '';
    }
    if (userStopped !== false) {
      return '';
    }
    if (!running && message === '已断开') {
      return 'abnormal disconnect';
    }
    if (running && this.stateHeartbeatStale(filesDir)) {
      return 'stale heartbeat';
    }
    return '';
  }

  /**
   * 判定 state.json 是否表示「扩展已死、非用户主动停止」。两种来源合入：
   * 正常断开（running=false + 「已断开」）或心跳过期（running=true 但 mtime 不动）。
   */
  isAbnormalDisconnect(filesDir: string): boolean {
    return this.abnormalKind(filesDir).length > 0;
  }

  /**
   * 一次性登记冷启动自愈请求。Index.aboutToAppear 与 EntryAbility.onForeground
   * 都会调用；单例 + coldStartHealDone 保证进程内只登记一次。
   * canAutoRecover() 再挡一道「用户主动停止 / 停止后立即重申请」红线；
   * scheduleRecover() 内部还会把 cooldownRemaining() 并入延迟。
   */
  requestColdStartHeal(filesDir: string): boolean {
    if (this.coldStartHealDone || !this.canAutoRecover()) {
      return false;
    }
    // 自动连接被用户关闭：冷启动不登记自愈请求
    if (this.autoConnectDisabled()) {
      return false;
    }
    if (!this.isAbnormalDisconnect(filesDir)) {
      return false;
    }
    this.coldStartHealDone = true;
    this.coldStartHealPending = true;
    return true;
  }

  /** 取走并清除待处理的冷启动自愈请求（页面侧调用）。 */
  consumeColdStartHeal(): boolean {
    if (!this.coldStartHealPending) {
      return false;
    }
    this.coldStartHealPending = false;
    return true;
  }

  /** onForeground / onBackground 的状态快照，便于真机一次抓日志定位 */
  snapshot(where: string): void {
    if (this.filesDir.length === 0) {
      return;
    }
    FileStore.appendLog(this.filesDir, 'keepalive: snapshot ' + where +
      ' userStopped=' + String(this.userStopped) +
      ' ok=' + String(this.keepAliveOk) +
      ' streak=' + String(this.failStreak) +
      ' cooldownIn=' + String(this.cooldownRemaining()) +
      ' vpn=' + String(this.vpnActive()));
  }
}
