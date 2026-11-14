import { hilog } from '@kit.PerformanceAnalysisKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { vpnExtension, VpnExtensionAbility, connection } from '@kit.NetworkKit';
import { NgCore } from '../core/NgCore';
import { FileStore } from '../core/FileStore';
import { DelayReq, DelayRes, DelayBody, AppScope } from '../core/Model';

const DOMAIN: number = 0x0001;
const TAG: string = 'V2rayNG-VpnExt';

const TUN_IP: string = '172.19.0.1';
const TUN_DNS: string = '172.19.0.2';
const TUN_PREFIX: number = 30;
const TUN_MTU: number = 1400;

/** 底层网络变化后重绑去抖（毫秒）：合并 WiFi/蜂窝切换瞬间连发的多个事件 */
const REBIND_DELAY_MS: number = 400;
/** conn.protect() 连续失败多少次后降级：本版本对 Go 内核 socket 因 MANAGE_VPN
 * 权限必然失败，避免每条出站 socket 都做一次系统调用 + hilog 刷屏 */
const PROTECT_FAIL_THRESHOLD: number = 20;

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

  /** 底层网络绑定：binding 为可重入互斥；boundNetId 记录当前目标，实现幂等跳过 */
  private binding: boolean = false;
  private boundNetId: number = -1;
  /** 网络变化监听（NetConnection）与重绑去抖定时器 */
  private netConn: connection.NetConnection | undefined = undefined;
  private rebindTimer: number = -1;
  /** protect 连续失败计数与降级开关 */
  private protectFailStreak: number = 0;
  private protectDisabled: boolean = false;

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'VpnExtAbility onCreate');
    // 本进程（:vpn）的日志写 vpn.log；显式设置，避免将来同进程复用时串到 ui.log。
    FileStore.setLogChannel('vpn');
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
    // 先关掉重绑门禁，再停去抖定时器与监听，避免销毁流程里仍触发一次 setAppNet
    this.started = false;
    if (this.rebindTimer >= 0) {
      clearTimeout(this.rebindTimer);
      this.rebindTimer = -1;
    }
    this.unregisterNetObserver();
    this.binding = false;
    this.boundNetId = -1;
    this.protectDisabled = false;
    this.protectFailStreak = 0;
    // 长时任务由 UI 进程持有，本进程不释放（从扩展进程 stop 会作用到别人的任务上）
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
    // 带上 userStopped 字段，避免扩展进程覆盖写把用户「主动停止」意图抹掉
    FileStore.writeText(FileStore.statePath(filesDir),
      '{"running":' + String(running) + ',"message":' + JSON.stringify(message) +
      FileStore.userStoppedField(filesDir) + '}');
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

    // 实测结论（build29~33 四轮真机）：鸿蒙会把 v6 地址挂到 vpn-tun 上，
    // 但 VpnConfig 里的 v6 默认路由（::/0 或 ::/1+8000::/1，接口名 tun0/vpn-tun 都试过）
    // 一律不会被装进路由表，v6 数据报也不会投递到 tun fd。也就是说本版本无法接管 v6。
    // 既然接不住，就把 v6 一并关掉（见 ConfigBuilder 的 ipv6: false），
    // 让内核不给应用下发 AAAA，应用就不会主动产生绕过隧道的 v6 流量。
    const vpnConfig: vpnExtension.VpnConfig = {
      addresses: [
        { address: tunAddr, prefixLength: TUN_PREFIX }
      ],
      routes: [
        {
          interface: 'tun0',
          destination: { address: zeroAddr, prefixLength: 0 },
          gateway: tunAddr,
          hasGateway: false,
          isDefaultRoute: true
        }
      ],
      dnsAddresses: [TUN_DNS],
      mtu: TUN_MTU,
      isIPv4Accepted: true,
      isIPv6Accepted: false,
      isBlocking: false,
      isInternal: false
    };

    // 分应用代理（参考 v2rayH）：allow=只有白名单应用走隧道，block=黑名单应用直连。
    // 两者都不设时全部应用走隧道。包名列表为空时忽略，避免误把全部流量或零流量圈进来。
    try {
      const scope: AppScope = FileStore.loadAppScope(filesDir);
      if (scope.packages.length > 0 && scope.mode === 'allow') {
        vpnConfig.trustedApplications = scope.packages;
        FileStore.appendLog(filesDir, 'app scope: allow ' + String(scope.packages.length) + ' packages');
      } else if (scope.packages.length > 0 && scope.mode === 'block') {
        vpnConfig.blockedApplications = scope.packages;
        FileStore.appendLog(filesDir, 'app scope: block ' + String(scope.packages.length) + ' packages');
      }
    } catch (err) {
      FileStore.appendLog(filesDir, 'app scope load failed: ' + String(err));
    }

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

      // 内核出站 socket 保护：Go 线程 -> NAPI -> ArkTS protect(fd) -> 回填结果。
      // 本版本 protect() 对 Go 内核自建 socket 必因 MANAGE_VPN 权限失败，连续失败达阈值后
      // 降级：不再发起系统调用，直接回填 false，避免大流量时权限校验刷屏。
      NgCore.setProtectHandler((id: number, socketFd: number) => {
        // settled 由短路 / then / 链式 catch / 外层 catch 四条回填路径共用。
        // 先置位再回填：protectDone 自身抛错时会流转到链式 catch，若未置位就会
        // 对同一 id 二次回填；回填异常就地吞掉，整个 handler 不再向外抛，避免挂死内核。
        let settled: boolean = false;
        try {
          if (this.protectDisabled) {
            settled = true;
            NgCore.protectDone(id, false);
            return;
          }
          conn.protect(socketFd).then(() => {
            if (settled) {
              return;
            }
            settled = true;
            this.protectFailStreak = 0;
            hilog.debug(DOMAIN, TAG, 'protect ok fd = %{public}d', socketFd);
            try {
              NgCore.protectDone(id, true);
            } catch (doneErr) {
              hilog.error(DOMAIN, TAG, 'protectDone(true) threw: %{public}s', String(doneErr));
            }
          }).catch((err: Error) => {
            if (settled) {
              return; // then 已回填（含回填抛错流转），不二次回填、不重复计数
            }
            settled = true;
            hilog.warn(DOMAIN, TAG, 'protect fd %{public}d failed: %{public}s', socketFd, err.message);
            try {
              NgCore.protectDone(id, false);
            } catch (doneErr) {
              hilog.error(DOMAIN, TAG, 'protectDone(false) threw: %{public}s', String(doneErr));
            }
            this.protectFailStreak++;
            if (!this.protectDisabled && this.protectFailStreak >= PROTECT_FAIL_THRESHOLD) {
              this.protectDisabled = true;
              FileStore.appendLog(filesDir, 'protect disabled after ' +
                String(this.protectFailStreak) + ' failures');
            }
          });
        } catch (err) {
          // conn.protect() 同步抛异常等非 Promise 路径：兜底回填一次，
          // 否则 Go 侧拿不到结果会挂住回调，大流量下表现为断网。
          if (!settled) {
            settled = true;
            try {
              NgCore.protectDone(id, false);
            } catch (doneErr) {
              hilog.error(DOMAIN, TAG, 'protect fallback threw: %{public}s', String(doneErr));
            }
          }
          // 只打一条系统日志，不写 vpn.log（240 行环形缓冲），避免刷屏挤掉排障记录
          hilog.error(DOMAIN, TAG, 'protect handler threw id=%{public}d: %{public}s',
            id, String(err));
        }
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
      // 底层网络（WiFi/蜂窝）变化后需重新 setAppNet，否则出站 socket 回环进 TUN
      this.registerNetObserver();
      // 长时任务保活改在 UI 进程申请（从扩展进程调会报 401：context 类型不被接受）
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'vpn create failed: %{public}s', String(err));
      this.writeState(false, '创建 VPN 失败：' + String(err));
    }
  }

  /**
   * 长时任务保活不在这里做：本扩展进程的 context 不被后台任务接口接受，
   * 从这个进程调用 startBackgroundRunning 会报 401「context 类型不合法」。
   * 保活统一由 UI 进程的 KeepAliveManager 申请（那里是 UIAbilityContext）。
   */
  private async bindUnderlyingNetwork(): Promise<void> {
    // 可重入互斥：网络变化回调可能连发，避免并发 setAppNet 交错
    if (this.binding) {
      return;
    }
    this.binding = true;
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
      // 幂等：目标底层网络未变则跳过，避免每次网络事件都做一次无效 setAppNet
      if (target.netId === this.boundNetId) {
        return;
      }
      const isRebind: boolean = this.boundNetId >= 0;
      await connection.setAppNet(target);
      this.boundNetId = target.netId;
      if (isRebind) {
        hilog.info(DOMAIN, TAG, 'underlying net rebound to %{public}d', target.netId);
        FileStore.appendLog(filesDir, 'underlying net rebound to ' + String(target.netId));
      } else {
        hilog.info(DOMAIN, TAG, 'app net bound to %{public}d (wifi/cellular)', target.netId);
        FileStore.appendLog(filesDir, 'app net bound to ' + String(target.netId));
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'bind underlying net failed: %{public}s', String(err));
      FileStore.appendLog(this.context.filesDir, 'bind net failed: ' + String(err));
    } finally {
      this.binding = false;
    }
  }

  /**
   * 注册底层网络变化监听。SDK 15 的 @ohos.net.connection 没有命名空间级 on/off，
   * 事件走 createNetConnection() 得到的 NetConnection.on(type, cb) + register(cb)。
   * 真机 20:30/20:40/20:50 的 netCapabilitiesChange 会连发多个，统一去抖后重绑。
   */
  private registerNetObserver(): void {
    if (this.netConn !== undefined) {
      return;
    }
    const filesDir: string = this.context.filesDir;
    try {
      const netConn: connection.NetConnection = connection.createNetConnection();
      // 能力变化：只认底层网络，BEARER_VPN 是隧道自身，跳过避免误重绑
      netConn.on('netCapabilitiesChange', (info: connection.NetCapabilityInfo): void => {
        const bearers: connection.NetBearType[] = info.netCap.bearerTypes;
        if (bearers !== undefined &&
          bearers.indexOf(connection.NetBearType.BEARER_VPN) >= 0) {
          return;
        }
        this.scheduleRebind();
      });
      netConn.on('netAvailable', (): void => {
        this.scheduleRebind();
      });
      netConn.on('netLost', (): void => {
        this.scheduleRebind();
      });
      netConn.on('netUnavailable', (): void => {
        this.scheduleRebind();
      });
      // 先持有引用：即使 register 回调报错，onDestroy 也能注销，不留悬挂监听
      this.netConn = netConn;
      netConn.register((err: BusinessError): void => {
        if (err !== null && err !== undefined) {
          hilog.warn(DOMAIN, TAG, 'net observer register failed: %{public}s', String(err.message));
          FileStore.appendLog(filesDir, 'net observer register failed: ' + String(err.message));
        }
      });
      FileStore.appendLog(filesDir, 'net observer registered');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'net observer setup failed: %{public}s', String(err));
      FileStore.appendLog(filesDir, 'net observer setup failed: ' + String(err));
    }
  }

  /** 注销网络监听。SDK 15 的 NetConnection 无 off()，用 unregister() 一次性取消。 */
  private unregisterNetObserver(): void {
    const netConn: connection.NetConnection | undefined = this.netConn;
    this.netConn = undefined;
    if (netConn === undefined) {
      return;
    }
    try {
      netConn.unregister((err: BusinessError): void => {
        if (err !== null && err !== undefined) {
          hilog.warn(DOMAIN, TAG, 'net observer unregister failed: %{public}s',
            String(err.message));
        }
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'net observer unregister threw: %{public}s', String(err));
    }
  }

  /** 400ms 去抖后重绑底层网络；bindUnderlyingNetwork 自带互斥 + 幂等。 */
  private scheduleRebind(): void {
    if (!this.started) {
      return;
    }
    if (this.rebindTimer >= 0) {
      clearTimeout(this.rebindTimer);
      this.rebindTimer = -1;
    }
    this.rebindTimer = setTimeout((): void => {
      this.rebindTimer = -1;
      if (!this.started) {
        return;
      }
      this.bindUnderlyingNetwork().catch((err: Error): void => {
        hilog.error(DOMAIN, TAG, 'rebind underlying net failed: %{public}s', err.message);
        FileStore.appendLog(this.context.filesDir, 'rebind net failed: ' + err.message);
      });
    }, REBIND_DELAY_MS);
  }

  private startStatsLoop(filesDir: string): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
    }
    // 后台降载：状态文件写入由 2s 降到 8s。真机 hilog 里 MANAGE_VPN 权限校验
    // 失败每秒十几条刷屏，叠加高频定时器容易被系统判为「后台负载长时间高于
    // 该类型典型负载」而挂起/回收进程。状态文件字段与格式保持完全不变。
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
        '{"running":true,"message":"已连接",' + body +
        FileStore.userStoppedField(filesDir) + '}');
      // 纯前台测速桥由 2s 一并降到 8s：扩展进程没有前后台回调，
      // 后台时界面不写 delay_req.json，函数读到空内容会立即返回（等效跳过）。
      // 保留调用而不删除，避免破坏既有 delay req/res 测速文件协议。
      this.handleDelayRequest(filesDir);
    }, 8000);

    // 并发测速取队列由 300ms 降到 1.5s（空队列时 listDelayReqs 直接返回）。
    // 这是后台最高频的一项：原来每秒 3 次列目录，现在约每 1.5s 一次。
    if (this.delayTimer >= 0) {
      clearInterval(this.delayTimer);
    }
    this.delayTimer = setInterval(() => {
      if (!this.started) {
        return;
      }
      this.drainDelayQueue(filesDir);
    }, 1500);
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
