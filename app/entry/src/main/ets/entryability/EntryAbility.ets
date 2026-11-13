import { common, AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { KeepAliveManager } from '../core/KeepAliveManager';
import { FileStore } from '../core/FileStore';

const DOMAIN: number = 0x0001;
const TAG: string = 'V2rayNG';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    // 界面进程的日志走 ui.log，与扩展进程的 vpn.log 分开，避免两个进程
    // 「读全文件 + 整文件重写」同一文件时互相覆盖、截断出 NUL 空洞。
    FileStore.setLogChannel('ui');
    // 注入应用级 UIAbilityContext：长时任务必须由它申请，且 userStopped 的
    // 持久化要在页面出现、用户点击之前就恢复完成。
    KeepAliveManager.getInstance().init(this.context as common.UIAbilityContext);
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
