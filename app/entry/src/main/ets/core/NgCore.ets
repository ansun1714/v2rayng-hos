/**
 * 内核库调用封装：libngnapi.so -> dlopen libngcore.so（Go 交叉编译产物）
 */
import ngnapi from 'libngnapi.so';

export class NgCore {
  static start(configYaml: string, homeDir: string): string {
    return ngnapi.start(configYaml, homeDir);
  }

  static stop(): void {
    ngnapi.stop();
  }

  static isRunning(): boolean {
    return ngnapi.isRunning();
  }

  static stats(): string {
    return ngnapi.stats();
  }

  /** 进程内测速：内核真实经该节点请求一次 url，返回 {"delay":N} 或 {"error":"..."}。 */
  static proxyDelay(name: string, url: string, timeoutMs: number): string {
    return ngnapi.proxyDelay(name, url, timeoutMs);
  }

  /** 异步测速：立即返回，结果（含 seq）由内核写进 resPath，避免占住 JS 线程卡住 protect 回调。 */
  static proxyDelayAsync(name: string, url: string, timeoutMs: number, resPath: string, seq: number): void {
    ngnapi.proxyDelayAsync(name, url, timeoutMs, resPath, seq);
  }

  static version(): string {
    return ngnapi.version();
  }

  /**
   * 注册出站 socket 保护回调。鸿蒙上 VPN 进程自己发出的连接也会被 TUN 拦截，
   * 必须对每个 fd 调 VpnConnection.protect，否则流量回环、代理不可用。
   */
  static setProtectHandler(handler: (id: number, fd: number) => void): void {
    ngnapi.setProtectHandler(handler);
  }

  static protectDone(id: number, ok: boolean): void {
    ngnapi.protectDone(id, ok);
  }

  /**
   * 把 mihomo 内核日志接进 hilog（域标签 NG-CORE）。
   * 内核启动/监听失败默认只写内核日志，不开这个桥就完全看不到原因。
   */
  static enableCoreLog(): void {
    ngnapi.enableCoreLog();
  }

  /** 诊断：在扩展进程里探测 tun fd 的可用性（fstat / fcntl / TUNGETIFF） */
  static probeFd(fd: number): string {
    return ngnapi.probeFd(fd);
  }

  /** 诊断：裸 TCP 探测目标可达性，用于区分"出站回环"和"节点不可达" */
  static probeDial(host: string, port: number, timeoutMs: number): string {
    return ngnapi.probeDial(host, port, timeoutMs);
  }
}
