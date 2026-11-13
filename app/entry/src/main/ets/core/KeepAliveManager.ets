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
import { BusinessError } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { FileStore } from './FileStore';

const BUNDLE_NAME: string = 'com.maoxu.v2rayng';
const ENTRY_ABILITY: string = 'EntryAbility';
/** 常态复核间隔：≥30s，避免「系统取消/暂停长时任务后立即再次申请」红线 */
const ENSURE_INTERVAL_MS: number = 30000;
/** force 调用的最小去重间隔：连接成功路径与 readState 边沿可能相隔几百毫秒
 * 连续触发，2s 内只申请一次，避免重复 startBackgroundRunning */
const FORCE_MIN_GAP_MS: number = 2000;
/** stop 成功后的冷却窗口（官方要求不得在停止后立即再次申请） */
const COOLDOWN_MS: number = 30000;
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
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    this.userStopped = FileStore.readUserStopped(this.filesDir);
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
    if (!this.canAutoRecover()) {
      return;
    }
    const now: number = Date.now();
    // 节流放在任何 IO 之前：readState() 每 1s 调一次本方法，绝大多数
    // 调用只做时间戳比较就返回，不加剧 IO / 并发写冲突。
    // force 也做 2s 去重：connect 成功路径与 readState 边沿可能紧邻触发。
    const gap: number = force ? FORCE_MIN_GAP_MS : ENSURE_INTERVAL_MS;
    if (now - this.lastEnsureAt < gap) {
      return;
    }
    if (this.ensuring) {
      return;
    }
    // 已持有短路：任务已在系统里且未被 noteTaskCancelled()/stop() 标记失效时，
    // 不再重复申请（真机 21:21:19 起证明重复申请会被拒为 9800005 并刷失败日志）。
    if (this.keepAliveOk) {
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
        this.keepAliveOk = true;
        this.failStreak = 0;
        FileStore.appendLog(filesDir, 'continuous task already applied, treat as ok');
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
   * 判定 state.json 是否表示「扩展异常销毁、非用户主动停止」。
   * 双校验缺一不可：userStopped 必须显式为 false，message 必须恰好是「已断开」
   * （该文案只由 VpnExtAbility.onDestroy 写出；用户主动停止写「未连接」）。
   * 字段缺失兼容：running/message/userStopped 分别按 false/''/false 处理。
   * 扩展 writeState() 会带上 userStopped，所以用户主动停止的意图不会被覆盖丢失。
   */
  isAbnormalDisconnect(filesDir: string): boolean {
    const text: string = FileStore.readText(FileStore.statePath(filesDir));
    if (text.length === 0) {
      return false;
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
      return false;
    }
    return !running && userStopped === false && message === '已断开';
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
