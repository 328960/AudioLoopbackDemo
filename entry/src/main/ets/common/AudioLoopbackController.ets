import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 低时延监听（AudioLoopback）封装。
 *
 * 对应 API：audio.createAudioLoopback / AudioLoopback（API 20 起支持）。
 * 系统内部用「低时延采集器 + 低时延渲染器」直连，采集到的音频不经应用层，
 * 直接送到耳机，所以这条通路上插不进应用自己的降噪处理。
 */
export class LoopbackController {
  /**
   * 进程级单例。
   *
   * AudioLoopback 实例由系统持有，页面重建时如果重新 create 一个，
   * 旧的实例可能还占着低时延通路，导致新实例 enable 成功却没有声音。
   * 复用同一个实例，start() 里就能先把它关干净再打开。
   */
  private static instance: LoopbackController | undefined = undefined;

  private loopback: audio.AudioLoopback | undefined = undefined;
  private statusCallback: ((status: audio.AudioLoopbackStatus) => void) | undefined = undefined;
  private log: (message: string) => void = () => {};
  private onStatus: (text: string, running: boolean) => void = () => {};

  private constructor() {
  }

  static shared(): LoopbackController {
    if (LoopbackController.instance === undefined) {
      LoopbackController.instance = new LoopbackController();
    }
    return LoopbackController.instance;
  }

  /** 页面每次出现时把回调重新绑到当前页面 */
  bind(log: (message: string) => void, onStatus: (text: string, running: boolean) => void): void {
    this.log = log;
    this.onStatus = onStatus;
  }

  /** 实例是否已创建（用于回到前台时同步界面状态） */
  isCreated(): boolean {
    return this.loopback !== undefined;
  }

  /** 页面销毁时解绑，避免回调写已销毁的组件 */
  unbind(): void {
    this.log = () => {};
    this.onStatus = () => {};
  }

  /** 当前设备/外设是否支持低时延监听（只查能力，不会创建实例） */
  static isSupported(): boolean {
    try {
      const manager: audio.AudioManager = audio.getAudioManager();
      return manager.getStreamManager().isAudioLoopbackSupported(audio.AudioLoopbackMode.HARDWARE);
    } catch (err) {
      const e = err as BusinessError;
      return false;
    }
  }

  /** 状态枚举转成可读文案 */
  static statusText(status: audio.AudioLoopbackStatus): string {
    if (status === audio.AudioLoopbackStatus.UNAVAILABLE_DEVICE) {
      return '不可用：输入/输出设备不支持低时延（需接有线耳机）';
    }
    if (status === audio.AudioLoopbackStatus.UNAVAILABLE_SCENE) {
      return '不可用：音频焦点或低时延管控受限';
    }
    if (status === audio.AudioLoopbackStatus.AVAILABLE_IDLE) {
      return '就绪（空闲）';
    }
    if (status === audio.AudioLoopbackStatus.AVAILABLE_RUNNING) {
      return '运行中';
    }
    return '未知状态';
  }

  private static isRunningStatus(status: audio.AudioLoopbackStatus): boolean {
    return status === audio.AudioLoopbackStatus.AVAILABLE_RUNNING;
  }

  /** 创建实例（幂等） */
  async create(): Promise<boolean> {
    if (this.loopback !== undefined) {
      return true;
    }
    if (!LoopbackController.isSupported()) {
      this.log('当前设备不支持低时延监听');
      this.onStatus('不支持：需要有线耳机', false);
      return false;
    }
    try {
      this.loopback = await audio.createAudioLoopback(audio.AudioLoopbackMode.HARDWARE);
      this.log('AudioLoopback 实例创建成功');
      return true;
    } catch (err) {
      const e = err as BusinessError;
      this.log(`创建 AudioLoopback 失败: code=${e.code}, message=${e.message}`);
      this.loopback = undefined;
      return false;
    }
  }

  /** 刷新一次状态，返回是否处于运行中 */
  async refresh(): Promise<boolean> {
    const lb = this.loopback;
    if (lb === undefined) {
      return false;
    }
    try {
      const status: audio.AudioLoopbackStatus = await lb.getStatus();
      const running: boolean = LoopbackController.isRunningStatus(status);
      this.onStatus(LoopbackController.statusText(status), running);
      return running;
    } catch (err) {
      const e = err as BusinessError;
      this.log(`获取状态失败: code=${e.code}, message=${e.message}`);
      return false;
    }
  }

