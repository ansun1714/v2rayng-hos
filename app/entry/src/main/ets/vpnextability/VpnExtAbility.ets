import { hilog } from '@kit.PerformanceAnalysisKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { vpnExtension, VpnExtensionAbility, connection } from '@kit.NetworkKit';
import { NgCore } from '../core/NgCore';
import { FileStore } from '../core/FileStore';
import { DelayReq, DelayRes, DelayBody } from '../core/Model';

const DOMAIN: number = 0x0001;
const TAG: string = 'V2rayNG-VpnExt';

const TUN_IP: string = '172.19.0.1';
const TUN_DNS: string = '172.19.0.2';
const TUN_PREFIX: number = 30;
const TUN_MTU: number = 1400;

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * 对应 Android 版 v2rayNG 的 CoreVpnService：
 * 系统拉起扩展 -> 申请虚拟网卡拿 fd -> 把 fd 交给 Go 内核（mihomo）跑 gvisor 协议栈，
 * 并把内核每一条出站 socket 交给系统 protect（否则回环进 TUN）。
 */
export default class VpnExtAbility extends VpnExtensionAbility {
  private vpnConn: vpnExtension.VpnConnection | undefined = undefined;
  private statsTimer: number = -1;

  /** 并发测速：扫描 delay/req_*.json 并立刻交给内核（内核侧是 goroutine，可并发） */
  private delayTimer: number = -1;
  private started: boolean = false;
  private lastDelaySeq: number = -1;

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'VpnExtAbility onCreate');
    FileStore.appendLog(this.context.filesDir, 'extension onCreate');
    this.startCore(want);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'VpnExtAbility onDestroy');
    const filesDir: string = this.context.filesDir;
    FileStore.appendLog(filesDir, 'extension onDestroy');
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
    if (this.delayTimer >= 0) {
      clearInterval(this.delayTimer);
      this.delayTimer = -1;
    }
    this.started = false;
    // 先落盘「已断开」：NgCore.stop 可能阻塞，绝不能让状态文件停在 running=true，
    // 否则界面会一直显示「已连接 / 停止代理」，点断开也无效。
    this.writeState(false, '已断开');
    const conn = this.vpnConn;
    this.vpnConn = undefined;
    // 内核退出与通道销毁移到下一轮事件循环，避免 onDestroy 被卡住、销毁流程走不完
    setTimeout(() => {
      try {
        NgCore.stop();
        FileStore.appendLog(filesDir, 'core stopped');
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'stop core failed: %{public}s', String(err));
        FileStore.appendLog(filesDir, 'core stop failed: ' + String(err));
      }
      if (conn !== undefined) {
        conn.destroy().then(() => {
          hilog.info(DOMAIN, TAG, 'vpn destroyed');
          FileStore.appendLog(filesDir, 'vpn destroyed');
        }).catch((err: Error) => {
          hilog.error(DOMAIN, TAG, 'vpn destroy failed: %{public}s', err.message);
          FileStore.appendLog(filesDir, 'vpn destroy failed: ' + err.message);
        });
      }
    }, 0);
  }

  private writeState(running: boolean, message: string): void {
    const filesDir: string = this.context.filesDir;
    FileStore.writeText(FileStore.statePath(filesDir),
      JSON.stringify({ running: running, message: message }));
  }

  private async startCore(want: Want): Promise<void> {
    const filesDir: string = this.context.filesDir;
    const configPath: string = FileStore.configPath(filesDir);
    const rawConfig: string = FileStore.readText(configPath);
    if (rawConfig.length === 0) {
      this.writeState(false, '内核配置为空，请先在界面选择节点');
      return;
    }

    const tunAddr: connection.NetAddress = { address: TUN_IP, family: 1, port: 0 };
    const zeroAddr: connection.NetAddress = { address: '0.0.0.0', family: 1, port: 0 };

    const vpnConfig: vpnExtension.VpnConfig = {
      addresses: [{ address: tunAddr, prefixLength: TUN_PREFIX }],
      routes: [{
        interface: 'tun0',
        destination: { address: zeroAddr, prefixLength: 0 },
        gateway: tunAddr,
        hasGateway: false,
        isDefaultRoute: true
      }],
      dnsAddresses: [TUN_DNS],
      mtu: TUN_MTU,
      isIPv4Accepted: true,
      isIPv6Accepted: false,
      isBlocking: false,
      isInternal: false
    };

    try {
      const conn: vpnExtension.VpnConnection = vpnExtension.createVpnConnection(this.context);
      this.vpnConn = conn;
      let fd: number = -1;
      try {
        fd = await conn.create(vpnConfig);
      } catch (createErr) {
        const be = createErr as BusinessError;
        const code: number = be.code !== undefined ? be.code : -1;
        hilog.error(DOMAIN, TAG, 'create err code=%{public}d msg=%{public}s', code, String(be.message));
        FileStore.appendLog(filesDir, 'create failed code=' + String(code) + ' msg=' + String(be.message));
        // 2203002：系统里已有 VPN（上一轮扩展还没拆干净）。销毁残留、等系统释放后重试
        try {
          await conn.destroy();
          FileStore.appendLog(filesDir, 'destroy stale conn');
        } catch (destroyErr) {
          const de = destroyErr as BusinessError;
          hilog.warn(DOMAIN, TAG, 'destroy before retry failed: %{public}s', String(de.message));
          FileStore.appendLog(filesDir, 'destroy stale conn failed: ' + String(de.message));
        }
        await delay(400);
        fd = await conn.create(vpnConfig);
        FileStore.appendLog(filesDir, 'create retried fd=' + String(fd));
      }
      hilog.info(DOMAIN, TAG, 'tun fd = %{public}d', fd);
      FileStore.appendLog(filesDir, 'tun fd=' + String(fd));
      hilog.info(DOMAIN, TAG, 'probe = %{public}s', NgCore.probeFd(fd));

      // 内核日志桥由 NAPI 在加载 libngcore.so 时自动挂上，日志标签 NG-CORE

      // 鸿蒙的 VpnConnection.protect() 只接受 @ohos.net.socket 创建的 socket fd，
      // Go 内核自己 open 的 socket 会被 netmanager 以 MANAGE_VPN 权限拒绝，
      // 因此改为把本进程（连同 Go 内核的 socket）绑定到底层真实网络，绕开 TUN 回环。
      await this.bindUnderlyingNetwork();
      // 绑定后的对照探针：用一个国内公共目标验证出站是否仍在回环
      hilog.info(DOMAIN, TAG, 'dial probe = %{public}s', NgCore.probeDial('223.5.5.5', 443, 5000));

      // 内核出站 socket 保护：Go 线程 -> NAPI -> ArkTS protect(fd) -> 回填结果
      NgCore.setProtectHandler((id: number, socketFd: number) => {
        conn.protect(socketFd).then(() => {
          hilog.debug(DOMAIN, TAG, 'protect ok fd = %{public}d', socketFd);
          NgCore.protectDone(id, true);
        }).catch((err: Error) => {
          hilog.warn(DOMAIN, TAG, 'protect fd %{public}d failed: %{public}s', socketFd, err.message);
          NgCore.protectDone(id, false);
        });
      });

      const config: string = rawConfig.replace('__TUN_FD__', String(fd));
      // 分流用的 geo 数据：从 rawfile 落到内核 home 目录（缺文件内核会尝试联网下载）
      const hasGeoIp: boolean = FileStore.ensureRawAsset(this.context.resourceManager,
        'geoip.dat', 'geoip.dat', filesDir);
      const hasGeoSite: boolean = FileStore.ensureRawAsset(this.context.resourceManager,
        'geosite.dat', 'geosite.dat', filesDir);
      hilog.info(DOMAIN, TAG, 'geo ready: geoip=%{public}s geosite=%{public}s',
        String(hasGeoIp), String(hasGeoSite));
      const error: string = NgCore.start(config, FileStore.ensureDir(filesDir));
      if (error.length > 0) {
        hilog.error(DOMAIN, TAG, 'core start failed: %{public}s', error);
        FileStore.appendLog(filesDir, 'core start failed: ' + error);
        this.writeState(false, '内核启动失败：' + error);
        return;
      }

      this.started = true;
      this.writeState(true, '已连接');
      FileStore.appendLog(filesDir, 'core started, state=running');
      this.startStatsLoop(filesDir);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'vpn create failed: %{public}s', String(err));
      this.writeState(false, '创建 VPN 失败：' + String(err));
    }
  }

  private async bindUnderlyingNetwork(): Promise<void> {
    try {
      const filesDir: string = this.context.filesDir;
      const nets: connection.NetHandle[] = await connection.getAllNets();
      let wifiNet: connection.NetHandle | undefined = undefined;
      let cellNet: connection.NetHandle | undefined = undefined;
      for (let i = 0; i < nets.length; i++) {
        const net: connection.NetHandle = nets[i];
        const caps: connection.NetCapabilities = await connection.getNetCapabilities(net);
        const bearers: connection.NetBearType[] = caps.bearerTypes;
        const isVpn: boolean = bearers !== undefined &&
          bearers.indexOf(connection.NetBearType.BEARER_VPN) >= 0;
        const capsArr: connection.NetCap[] = caps.networkCap !== undefined ? caps.networkCap : [];
        const hasInternet: boolean =
          capsArr.indexOf(connection.NetCap.NET_CAPABILITY_INTERNET) >= 0;
        if (isVpn || !hasInternet) {
          continue;
        }
        // 优先 WiFi：若绑到蜂窝，用户切到 WiFi 后内核仍走蜂窝，信号差时直接断流
        if (bearers.indexOf(connection.NetBearType.BEARER_WIFI) >= 0 && wifiNet === undefined) {
          wifiNet = net;
        } else if (bearers.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0 &&
          cellNet === undefined) {
          cellNet = net;
        }
      }
      const target: connection.NetHandle | undefined =
        wifiNet !== undefined ? wifiNet : cellNet;
      if (target === undefined) {
        hilog.warn(DOMAIN, TAG, 'no underlying net found, keep default');
        FileStore.appendLog(filesDir, 'no underlying net, keep default');
        return;
      }
      await connection.setAppNet(target);
      hilog.info(DOMAIN, TAG, 'app net bound to %{public}d (wifi/cellular)', target.netId);
      FileStore.appendLog(filesDir, 'app net bound to ' + String(target.netId));
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'bind underlying net failed: %{public}s', String(err));
      FileStore.appendLog(this.context.filesDir, 'bind net failed: ' + String(err));
    }
  }

  private startStatsLoop(filesDir: string): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
    }
    this.statsTimer = setInterval(() => {
      if (!this.started) {
        return;
      }
      let stats: string = '{}';
      try {
        stats = NgCore.stats();
      } catch (err) {
        stats = '{}';
      }
      // 把内核返回的 {"up":..,"down":..} 平铺进状态文件，界面按 state.up / state.down 读取
      let body: string = stats.trim();
      if (body.startsWith('{')) {
        body = body.substring(1);
      }
      if (body.endsWith('}')) {
        body = body.substring(0, body.length - 1);
      }
      FileStore.writeText(FileStore.statePath(filesDir),
        '{"running":true,"message":"已连接",' + body + '}');
      this.handleDelayRequest(filesDir);
    }, 2000);

    // 并发测速的取队列：界面按 seq 各写一个请求文件，这里高频扫描并全部提交
    if (this.delayTimer >= 0) {
      clearInterval(this.delayTimer);
    }
    this.delayTimer = setInterval(() => {
      if (!this.started) {
        return;
      }
      this.drainDelayQueue(filesDir);
    }, 300);
  }

  /**
   * 并发测速桥：UI 为每个节点写一份 delay/req_<seq>.json（互不覆盖），
   * 这里把目录里所有待处理请求一次性交给内核（proxyDelayAsync 是 goroutine，天然并发），
   * 提交后删掉请求文件，结果由内核写到 delay/res_<seq>.json。
   */
  private drainDelayQueue(filesDir: string): void {
    const reqs: string[] = FileStore.listDelayReqs(filesDir);
    if (reqs.length === 0) {
      return;
    }
    reqs.forEach((path: string) => {
      const text: string = FileStore.readText(path);
      if (text.length === 0) {
        return;
      }
      try {
        const req = JSON.parse(text) as DelayReq;
        if (req.seq === undefined || req.name === undefined) {
          return;
        }
        NgCore.proxyDelayAsync(req.name, req.url !== undefined ? req.url : '', 5000,
          FileStore.delayResFile(filesDir, req.seq), req.seq);
      } catch (err) {
      }
      FileStore.removeFile(path);
    });
  }

  /**
   * 测速桥：界面进程访问不到内核的 9090（两个进程不在同一网络命名空间），
   * 所以界面把请求写 delay_req.json，这里（内核所在进程）执行并写回 delay_res.json。
   */
  private handleDelayRequest(filesDir: string): void {
    const text: string = FileStore.readText(FileStore.delayReqPath(filesDir));
    if (text.length === 0) {
      return;
    }
    let req: DelayReq | null = null;
    try {
      req = JSON.parse(text) as DelayReq;
    } catch (err) {
      return;
    }
    if (req === null || req.seq === undefined || req.seq === this.lastDelaySeq) {
      return;
    }
    this.lastDelaySeq = req.seq;
    // 异步执行：测速期间内核要回调 JS 执行 protect，同步调用会把它堵死
    NgCore.proxyDelayAsync(req.name, req.url !== undefined ? req.url : '', 5000,
      FileStore.delayResPath(filesDir), req.seq);
    // 节点名可能带机房/地区信息，不写系统日志，只留序号
    hilog.info(DOMAIN, TAG, 'delay start seq=%{public}d', req.seq);
  }
}
