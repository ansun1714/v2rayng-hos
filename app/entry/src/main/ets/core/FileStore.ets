/**
 * 配置与状态文件读写：节点列表、内核配置、运行状态。
 */
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { Profile, RuleItem } from './Model';

/** state.json 中由 UI 进程维护的用户意图标记（旧版本文件里没有，按 false 处理）。 */
interface StateFlag {
  userStopped?: boolean;
}

export class FileStore {
  static dir(filesDir: string): string {
    return filesDir + '/v2rayng';
  }

  static ensureDir(filesDir: string): string {
    const dir: string = FileStore.dir(filesDir);
    try {
      fileIo.mkdirSync(dir, true);
    } catch (err) {
    }
    return dir;
  }

  static readText(path: string): string {
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(path);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer));
    } catch (err) {
      return '';
    }
  }

  static writeText(path: string, text: string): void {
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
    } catch (err) {
    }
  }

  /** 运行日志路径。日志只落本机沙盒，界面可以一键清除。 */
  static logPath(filesDir: string): string {
    return FileStore.ensureDir(filesDir) + '/vpn.log';
  }

  /**
   * 追加一行运行日志（vpn.log）。界面进程与扩展进程都会写同一个文件，
   * 这里用「读旧 + 截断 + 重写」的方式，并保留最近 240 行，避免越写越大。
   */
  static appendLog(filesDir: string, line: string): void {
    try {
      const path: string = FileStore.logPath(filesDir);
      const old: string = FileStore.readText(path);
      let lines: string[] = old.length > 0 ? old.split('\n') : [];
      const now: Date = new Date();
      const hh: string = String(now.getHours()).padStart(2, '0');
      const mm: string = String(now.getMinutes()).padStart(2, '0');
      const ss: string = String(now.getSeconds()).padStart(2, '0');
      lines.push(hh + ':' + mm + ':' + ss + ' ' + line);
      if (lines.length > 240) {
        lines = lines.slice(lines.length - 240);
      }
      FileStore.writeText(path, lines.join('\n'));
    } catch (err) {
    }
  }

  static profilesPath(filesDir: string): string {
    return FileStore.ensureDir(filesDir) + '/profiles.json';
  }

  static configPath(filesDir: string): string {
    return FileStore.ensureDir(filesDir) + '/core.yaml';
  }

  static statePath(filesDir: string): string {
    return FileStore.ensureDir(filesDir) + '/state.json';
  }

  /**
   * 读用户「主动停止代理」标记。字段缺失 / 文件不存在 / 解析失败一律按 false，
   * 兼容旧版本 state.json（只有 running/message/up/down 等字段）。
   */
  static readUserStopped(filesDir: string): boolean {
    const text: string = FileStore.readText(FileStore.statePath(filesDir));
    if (text.length === 0) {
      return false;
    }
    try {
      const state: StateFlag = JSON.parse(text) as StateFlag;
      return state.userStopped === true;
    } catch (err) {
      return false;
    }
  }

  /** 供各写状态处拼接的 userStopped 片段，避免覆盖写把它抹掉。 */
  static userStoppedField(filesDir: string): string {
    return ',"userStopped":' + String(FileStore.readUserStopped(filesDir));
  }

  /**
   * 读-改-写更新 state.json 的 userStopped，保留其余字段。
   * 只在用户点击连接/断开时低频调用，不进任何高频定时器；
   * 用字符串替换而非反序列化重建，避免丢掉内核写入的统计字段。
   */
  static writeUserStopped(filesDir: string, value: boolean): void {
    const path: string = FileStore.statePath(filesDir);
    let text: string = FileStore.readText(path);
    if (text.length === 0) {
      text = '{"running":false,"message":"未连接"}';
    }
    let cleaned: string = text;
    const trueKey: string = ',"userStopped":true';
    const falseKey: string = ',"userStopped":false';
    if (cleaned.indexOf(trueKey) >= 0) {
      cleaned = cleaned.replace(trueKey, '');
    } else if (cleaned.indexOf(falseKey) >= 0) {
      cleaned = cleaned.replace(falseKey, '');
    }
    let body: string = cleaned.trim();
    if (body.endsWith('}')) {
      body = body.substring(0, body.length - 1);
      FileStore.writeText(path, body + ',"userStopped":' + String(value) + '}');
    }
  }

  /** 测速请求：界面进程写，VPN 扩展进程（内核所在进程）读。 */
  static delayReqPath(filesDir: string): string {
    return FileStore.ensureDir(filesDir) + '/delay_req.json';
  }

  /** 测速结果：VPN 扩展进程写，界面进程读。 */
  static delayResPath(filesDir: string): string {
    return FileStore.ensureDir(filesDir) + '/delay_res.json';
  }

  /**
   * 并发测速用的请求/结果文件：每个 seq 一对（req_<seq>.json / res_<seq>.json），
   * 放在 delay/ 子目录，避免并发时互相覆盖。
   */
  static delayDir(filesDir: string): string {
    const dir: string = FileStore.ensureDir(filesDir) + '/delay';
    try {
      fileIo.mkdirSync(dir, true);
    } catch (err) {
    }
    return dir;
  }

  static delayReqFile(filesDir: string, seq: number): string {
    return FileStore.delayDir(filesDir) + '/req_' + String(seq) + '.json';
  }

  static delayResFile(filesDir: string, seq: number): string {
    return FileStore.delayDir(filesDir) + '/res_' + String(seq) + '.json';
  }

  /** 列出 delay 目录下所有未处理的测速请求（按文件名）。 */
  static listDelayReqs(filesDir: string): string[] {
    const dir: string = FileStore.delayDir(filesDir);
    const out: string[] = [];
    try {
      const names: string[] = fileIo.listFileSync(dir, { recursion: false });
      names.forEach((name: string) => {
        if (name.startsWith('req_') && name.endsWith('.json')) {
          out.push(dir + '/' + name);
        }
      });
    } catch (err) {
    }
    return out;
  }

  static removeFile(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (err) {
    }
  }

  static loadProfiles(filesDir: string): Profile[] {
    const text: string = FileStore.readText(FileStore.profilesPath(filesDir));
    if (text.length === 0) {
      return [];
    }
    try {
      return JSON.parse(text) as Profile[];
    } catch (err) {
      return [];
    }
  }

  static saveProfiles(filesDir: string, profiles: Profile[]): void {
    FileStore.writeText(FileStore.profilesPath(filesDir), JSON.stringify(profiles));
  }

  /** 分流规则：用户可手动改、从文件导入、从网址订阅覆盖。 */
  static rulesPath(filesDir: string): string {
    return FileStore.ensureDir(filesDir) + '/rules.json';
  }

  static loadRules(filesDir: string): RuleItem[] {
    const text: string = FileStore.readText(FileStore.rulesPath(filesDir));
    if (text.length === 0) {
      return [];
    }
    try {
      return JSON.parse(text) as RuleItem[];
    } catch (err) {
      return [];
    }
  }

  static saveRules(filesDir: string, rules: RuleItem[]): void {
    FileStore.writeText(FileStore.rulesPath(filesDir), JSON.stringify(rules));
  }

  static readText2(filesDir: string, name: string): string {
    return FileStore.readText(FileStore.ensureDir(filesDir) + '/' + name);
  }

  static writeText2(filesDir: string, name: string, text: string): void {
    FileStore.writeText(FileStore.ensureDir(filesDir) + '/' + name, text);
  }

  /**
   * 把打包在 rawfile 里的资源（geoip.dat / geosite.dat）落到内核 home 目录。
   * 已存在且大小一致时跳过，避免每次启动都拷十几 MB。
   */
  static ensureRawAsset(rm: resourceManager.ResourceManager, assetName: string,
    targetName: string, filesDir: string): boolean {
    const target: string = FileStore.ensureDir(filesDir) + '/' + targetName;
    try {
      const raw: Uint8Array = rm.getRawFileContentSync(assetName);
      const existing = fileIo.statSync(target);
      if (existing.size === raw.length) {
        return true;
      }
    } catch (err) {
      // 不存在或读取失败，继续走拷贝
    }
    try {
      const raw: Uint8Array = rm.getRawFileContentSync(assetName);
      const file = fileIo.openSync(target,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, raw.buffer as ArrayBuffer);
      fileIo.closeSync(file);
      return true;
    } catch (err) {
      return false;
    }
  }
}