  /** 开启监听 */
  async start(): Promise<boolean> {
    const created: boolean = await this.create();
    if (!created) {
      return false;
    }
    const lb = this.loopback;
    if (lb === undefined) {
      return false;
    }
    try {
      const status: audio.AudioLoopbackStatus = await lb.getStatus();
      if (status === audio.AudioLoopbackStatus.UNAVAILABLE_DEVICE ||
        status === audio.AudioLoopbackStatus.UNAVAILABLE_SCENE) {
        this.onStatus(LoopbackController.statusText(status), false);
        this.log(`无法启用监听：${LoopbackController.statusText(status)}`);
        return false;
      }

      // 上一次的实例可能还挂在系统里（比如应用被切到后台后回到前台）。
      // 这种「假运行」状态下直接 enable(true) 会返回成功但没有声音，必须先关掉再重开。
      if (status === audio.AudioLoopbackStatus.AVAILABLE_RUNNING) {
        this.log('检测到上一次监听仍在运行，先关闭再重新启用');
        await lb.enable(false);
      }

      if (this.statusCallback === undefined) {
        const callback: (status: audio.AudioLoopbackStatus) => void = (s: audio.AudioLoopbackStatus) => {
          const running: boolean = LoopbackController.isRunningStatus(s);
          this.onStatus(LoopbackController.statusText(s), running);
          this.log(`状态变化：${LoopbackController.statusText(s)}`);
        };
        this.statusCallback = callback;
        lb.on('statusChange', callback);
      }

      let success: boolean = await lb.enable(true);
      if (!success) {
        // 旧实例释放是异步的，偶发竞争时等一小会儿再试一次
        this.log('enable(true) 首次失败，300ms 后重试');
        await LoopbackController.delay(300);
        success = await lb.enable(true);
      }
      if (success) {
        this.log('已启用低时延监听');
        await this.refresh();
      } else {
        this.log('enable(true) 返回 false，监听未启动');
        await this.refresh();
      }
      return success;
    } catch (err) {
      const e = err as BusinessError;
      this.log(`启用监听失败: code=${e.code}, message=${e.message}`);
      return false;
    }
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 关闭监听 */
  async stop(): Promise<void> {
    const lb = this.loopback;
    if (lb === undefined) {
      return;
    }
    try {
      const success: boolean = await lb.enable(false);
      this.log(success ? '已关闭低时延监听' : 'enable(false) 返回 false');
      if (success && this.statusCallback !== undefined) {
        lb.off('statusChange', this.statusCallback);
        this.statusCallback = undefined;
      }
      await this.refresh();
    } catch (err) {
      const e = err as BusinessError;
      this.log(`关闭监听失败: code=${e.code}, message=${e.message}`);
    }
  }

  /** 监听音量，取值 [0.0, 1.0] */
  async setVolume(volume: number): Promise<void> {
    const lb = this.loopback;
    if (lb === undefined) {
      return;
    }
    try {
      await lb.setVolume(volume);
      this.log(`监听音量已设置为 ${volume.toFixed(2)}`);
    } catch (err) {
      const e = err as BusinessError;
      this.log(`设置音量失败: code=${e.code}, message=${e.message}`);
    }
  }

  /** 均衡器模式（API 21+） */
  setEqualizer(preset: audio.AudioLoopbackEqualizerPreset, label: string): void {
    const lb = this.loopback;
    if (lb === undefined) {
      this.log('请先开始监听，再设置均衡器');
      return;
    }
    try {
      const ok: boolean = lb.setEqualizerPreset(preset);
      this.log(ok ? `均衡器：${label}` : `设置均衡器失败：${label}`);
    } catch (err) {
      const e = err as BusinessError;
      this.log(`设置均衡器异常: code=${e.code}, message=${e.message}`);
    }
  }

  /** 释放资源 */
  async release(): Promise<void> {
    await this.stop();
    this.loopback = undefined;
  }
}
