import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN: number = 0x0001;
const TAG: string = 'V2rayNG';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
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

  onForeground(): void {
  }

  onBackground(): void {
  }
}
