/**
 * 配置与状态文件读写：节点列表、内核配置、运行状态。
 */
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { Profile, RuleItem } from './Model';

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

  static profilesPath(filesDir: string): string {
    return FileStore.ensureDir(filesDir) + '/profiles.json';
  }

  static configPath(filesDir: string): string {
    return FileStore.ensureDir(filesDir) + '/core.yaml';
  }

  static statePath(filesDir: string): string {
    return FileStore.ensureDir(filesDir) + '/state.json';
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
