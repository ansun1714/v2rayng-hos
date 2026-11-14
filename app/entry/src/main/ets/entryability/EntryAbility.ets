import { common, AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { KeepAliveManager } from '../core/KeepAliveManager';
import { FileStore } from '../core/FileStore';

const DOMAIN: number = 0x0001;
const TAG: string = 'V2rayM';
const BUNDLE_NAME: string = 'com.maoxu.v2rayng';
/** 看门狗 workId：固定值，重复 startWork 覆盖同 id 任务，天然幂等 */
const WATCHDOG_WORK_ID: number = 1001;
/** module.json5 中 type=workScheduler 的扩展 ability 名 */
const WATCHDOG_ABILITY: string = 'VpnWatchdogExtAbility';
/** WorkInfo.repeatCycleTime 官方文档下限 20 分钟（1200000ms）；d.ts 未写下限，
 * 若被系统判为非法，startWork 会抛 9700004，日志里能看到 */
const WATCHDOG_CYCLE_MS: number = 1200000;

export default class EntryAbility extends UIAbility {
  /** 上一次成功注册看门狗的时刻：用来给 refreshWatchdog 限频 */
  private lastWatchdogRefresh: number = 0;
  /** 看门狗重注册的最小间隔 */
  static readonly WATCHDOG_REFRESH_MS: number = 1800000;
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    // 界面进程的日志走 ui.log，与扩展进程的 vpn.log 分开，避免两个进程
    // 「读全文件 + 整文件重写」同一文件时互相覆盖、截断出 NUL 空洞。
    FileStore.setLogChannel('ui');
    // 注入应用级 UIAbilityContext：长时任务必须由它申请，且 userStopped 的
    // 持久化要在页面出现、用户点击之前就恢复完成。
    KeepAliveManager.getInstance().init(this.context as common.UIAbilityContext);
    // 注册系统级看门狗：UI 被冻结时页面定时器全停，只有系统周期任务还能兜底。
    // 走 refreshWatchdog 而不是直接 startWork：进程重启时旧任务往往还在，
    // 直接 start 只会得到 9700005 already added（09:39:17 日志第一条就是这个）
    this.refreshWatchdog();
    // 看门狗拉起本 Ability 时带 fromWatchdog=true：只置既有 needRecover 标记，
    // 由页面的 consumeNeedRecover() 走同一条恢复链路，不新增第二套恢复入口。
    const fromWatchdog: Object | undefined = want.parameters?.fromWatchdog;
    if (fromWatchdog !== undefined && fromWatchdog !== null && String(fromWatchdog) === 'true') {
      this.onLaunchedByWatchdog();
    }
    // 支持 aa start --ps importUri "<链接>" 一次性导入（便于自动化与批量导入）
    const extra: Object | undefined = want.parameters?.importUri;
    if (extra !== undefined && extra !== null) {
      const text: string = String(extra);
      if (text.length > 0) {
        AppStorage.setOrCreate<string>('launchImportUri', text);
        hilog.info(DOMAIN, TAG, 'received importUri, length=%{public}d', text.length);
      }
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  /**
   * 注册系统级周期看门狗（WorkSchedulerExtensionAbility）。
   * workId 固定 ⇒ 每次重复 startWork 都是同一个任务；
   * isPersisted=true ⇒ 设备重启后任务仍在；isRepeat + 20 分钟 ⇒ 至少每 20 分钟
   * 被系统唤起一次，用来兜住「UI 进程被冻结、页面定时器全停」的场景。
   * 注意：重复 startWork 并不幂等，任务已存在时会抛 9700005，所以注册统一走 refreshWatchdog。
   */
  private registerWatchdog(): void {
    this.startWatchdogWork('watchdog: work registered');
  }

  /**
   * 重新注册看门狗。真机 11-14 日志证据：01:57 注册、07:07 只 tick 一次、
   * 07:23 收到 work stop 之后到 09:10 再无任何 tick —— 系统的周期任务会被
   * 静默停掉。单纯再调一次 startWork 只会得到 9700005（already added），
   * 必须先用 stopAndClearWorks 把旧的清掉（stopWork 单条清理在实际设备上
   * 没能生效，日志里 09:29 仍是 already added），再重新注册。
   * 限频 30 分钟：频繁切前后台不该反复重置周期计时，否则永远等不到第一次 tick。
   */
  private refreshWatchdog(): void {
    const filesDir: string = this.context.filesDir;
    const now: number = Date.now();
    if (this.lastWatchdogRefresh > 0 &&
      now - this.lastWatchdogRefresh < EntryAbility.WATCHDOG_REFRESH_MS) {
      return;
    }
    this.lastWatchdogRefresh = now;
    try {
      workScheduler.stopAndClearWorks();
      FileStore.appendLog(filesDir, 'watchdog: old work cleared');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      FileStore.appendLog(filesDir, 'watchdog: stopAndClearWorks failed code=' +
        String(be.code !== undefined ? be.code : -1) + ' msg=' + String(be.message));
    }
    this.startWatchdogWork('watchdog: work refreshed');
  }

  private startWatchdogWork(tag: string): void {
    const filesDir: string = this.context.filesDir;
    const work: workScheduler.WorkInfo = {
      workId: WATCHDOG_WORK_ID,
      bundleName: BUNDLE_NAME,
      abilityName: WATCHDOG_ABILITY,
      isRepeat: true,
      repeatCycleTime: WATCHDOG_CYCLE_MS,
      isPersisted: true
    };
    try {
      workScheduler.startWork(work);
      this.lastWatchdogRefresh = Date.now();
      FileStore.appendLog(filesDir, tag + ' (cycle=' + String(WATCHDOG_CYCLE_MS) + 'ms)');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      FileStore.appendLog(filesDir, 'watchdog: startWork failed code=' +
        String(be.code !== undefined ? be.code : -1) + ' msg=' + String(be.message));
    }
  }

  /**
   * 看门狗把本 Ability 拉起后的收尾：只在「确认异常 + 未用户停止 + 已过冷却」
   * 时置 needRecover，交给 Index.consumeNeedRecover() 去调 scheduleRecover()。
   * 双校验缺一不可：abnormalKind() 已内含 userStopped===false，canAutoRecover()
   * 再挡冷却与用户停止，用户主动断开后绝不会被看门狗抢连回来。
   */
  private onLaunchedByWatchdog(): void {
    const filesDir: string = this.context.filesDir;
    const mgr: KeepAliveManager = KeepAliveManager.getInstance();
    const kind: string = mgr.abnormalKind(filesDir);
    if (kind.length === 0 || !mgr.canAutoRecover()) {
      FileStore.appendLog(filesDir, 'watchdog: launch ignored (kind=' +
        (kind.length === 0 ? 'none' : kind) + ')');
      return;
    }
    AppStorage.setOrCreate<boolean>('needRecover', true);
    FileStore.appendLog(filesDir, 'watchdog: recover requested (' + kind + ')');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
      // 冷启动时 onForeground 可能早于页面加载：这里确认标记还在（AppStorage
      // 跨页面存活），留给 Index.aboutToAppear / pollTimer 消费，避免丢事件。
      if (AppStorage.get<boolean>('needRecover') === true) {
        FileStore.appendLog(this.context.filesDir,
          'loadContent: needRecover pending before page ready');
      }
    });
  }

  onWindowStageDestroy(): void {
  }

  /** 回到前台：打状态快照并立即复核一次长时任务（force）。 */
  onForeground(): void {
    const mgr: KeepAliveManager = KeepAliveManager.getInstance();
    mgr.snapshot('onForeground');
    // 每次回前台都把看门狗重置一次：系统的周期任务会被静默停掉（见 refreshWatchdog 注释）
    this.refreshWatchdog();
    mgr.ensureRunning(this.context as common.UIAbilityContext, true)
      .catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'ensure onForeground failed: %{public}s', err.message);
      });
    // 冷启动 / 回前台兜底：页面组件被系统回收时，这一层比页面定时器更可靠。
    // 只做「异常断开 + 已过冷却」判定并登记请求，由 Index 在 aboutToAppear
    // 或 1s pollTimer 中消费后调 scheduleRecover()。
    // 全工程仅 Index.connectInternal 一处允许 startVpnExtensionAbility，
    // 这里绝不直接拉起扩展；一次性登记标志保证不会与页面重复触发。
    const filesDir: string = (this.context as common.UIAbilityContext).filesDir;
    if (mgr.requestColdStartHeal(filesDir)) {
      FileStore.appendLog(filesDir, 'cold start recover requested by onForeground');
    }
    // 系统 VPN 交叉校验：state.json 的 running 可能是扩展被 SIGKILL 前的残留
    // （onDestroy 没执行），只信文案会永久卡在「假连接」。onForeground 由系统
    // 稳定投递、不受应用冻结影响，是唯一可靠的纠错时点。
    // 判定结果只写 AppStorage，由页面 pollTimer / aboutToAppear 消费后调
    // scheduleRecover()——全工程仍只有 Index 一处允许拉起 vpnExtension。
    mgr.hasSystemVpn().then((alive: boolean): void => {
      // 三个前置缺一不可：系统里有 VPN / 用户主动停止 / 状态本来就说没连着
      // —— 最后一条防止「从未连接过的新装应用」被误判成掉线并自动连上。
      if (alive || mgr.isUserStopped() || !mgr.stateSaysRunning(filesDir)) {
        return;
      }
      AppStorage.setOrCreate<boolean>('needRecover', true);
      FileStore.appendLog(filesDir, 'onForeground: vpn missing while state says running');
    }).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'onForeground cross-check failed: %{public}s', err.message);
    });
  }

  /** 切后台：同样复核一次；无业务或用户已停止时管理器会自行跳过。 */
  onBackground(): void {
    const mgr: KeepAliveManager = KeepAliveManager.getInstance();
    mgr.snapshot('onBackground');
    mgr.ensureRunning(this.context as common.UIAbilityContext, false)
      .catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'ensure onBackground failed: %{public}s', err.message);
      });
  }
}
