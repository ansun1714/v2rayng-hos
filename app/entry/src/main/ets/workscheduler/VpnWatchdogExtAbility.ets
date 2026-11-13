/**
 * 系统级看门狗（WorkSchedulerExtensionAbility）。
 *
 * 为什么需要：UI 进程被系统冻结时，页面里的 1s/3s 定时器与 recoverTimer 全部停摆，
 * 恢复逻辑（Index.verifyRunning / scheduleRecover）根本不会执行，于是扩展被 SIGKILL 后
 * 没有人兜底，表现为「state.json 说已连接，实际没有 :vpn」的静默假连接（真机 11-13
 * 23:23 之后挂机第二天才被发现）。本扩展由系统按周期唤起，运行在独立进程，
 * 不依赖 UI 是否被冻结。
 *
 * ⚠ 独立进程注意：
 * - KeepAliveManager 的静态单例在这里是另一个实例，不能用，也不 import Index；
 *   判定一律直接读 state.json 与 state.json 的 mtime（心跳）。
 * - 日志走 ui 通道（FileStore.setLogChannel('ui')），便于与 UI 侧时间线对齐取证。
 *
 * 判定条件与主链路保持一致（防误连）：userStopped === false 且
 *   (running === true  且 心跳超过 30s 未更新)   —— 扩展被硬杀，状态文件残留「已连接」
 *   (running === false 且 message === '已断开')  —— 扩展走了 onDestroy
 * 任一成立才尝试恢复；用户主动停止（userStopped === true）一律不动。
 */
import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection, vpnExtension } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FileStore } from '../core/FileStore';

const DOMAIN: number = 0x0001;
const TAG: string = 'VpnWatchdog';
const BUNDLE_NAME: string = 'com.maoxu.v2rayng';
const EXT_ABILITY: string = 'VpnExtAbility';
/** 与 KeepAliveManager.HEARTBEAT_STALE_MS 保持一致：扩展每 8s 重写一次 state.json */
const HEARTBEAT_STALE_MS: number = 30000;

/** 判定所需的 state.json 字段（其余统计字段忽略，兼容字段缺失）。 */
interface WatchdogState {
  running?: boolean;
  message?: string;
  userStopped?: boolean;
}

export default class VpnWatchdogExtAbility extends WorkSchedulerExtensionAbility {
  /** 系统按周期唤起：只做「判定 + 写日志 + 必要恢复」，不做任何 UI 操作。 */
  onWorkStart(work: workScheduler.WorkInfo): void {
    const filesDir: string = this.context.filesDir;
    // 看门狗是独立进程，日志切到 ui 通道，和 UI/扩展两侧时间线能对上
    FileStore.setLogChannel('ui');
    let running: boolean = false;
    let message: string = '';
    let userStopped: boolean = false;
    const text: string = FileStore.readText(FileStore.statePath(filesDir));
    if (text.length > 0) {
      try {
        const state: WatchdogState = JSON.parse(text) as WatchdogState;
        running = state.running === undefined ? false : state.running;
        message = state.message === undefined ? '' : state.message;
        userStopped = state.userStopped === undefined ? false : state.userStopped;
      } catch (err) {
        // 状态文件坏了不能静默：下一轮排查靠这一行
        FileStore.appendLog(filesDir, 'watchdog: state.json parse failed');
      }
    }
    const stale: boolean = running && this.heartbeatStale(filesDir);
    // 无论是否命中都必须留痕，次日取证靠这一行
    FileStore.appendLog(filesDir, 'watchdog: tick (running=' + String(running) +
      ', stale=' + String(stale) + ', userStopped=' + String(userStopped) + ')');
    if (userStopped) {
      return;
    }
    const abnormal: boolean = (running && stale) || (!running && message === '已断开');
    if (!abnormal) {
      return;
    }
    FileStore.appendLog(filesDir, 'watchdog: abnormal detected, restarting vpn extension');
    this.restartVpn(filesDir);
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    FileStore.setLogChannel('ui');
    FileStore.appendLog(this.context.filesDir,
      'watchdog: work stop, workId=' + String(work.workId));
  }

  /**
   * state.json 心跳是否过期。扩展的 statsTimer 每 8s 整文件重写一次 state.json，
   * 只要扩展活着 mtime 最多 8s 前进一次；被 SIGKILL 时 onDestroy 不执行，
   * state.json 会永久停在「已连接」。Stat.mtime 单位是**秒**，×1000 再比毫秒。
   * 读不到文件时按「已死」处理：宁可多拉起一次，也不要漏掉真故障。
   */
  private heartbeatStale(filesDir: string): boolean {
    try {
      const stat: fileIo.Stat = fileIo.statSync(FileStore.statePath(filesDir));
      const mtimeMs: number = stat.mtime * 1000;
      return Date.now() - mtimeMs > HEARTBEAT_STALE_MS;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'stat state.json failed: %{public}s', String(err));
      return true;
    }
  }

  /** 先确认系统里确实没有 VPN，再拉起扩展，避免把活着的连接再起一份。 */
  private restartVpn(filesDir: string): void {
    this.hasSystemVpn().then((alive: boolean): void => {
      if (alive) {
        FileStore.appendLog(filesDir, 'watchdog: system vpn alive, skip restart');
        return;
      }
      this.startVpn(filesDir);
    }).catch((err: Error) => {
      // 查不到网络列表不放弃：state.json 已判定异常，直接尝试拉起
      FileStore.appendLog(filesDir, 'watchdog: net query failed: ' + err.message);
      this.startVpn(filesDir);
    });
  }

  /**
   * 拉起 VPN 扩展。这里用模块级函数 vpnExtension.startVpnExtensionAbility(want)
   * （@ohos.net.vpnExtension.d.ts 中无 @permission 标注，非 Context 方法），
   * 因为 WorkSchedulerExtensionContext 只继承 ExtensionContext/Context，
   * **没有 startAbility**，无法拉起 EntryAbility（已核对 SDK，不编造）。
   * 能否在扩展进程内成功拉起必须真机验证：失败时把 code 原样写进日志。
   */
  private startVpn(filesDir: string): void {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: EXT_ABILITY
    };
    vpnExtension.startVpnExtensionAbility(want).then((): void => {
      FileStore.appendLog(filesDir, 'watchdog: restart vpn extension ok');
    }).catch((err: Error) => {
      const be: BusinessError = err as BusinessError;
      FileStore.appendLog(filesDir, 'watchdog: restart failed code=' +
        String(be.code !== undefined ? be.code : -1) + ' msg=' + String(err.message));
    });
  }

  /** 系统里是否已有 VPN 通道（getAllNets + getNetCapabilities + BEARER_VPN）。 */
  private async hasSystemVpn(): Promise<boolean> {
    const nets: connection.NetHandle[] = await connection.getAllNets();
    for (let i = 0; i < nets.length; i++) {
      const caps: connection.NetCapabilities = await connection.getNetCapabilities(nets[i]);
      const bearers: connection.NetBearType[] = caps.bearerTypes;
      if (bearers !== undefined && bearers.indexOf(connection.NetBearType.BEARER_VPN) >= 0) {
        return true;
      }
    }
    return false;
  }
}
