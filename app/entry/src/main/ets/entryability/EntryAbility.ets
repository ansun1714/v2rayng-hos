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
