import { abilityAccessCtrl, common, PermissionRequestResult } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { window } from '@kit.ArkUI';
import { AudioEnv } from '../common/AudioEnv';
import { HeartRateMonitor } from '../common/HeartRateMonitor';
import { LoopbackController } from '../common/AudioLoopbackController';
import { MonitorStats, SoftwareEarMonitor } from '../common/SoftwareEarMonitor';

const ACCENT_TEXT: string = '#FFFFFF';
const WAVE_COLOR: string = '#2F7CF6';
const WAVE_AXIS: string = '#9A9AA0';

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 一条录音记录 */
class RecordItem {
  name: string;
  path: string;
  seconds: number;
  playing: boolean;

  constructor(name: string, path: string, seconds: number) {
    this.name = name;
    this.path = path;
    this.seconds = seconds;
    this.playing = false;
  }
}

@Entry
@Component
struct Index {
  @State modeIndex: number = 0;
  @State logs: string[] = [];

  @State hwSupported: boolean = false;
  @State hwStatus: string = '未开始';
  @State hwRunning: boolean = false;
  @State hwBusy: boolean = false;
  @State volume: number = 50;
  @State eqIndex: number = 1;

  @State swRunning: boolean = false;
  @State swBusy: boolean = false;

  @State noiseGate: boolean = true;
  @State noiseThreshold: number = 60;
  @State levelDb: number = -100;
  @State suppressing: boolean = false;
  @State suppressedFrames: number = 0;
  @State noiseModeText: string = '系统降噪待启动';

  /**
   * 波形历史点。
   * 用固定长度的环形缓冲：避免每帧 splice/slice 造成的内存抖动，
   * 否则运行越久越卡。
   */
  private waveRing: number[] = new Array<number>(Index.WAVE_HISTORY).fill(0);
  private waveCount: number = 0;
  private waveWrite: number = 0;

  /** 低时延监听页的心电波形（由心率广播的 bpm 合成） */
  private heartRing: number[] = new Array<number>(Index.HEART_HISTORY).fill(0);
  private heartCount: number = 0;
  private heartWrite: number = 0;
  private ecgPhase: number = 0;
  /** 待消费的波形点：用游标消费，不 shift */
  private pendingWave: number[] = [];
  private pendingHead: number = 0;
  private renderTimer: number = -1;
  private waveAccum: number = 0;
  private lastTickAt: number = 0;
  private static readonly WAVE_HISTORY: number = 80;
  private static readonly WAVE_POINTS_PER_SECOND: number = 80;
  private static readonly HEART_HISTORY: number = 240;
  private static readonly FRAME_INTERVAL: number = 8;

  @State recording: boolean = false;
  @State recordSeconds: number = 0;
  @State records: RecordItem[] = [];
  /** 播放进度（非 @State：120 fps 推进，走状态会整页重渲染） */
  private playProgress: number = 0;
  /** 播放时间文本，节流更新 */
  @State playTimeText: string = '00:00';

  @State inputText: string = '查询中';
  @State outputText: string = '查询中';
  @State permissionText: string = '未申请';
  /** 心率广播 */
  @State heartBpm: number = -1;
  @State heartDevice: string = '';
  @State heartScanning: boolean = false;

  /** 沉浸式布局下状态栏 / 导航条的安全区高度（vp），用于给内容让位 */
  @State topInset: number = 0;
  @State bottomInset: number = 0;

  private loopback: LoopbackController | undefined = undefined;
  private software: SoftwareEarMonitor | undefined = undefined;
  private recordTimer: number = -1;
  private player: media.AVPlayer | undefined = undefined;
  private playingPath: string = '';
  /** 当前播放录音的时长（秒）与缩略波形 */
  private playingSeconds: number = 0;
  private playWave: number[] = [];
  /** 播放计时：以本地时钟推进，timeUpdate 只用来校正漂移 */
  private playStartedAt: number = 0;
  private playBaseOffset: number = 0;
  private lastTextAt: number = 0;
  /** 本次录制是否走的「临时抢占麦克风」通道（低时延模式下） */
  private auxRecording: boolean = false;

  private canvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.canvasSettings);
  private hwCanvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private hwCanvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.hwCanvasSettings);

  private eqLabels: string[] = ['平直', '饱满', '明亮'];
  private eqPresets: audio.AudioLoopbackEqualizerPreset[] = [
    audio.AudioLoopbackEqualizerPreset.FLAT,
    audio.AudioLoopbackEqualizerPreset.FULL,
    audio.AudioLoopbackEqualizerPreset.BRIGHT
  ];

  aboutToAppear(): void {
    this.loopback = LoopbackController.shared();
    this.loopback.bind(
      (message: string) => this.addLog(message),
      (text: string, running: boolean) => {
        this.hwStatus = text;
        this.hwRunning = running;
      }
    );
    this.software = SoftwareEarMonitor.shared();
    this.software.bind(
      (message: string) => this.addLog(message),
      (stats: MonitorStats) => {
        this.levelDb = stats.levelDb;
        this.suppressing = stats.suppressing;
        this.suppressedFrames = stats.suppressedFrames;
        this.noiseModeText = stats.noiseModeText;
      },
      (points: number[]) => {
        for (let i = 0; i < points.length; i++) {
          this.pendingWave.push(points[i]);
        }
      }
    );
    this.software.setThreshold(this.noiseThreshold);

    this.hwSupported = LoopbackController.isSupported();
    this.addLog(`设备支持低时延监听：${this.hwSupported ? '是' : '否'}`);
    this.refreshDevices();
    this.refreshRecords();
    this.ensurePermission();
    this.updateSafeAreaInsets();
  }

  /**
   * 窗口用 setWindowLayoutFullScreen(true) 铺满后，页面内容会顶到状态栏和导航条底下，
   * 这里读出被系统栏占掉的区域高度，给根容器加 padding 让内容避开。
   */
  private async updateSafeAreaInsets(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const mainWindow: window.Window = await window.getLastWindow(context);
      const systemArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicatorArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.topInset = px2vp(systemArea.topRect.height);
      this.bottomInset = px2vp(indicatorArea.bottomRect.height);
    } catch (err) {
      const e = err as BusinessError;
      this.addLog(`读取安全区失败: code=${e.code}, message=${e.message}`);
    }
  }

  aboutToDisappear(): void {
    // 页面销毁：停掉音频并解绑回调，但保留实例（进程级单例），
    // 这样下次进入时能先把可能残留的通路关干净再重开。
    this.stopRecordTimer();
    this.stopRenderLoop();
    this.stopPlayback();
    if (this.loopback !== undefined) {
      this.loopback.stop();
      this.loopback.unbind();
    }
    if (this.software !== undefined) {
      this.software.shutdown();
      this.software.unbind();
    }
  }

  /**
   * 回到前台时把界面状态和真实音频状态对齐。
   *
   * 退到后台时 Ability 会主动停掉监听（系统的后台音频会被挂起，留着只会
   * 出现「显示运行中却没有声音」的假状态），这里回来重新读一次状态，
   * 该显示「就绪」就显示「就绪」，用户点开始即可正常出声。
   */
  onPageShow(): void {
    this.syncFromControllers();
  }

  private async syncFromControllers(): Promise<void> {
    if (this.loopback !== undefined) {
      if (!this.loopback.isCreated()) {
        this.hwStatus = '未开始';
        this.hwRunning = false;
      } else {
        this.hwRunning = await this.loopback.refresh();
      }
    }
    if (this.software !== undefined && !this.software.isRunning()) {
      this.swRunning = false;
      this.suppressing = false;
      this.levelDb = -100;
      this.stopRenderLoop();
      this.resetWave();
    }
    // 退到后台时录制会被收尾，这里同步一下界面
    if (this.software !== undefined && !this.software.isRecording() && this.recording) {
      this.recording = false;
      this.stopRecordTimer();
    }
  }

  private addLog(message: string): void {
    const now = new Date();
    const ts: string = `${pad2(now.getHours())}:${pad2(now.getMinutes())}:${pad2(now.getSeconds())}`;
    const next: string[] = [`${ts}  ${message}`];
    for (let i = 0; i < this.logs.length && i < 29; i++) {
      next.push(this.logs[i]);
    }
    this.logs = next;
  }

  private async ensurePermission(): Promise<void> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
      this.permissionText = granted ? '已授权' : '未授权';
      this.addLog(granted ? '麦克风权限已获取' : '麦克风权限被拒绝，无法采集声音');
    } catch (err) {
      const e = err as BusinessError;
      this.permissionText = '申请失败';
      this.addLog(`申请麦克风权限失败: code=${e.code}, message=${e.message}`);
    }
  }

  private async toggleHeartRateScan(): Promise<void> {
    const monitor: HeartRateMonitor = HeartRateMonitor.shared();
    if (this.heartScanning) {
      monitor.stop();
      this.heartScanning = false;
      this.addLog('已停止心率扫描');
      return;
    }
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result: PermissionRequestResult = await atManager.requestPermissionsFromUser(
        context, ['ohos.permission.ACCESS_BLUETOOTH', 'ohos.permission.APPROXIMATELY_LOCATION']);
      const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
      if (!granted) {
        this.addLog('蓝牙权限被拒绝，无法扫描心率');
        return;
      }
    } catch (err) {
      const e = err as BusinessError;
      this.addLog(`申请蓝牙权限失败: code=${e.code}`);
      return;
    }
    monitor.bindLog((message: string) => this.addLog(message));
    const started: boolean = monitor.start(
      (bpm: number, deviceId: string) => {
        this.heartBpm = bpm;
        this.heartDevice = deviceId;
      },
      (message: string) => {
        this.addLog(`心率扫描错误: ${message}`);
      }
    );
    this.heartScanning = started;
    this.addLog(started ? '开始扫描心率，稍后自动连接设备' : '心率扫描启动失败，请确认蓝牙已开启');
  }

  private heartText(): string {
    if (this.heartBpm > 0) {
      return `${this.heartBpm} bpm`;
    }
    return this.heartScanning ? '扫描中…' : '未扫描';
  }

  private async refreshDevices(): Promise<void> {
    const inputs: string[] = await AudioEnv.listDevices(audio.DeviceFlag.INPUT_DEVICES_FLAG);
    const outputs: string[] = await AudioEnv.listDevices(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
    this.inputText = AudioEnv.joinNames(inputs);
    this.outputText = AudioEnv.joinNames(outputs);
  }

  private async toggleHardware(): Promise<void> {
    if (this.hwBusy || this.loopback === undefined) {
      return;
    }
    this.hwBusy = true;
    if (this.hwRunning) {
      await this.loopback.stop();
      if (!this.swRunning && !this.recording) {
        this.stopRenderLoop();
      }
      this.resetWave();
    } else {
      await this.loopback.start();
      await this.loopback.setVolume(this.volume / 100);
      if (this.hwRunning) {
        // 低时延监听页要画心率心电图，同样需要渲染循环
        this.startRenderLoop();
      }
    }
    await this.refreshDevices();
    this.hwBusy = false;
  }

  /**
   * 低时延链路由系统直连，应用拿不到 PCM；而额外开一路采集会和它抢麦克风，
   * 实测约 6 秒后系统就会把低时延通路关掉。所以这里不做常驻旁路采集，
   * 只在录制时临时占用麦克风。
   */
  private async startAuxCapture(): Promise<boolean> {
    if (this.software === undefined) {
      return false;
    }
    const ok: boolean = await this.software.start(true);
    if (ok) {
      this.startRenderLoop();
      return true;
    }
    this.addLog('旁路采集启动失败，本次无法录制');
    return false;
  }

  private async stopAuxCapture(): Promise<void> {
    if (this.software !== undefined && this.software.isRunning()) {
      await this.software.stop();
      this.stopRenderLoop();
      this.resetWave();
    }
  }

  private applyVolume(value: number): void {
    if (this.loopback === undefined) {
      return;
    }
    this.loopback.setVolume(value / 100);
  }

  private applyEqualizer(index: number): void {
    if (this.loopback === undefined) {
      return;
    }
    this.loopback.setEqualizer(this.eqPresets[index], this.eqLabels[index]);
  }

  private async toggleSoftware(): Promise<void> {
    if (this.swBusy || this.software === undefined) {
      return;
    }
    this.swBusy = true;
    if (this.swRunning) {
      await this.software.stop();
      this.swRunning = false;
      this.suppressing = false;
      this.levelDb = -100;
      this.stopRenderLoop();
      this.resetWave();
    } else {
      const started: boolean = await this.software.start();
      this.swRunning = started;
      if (started) {
        this.startRenderLoop();
      }
    }
    await this.refreshDevices();
    this.swBusy = false;
  }

  private async toggleRecording(): Promise<void> {
    if (this.software === undefined) {
      return;
    }
    if (!this.swRunning && !this.hwRunning) {
      this.addLog('请先开始监听，再录制');
      return;
    }
    if (this.recording) {
      const path: string = await this.software.stopRecording();
      this.recording = false;
      this.stopRecordTimer();
      if (path.length > 0) {
        this.refreshRecords();
      }
      // 低时延模式下录制结束：释放麦克风并把监听接回去
      if (this.auxRecording) {
        this.auxRecording = false;
        await this.stopAuxCapture();
        if (this.loopback !== undefined) {
          await this.loopback.start();
          await this.loopback.setVolume(this.volume / 100);
          this.addLog('录制结束，已恢复低时延监听');
        }
        await this.refreshDevices();
      }
      return;
    }

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const dir: string = `${context.filesDir}/records`;

    // 低时延模式下录制要临时抢麦克风，先停掉低时延通路
    if (!this.swRunning && this.hwRunning) {
      if (this.loopback !== undefined) {
        await this.loopback.stop();
        this.addLog('录制需要占用麦克风，已暂停低时延监听');
      }
      const ok: boolean = await this.startAuxCapture();
      if (!ok) {
        return;
      }
      this.auxRecording = true;
    }

    const path: string = await this.software.startRecording(dir);
    if (path.length > 0) {
      this.recording = true;
      this.recordSeconds = 0;
      this.startRecordTimer();
    } else if (this.auxRecording) {
      this.auxRecording = false;
      await this.stopAuxCapture();
    }
  }

  private recordDir(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/records`;
  }

  /** 扫描录音目录，按文件名（时间戳）倒序 */
  private refreshRecords(): void {
    const dir: string = this.recordDir();
    const items: RecordItem[] = [];
    try {
      if (!fs.accessSync(dir)) {
        this.records = items;
        return;
      }
      const files: string[] = fs.listFileSync(dir);
      for (let i = 0; i < files.length; i++) {
        const name: string = files[i];
        if (!name.endsWith('.wav')) {
          continue;
        }
        const path: string = `${dir}/${name}`;
        let seconds: number = 0;
        try {
          const stat = fs.statSync(path);
          // 去掉 44 字节头，按 48 kHz / 16 bit / 单声道换算
          seconds = Math.max(0, Math.round((stat.size - 44) / 96000));
        } catch (err) {
          seconds = 0;
        }
        items.push(new RecordItem(name, path, seconds));
      }
    } catch (err) {
      const e = err as BusinessError;
      this.addLog(`读取录音目录失败: code=${e.code}`);
    }
    items.sort((a: RecordItem, b: RecordItem) => a.name < b.name ? 1 : -1);
    this.records = items;
  }

  private markPlaying(path: string): void {
    const next: RecordItem[] = [];
    for (let i = 0; i < this.records.length; i++) {
      const old: RecordItem = this.records[i];
      const item: RecordItem = new RecordItem(old.name, old.path, old.seconds);
      item.playing = old.path === path;
      next.push(item);
    }
    this.records = next;
  }

  private async stopPlayback(): Promise<void> {
    const current = this.player;
    this.player = undefined;
    this.playingPath = '';
    this.playingSeconds = 0;
    this.playWave = [];
    this.playProgress = 0;
    this.playTimeText = '00:00';
    this.markPlaying('');
    // 没有监听/录制在跑时，把渲染循环也停掉
    if (!this.swRunning && !this.hwRunning && !this.recording) {
      this.stopRenderLoop();
    }
    this.drawWave();
    if (current !== undefined) {
      try {
        await current.stop();
      } catch (err) {
        // 已经停了就忽略
      }
      try {
        await current.release();
      } catch (err) {
        // 已经释放就忽略
      }
    }
  }

  private async togglePlayback(item: RecordItem): Promise<void> {
    if (this.playingPath === item.path) {
      await this.stopPlayback();
      return;
    }
    await this.stopPlayback();
    try {
      const file = fs.openSync(item.path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(item.path);
      const avPlayer: media.AVPlayer = await media.createAVPlayer();
      avPlayer.on('stateChange', (state: string) => {
        if (state === 'initialized') {
          avPlayer.prepare();
        } else if (state === 'prepared') {
          avPlayer.play();
        } else if (state === 'completed') {
          this.stopPlayback();
        }
      });
      avPlayer.on('timeUpdate', (time: number) => {
        // 用真实播放时间校正本地时钟，避免长时间播放累积漂移
        if (this.playingSeconds > 0) {
          this.playBaseOffset = time / 1000;
          this.playStartedAt = Date.now();
        }
      });
      avPlayer.on('error', (err: BusinessError) => {
        this.addLog(`播放失败: code=${err.code}, message=${err.message}`);
        this.stopPlayback();
      });
      avPlayer.fdSrc = { fd: file.fd, offset: 0, length: stat.size };
      this.player = avPlayer;
      this.playingPath = item.path;
      this.playingSeconds = item.seconds;
      this.playWave = this.loadWaveSidecar(item.path);
      this.playProgress = 0;
      this.playTimeText = '00:00';
      this.playStartedAt = Date.now();
      this.playBaseOffset = 0;
      this.lastTextAt = 0;
      this.startRenderLoop();
      this.markPlaying(item.path);
      this.drawWave();
      this.addLog(`播放 ${item.name}`);
    } catch (err) {
      const e = err as BusinessError;
      this.addLog(`播放失败: code=${e.code}, message=${e.message}`);
    }
  }

  /** 读取录制时存下的缩略波形，降采样到 240 根柱子 */
  private loadWaveSidecar(wavPath: string): number[] {
    const bars: number[] = [];
    try {
      const wavePath: string = `${wavPath}.wave`;
      if (!fs.accessSync(wavePath)) {
        return bars;
      }
      const content: string = fs.readTextSync(wavePath);
      const raw: number[] = JSON.parse(content) as number[];
      const step: number = Math.max(1, Math.floor(raw.length / 240));
      for (let i = 0; i < raw.length; i += step) {
        let peak: number = 0;
        const end: number = Math.min(i + step, raw.length);
        for (let j = i; j < end; j++) {
          if (raw[j] > peak) {
            peak = raw[j];
          }
        }
        bars.push(peak);
      }
    } catch (err) {
      // 没有 sidecar 就只显示空波形
    }
    return bars;
  }

  private seekTo(ratio: number): void {
    if (this.player !== undefined && this.playingSeconds > 0) {
      this.player.seek(Math.round(ratio * this.playingSeconds * 1000));
      this.playBaseOffset = ratio * this.playingSeconds;
      this.playStartedAt = Date.now();
      this.playProgress = ratio;
      this.playTimeText = this.formatTime(ratio * this.playingSeconds);
      this.drawWave();
    }
  }

  private formatTime(totalSeconds: number): string {
    const m: number = Math.floor(totalSeconds / 60);
    const s: number = Math.floor(totalSeconds % 60);
    return `${pad2(m)}:${pad2(s)}`;
  }

  private deleteRecord(item: RecordItem): void {
    try {
      if (this.playingPath === item.path) {
        this.stopPlayback();
      }
      fs.unlinkSync(item.path);
      try {
        fs.unlinkSync(`${item.path}.wave`);
      } catch (err) {
        // 没有 sidecar 就忽略
      }
      const next: RecordItem[] = [];
      for (let i = 0; i < this.records.length; i++) {
        if (this.records[i].path !== item.path) {
          next.push(this.records[i]);
        }
      }
      this.records = next;
      this.addLog(`已删除 ${item.name}`);
    } catch (err) {
      const e = err as BusinessError;
      this.addLog(`删除失败: code=${e.code}, message=${e.message}`);
    }
  }

  private startRecordTimer(): void {
    this.stopRecordTimer();
    this.recordTimer = setInterval(() => {
      this.recordSeconds += 1;
    }, 1000);
  }

  private stopRecordTimer(): void {
    if (this.recordTimer >= 0) {
      clearInterval(this.recordTimer);
      this.recordTimer = -1;
    }
  }

  private recordTimeText(): string {
    const m: number = Math.floor(this.recordSeconds / 60);
    const s: number = this.recordSeconds % 60;
    return `${pad2(m)}:${pad2(s)}`;
  }

  // ---------------------------------------------------------------------
  // 波形绘制：心电图式滚动折线，新点从右侧进入、旧点向左滚出
  // ---------------------------------------------------------------------
  private startRenderLoop(): void {
    this.stopRenderLoop();
    this.lastTickAt = Date.now();
    this.waveAccum = 0;
    // 8 ms ≈ 120 fps：监听和播放共用这一个节拍
    this.renderTimer = setInterval(() => {
      const now: number = Date.now();
      const dt: number = now - this.lastTickAt;
      this.lastTickAt = now;
      this.tickWave(dt);
      this.tickHeartWave(dt);
      this.tickPlayback();
      this.drawWave();
    }, Index.FRAME_INTERVAL);
  }

  private stopRenderLoop(): void {
    if (this.renderTimer >= 0) {
      clearInterval(this.renderTimer);
      this.renderTimer = -1;
    }
  }

  /** 播放进度按本地时钟推进，保证 120 fps 平滑；timeUpdate 只用来校正 */
  private tickPlayback(): void {
    if (this.player === undefined || this.playingSeconds <= 0) {
      return;
    }
    const elapsed: number = (Date.now() - this.playStartedAt) / 1000;
    this.playProgress = Math.min(1, (this.playBaseOffset + elapsed) / this.playingSeconds);
    const now: number = Date.now();
    if (now - this.lastTextAt > 250) {
      this.lastTextAt = now;
      this.playTimeText = this.formatTime(this.playProgress * this.playingSeconds);
    }
    if (this.playProgress >= 1) {
      this.stopPlayback();
    }
  }

  /** 按真实时间差推进波形，掉帧时也不会忽快忽慢 */
  private tickWave(dtMs: number): void {
    this.waveAccum += Index.WAVE_POINTS_PER_SECOND * dtMs / 1000;
    let take: number = Math.floor(this.waveAccum);
    this.waveAccum -= take;
    while (take > 0 && this.pendingHead < this.pendingWave.length) {
      const value: number = this.pendingWave[this.pendingHead];
      this.pendingHead++;
      this.waveRing[this.waveWrite] = value;
      this.waveWrite = (this.waveWrite + 1) % Index.WAVE_HISTORY;
      if (this.waveCount < Index.WAVE_HISTORY) {
        this.waveCount++;
      }
      take--;
    }
    // 游标太长时整体压缩一次，避免数组无限增长
    if (this.pendingHead > 512) {
      this.pendingWave = this.pendingWave.slice(this.pendingHead);
      this.pendingHead = 0;
    }
  }

  private resetWave(): void {
    this.waveRing.fill(0);
    this.waveCount = 0;
    this.waveWrite = 0;
    this.pendingWave = [];
    this.pendingHead = 0;
    this.waveAccum = 0;
    this.heartRing.fill(0);
    this.heartCount = 0;
    this.heartWrite = 0;
    this.ecgPhase = 0;
    this.drawWave();
  }

  /**
   * 心率广播只给 bpm，没有原始 ECG 信号，这里按 bpm 的节拍合成一个 PQRST 波形。
   */
  private tickHeartWave(dtMs: number): void {
    if (!this.hwRunning || this.heartBpm <= 0) {
      return;
    }
    const periodMs: number = 60000 / this.heartBpm;
    this.ecgPhase += dtMs / periodMs;
    while (this.ecgPhase >= 1) {
      this.ecgPhase -= 1;
    }
    const value: number = Index.ecgValue(this.ecgPhase);
    this.heartRing[this.heartWrite] = value;
    this.heartWrite = (this.heartWrite + 1) % Index.HEART_HISTORY;
    if (this.heartCount < Index.HEART_HISTORY) {
      this.heartCount++;
    }
  }

  /** 归一化相位 [0,1) → ECG 幅值（P/Q/R/S/T 五个高斯峰叠加） */
  private static ecgValue(t: number): number {
    const g = (x: number, mu: number, sigma: number): number => {
      const d: number = x - mu;
      return Math.exp(-(d * d) / (2 * sigma * sigma));
    };
    let y: number = 0;
    y += 0.12 * g(t, 0.18, 0.025);   // P
    y -= 0.15 * g(t, 0.30, 0.010);   // Q
    y += 1.00 * g(t, 0.33, 0.010);   // R
    y -= 0.28 * g(t, 0.36, 0.010);   // S
    y += 0.28 * g(t, 0.55, 0.040);   // T
    // 压缩到 0~1，和 PCM 波形的幅度口径一致
    return Math.max(0, Math.min(1, (y + 0.3) / 1.3));
  }

  private drawWave(): void {
    if (this.modeIndex === 0) {
      this.drawHeartWave();
      return;
    }
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);

    const mid: number = h / 2;
    const amplitude: number = h / 2 - 6;

    // 心电图纸式的横向网格
    ctx.strokeStyle = WAVE_AXIS;
    ctx.lineWidth = 1;
    ctx.globalAlpha = 0.16;
    for (let g = 1; g <= 2; g++) {
      const y: number = (h / 3) * g;
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(w, y);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    // 播放态：画录音的波形，而不是实时波形
    if (this.playingPath.length > 0 && this.playWave.length > 0) {
      this.drawPlaybackWave(ctx, w, h, mid, amplitude);
      return;
    }

    const count: number = this.waveCount;
    const active: boolean = this.hwRunning || this.swRunning || this.recording;
    if (!active || count < 2) {
      return;
    }

    // 数据右对齐：越新的点越靠右；环形缓冲按写入顺序还原
    const stepX: number = w / (Index.WAVE_HISTORY - 1);
    const startX: number = w - (count - 1) * stepX;
    const ringStart: number = (this.waveWrite - count + Index.WAVE_HISTORY) % Index.WAVE_HISTORY;

    // 纯色单线，不分段、不画竖线
    ctx.beginPath();
    for (let i = 0; i < count; i++) {
      const value: number = this.waveRing[(ringStart + i) % Index.WAVE_HISTORY];
      const x: number = startX + i * stepX;
      const y: number = mid - value * amplitude;
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.strokeStyle = WAVE_COLOR;
    ctx.lineWidth = 2;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.stroke();
  }

  /** 播放录音：纯色波形 + 一条进度竖线（进度是功能，保留） */
  /** 低时延监听页：画由心率合成的心电波形 */
  private drawHeartWave(): void {
    const ctx: CanvasRenderingContext2D = this.hwCanvasCtx;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);

    const mid: number = h / 2;
    const amplitude: number = h / 2 - 6;

    ctx.strokeStyle = WAVE_AXIS;
    ctx.lineWidth = 1;
    ctx.globalAlpha = 0.16;
    for (let g = 1; g <= 2; g++) {
      const y: number = (h / 3) * g;
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(w, y);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    const count: number = this.heartCount;
    if (!this.hwRunning || this.heartBpm <= 0 || count < 2) {
      return;
    }

    const stepX: number = w / (Index.HEART_HISTORY - 1);
    const startX: number = w - (count - 1) * stepX;
    const ringStart: number = (this.heartWrite - count + Index.HEART_HISTORY) % Index.HEART_HISTORY;

    ctx.beginPath();
    for (let i = 0; i < count; i++) {
      const value: number = this.heartRing[(ringStart + i) % Index.HEART_HISTORY];
      const x: number = startX + i * stepX;
      const y: number = mid - (value - 0.5) * 2 * amplitude;
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.strokeStyle = WAVE_COLOR;
    ctx.lineWidth = 2;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.stroke();
  }

  private drawPlaybackWave(ctx: CanvasRenderingContext2D, w: number, h: number,
    mid: number, amplitude: number): void {
    const data: number[] = this.playWave;
    const count: number = data.length;
    if (count < 2) {
      return;
    }
    const stepX: number = w / (count - 1);

    ctx.beginPath();
    for (let i = 0; i < count; i++) {
      const x: number = i * stepX;
      const y: number = mid - data[i] * amplitude;
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.strokeStyle = WAVE_COLOR;
    ctx.lineWidth = 2;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.stroke();

    // 进度竖线
    const playedX: number = w * this.playProgress;
    ctx.strokeStyle = WAVE_COLOR;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(playedX, 2);
    ctx.lineTo(playedX, h - 2);
    ctx.stroke();
  }

  private statusColor(): Resource {
    if (this.hwRunning) {
      return $r('app.color.ok');
    }
    return this.hwSupported ? $r('app.color.warn') : $r('app.color.bad');
  }

  private levelText(): string {
    if (!this.swRunning && !this.hwRunning) {
      return '--';
    }
    return `${Math.round(this.levelDb)} dB`;
  }

  @Builder
  tabButton(label: string, index: number) {
    Button(label)
      .layoutWeight(1)
      .height(34)
      .fontSize(13)
      .backgroundColor(this.modeIndex === index ? $r('app.color.accent') : $r('app.color.chip'))
      .fontColor(this.modeIndex === index ? ACCENT_TEXT : $r('app.color.text_sub'))
      .onClick(() => {
        this.modeIndex = index;
      })
  }

  @Builder
  labelText(text: string) {
    Text(text).fontSize(12).fontColor($r('app.color.text_sub')).width('100%')
  }

  /** 波形 + 录制控制；低时延通路拿不到 PCM，那边不画波形 */
  @Builder
  waveAndRecordBlock(active: boolean, showWave: boolean) {
    if (showWave) {
      Column({ space: 8 }) {
        Row() {
          Text('波形')
            .fontSize(13)
            .fontColor($r('app.color.text_main'))
          Blank()
          Text(this.modeIndex === 0
            ? (this.heartBpm > 0 ? `心率 ${this.heartBpm} bpm` : '等待心率')
            : (active ? `峰值 ${this.levelText()}` : '待启动'))
            .fontSize(11)
            .fontColor($r('app.color.text_sub'))
        }
        .width('100%')

        Canvas(this.modeIndex === 0 ? this.hwCanvasCtx : this.canvasCtx)
          .width('100%')
          .height(80)
          .backgroundColor($r('app.color.chip'))
          .borderRadius(10)
          .onTouch((event: TouchEvent) => {
            // 播放时，波形本身就是进度条：点按 / 拖动即可跳转
            if (this.playingPath.length === 0 || this.playWave.length === 0) {
              return;
            }
            if (event.type === TouchType.Down || event.type === TouchType.Move) {
              const touch: TouchObject = event.touches[0];
              const width: number = this.canvasCtx.width;
              if (width > 0) {
                this.seekTo(Math.max(0, Math.min(1, touch.x / width)));
              }
            }
          })
          .onReady(() => {
            this.drawWave();
          })
      }
      .width('100%')
    }

    Row() {
      Column({ space: 2 }) {
        Text('录制').fontSize(13).fontColor($r('app.color.text_main'))
        Text(this.recording ? `录制中 ${this.recordTimeText()}` : '保存为 WAV（48 kHz / 16 bit / 单声道）')
          .fontSize(11)
          .fontColor(this.recording ? $r('app.color.bad') : $r('app.color.text_sub'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button(this.recording ? '停止' : '录制')
        .height(30)
        .fontSize(12)
        .padding({ left: 16, right: 16 })
        .backgroundColor(this.recording ? $r('app.color.bad') : $r('app.color.chip'))
        .fontColor(this.recording ? ACCENT_TEXT : $r('app.color.text_main'))
        .onClick(() => {
          this.toggleRecording();
        })
    }
    .width('100%')
  }

  @Builder
  recordList() {
    if (this.records.length > 0) {
      Column({ space: 6 }) {
        this.labelText('录音列表')
        ForEach(this.records, (item: RecordItem) => {
          Column({ space: 4 }) {
            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text(item.name)
                  .fontSize(11)
                  .fontColor($r('app.color.text_main'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.formatTime(item.seconds))
                  .fontSize(10)
                  .fontColor($r('app.color.text_sub'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Button(item.playing ? '停止' : '播放')
                .height(26)
                .fontSize(11)
                .padding({ left: 10, right: 10 })
                .backgroundColor($r('app.color.chip'))
                .fontColor($r('app.color.text_main'))
                .onClick(() => {
                  this.togglePlayback(item);
                })

              Button('删除')
                .height(26)
                .fontSize(11)
                .padding({ left: 10, right: 10 })
                .backgroundColor($r('app.color.chip'))
                .fontColor($r('app.color.bad'))
                .onClick(() => {
                  this.deleteRecord(item);
                })
            }
            .width('100%')

            if (item.playing) {
              Row() {
                Text(`${this.playTimeText} / ${this.formatTime(item.seconds)}`)
                  .fontSize(10)
                  .fontColor($r('app.color.text_sub'))
                Blank()
                Text('点按或拖动上方波形可跳转')
                  .fontSize(10)
                  .fontColor($r('app.color.text_sub'))
              }
              .width('100%')
            }
          }
          .width('100%')
        }, (item: RecordItem) => item.path)
      }
      .width('100%')
    }
  }

  @Builder
  hardwareCard() {
    Column({ space: 14 }) {
      Row() {
        Text('低时延监听 · AudioLoopback')
          .fontSize(16)
          .fontColor($r('app.color.text_main'))
          .fontWeight(FontWeight.Medium)
        Blank()
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .backgroundColor(this.statusColor())
      }
      .width('100%')

      Text(this.hwStatus)
        .fontSize(12)
        .fontColor($r('app.color.text_sub'))
        .width('100%')

      Button(this.hwRunning ? '停止监听' : '开始监听')
        .width('100%')
        .height(44)
        .fontSize(15)
        .backgroundColor(this.hwRunning ? $r('app.color.chip') : $r('app.color.accent'))
        .fontColor(this.hwRunning ? $r('app.color.text_main') : ACCENT_TEXT)
        .enabled(!this.hwBusy)
        .onClick(() => {
          this.toggleHardware();
        })

      Row({ space: 12 }) {
        Text('监听音量').fontSize(13).fontColor($r('app.color.text_sub'))
        Slider({ value: this.volume, min: 0, max: 100, step: 1, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .selectedColor($r('app.color.accent'))
          .onChange((value: number, mode: SliderChangeMode) => {
            this.volume = value;
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.applyVolume(value);
            }
          })
        Text(`${Math.round(this.volume)}`)
          .fontSize(13)
          .fontColor($r('app.color.text_main'))
          .width(32)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      Column({ space: 8 }) {
        this.labelText('均衡器（API 21+）')
        Row({ space: 8 }) {
          ForEach(this.eqLabels, (label: string, index: number) => {
            Button(label)
              .fontSize(12)
              .height(30)
              .padding({ left: 12, right: 12 })
              .backgroundColor(this.eqIndex === index ? $r('app.color.accent') : $r('app.color.chip'))
              .fontColor(this.eqIndex === index ? ACCENT_TEXT : $r('app.color.text_sub'))
              .onClick(() => {
                this.eqIndex = index;
                this.applyEqualizer(index);
              })
          }, (label: string) => label)
        }
        .width('100%')
      }
      .width('100%')

      this.waveAndRecordBlock(this.hwRunning, true)

      Text('低时延链路的声音由系统直连，应用拿不到这段 PCM，所以这里不显示波形；录制时会临时占用麦克风，录完自动恢复监听。')
        .fontSize(11)
        .fontColor($r('app.color.text_sub'))
        .width('100%')

      Text('提示：低时延通道依赖设备能力，目前仅支持有线耳机；未接耳机时会显示「不可用」。')
        .fontSize(11)
        .fontColor($r('app.color.text_sub'))
        .width('100%')

      this.recordList()
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.card'))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  softwareCard() {
    Column({ space: 14 }) {
      Row() {
        Text('实时监听 · Capturer + Renderer')
          .fontSize(16)
          .fontColor($r('app.color.text_main'))
          .fontWeight(FontWeight.Medium)
        Blank()
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .backgroundColor(this.swRunning ? $r('app.color.ok') : $r('app.color.chip'))
      }
      .width('100%')

      Text('用 AudioCapturer 采集、AudioRenderer 播放，在应用层串一条「麦克风 → 耳机」的通路，波形、降噪、录制都挂在这条通路上。')
        .fontSize(12)
        .fontColor($r('app.color.text_sub'))
        .width('100%')

      Button(this.swRunning ? '停止监听' : '开始监听')
        .width('100%')
        .height(44)
        .fontSize(15)
        .backgroundColor(this.swRunning ? $r('app.color.chip') : $r('app.color.accent'))
        .fontColor(this.swRunning ? $r('app.color.text_main') : ACCENT_TEXT)
        .enabled(!this.swBusy)
        .onClick(() => {
          this.toggleSoftware();
        })

      this.waveAndRecordBlock(this.swRunning, true)

      Text('参数：48 kHz / 单声道 / S16LE，环形缓冲 100 ms')
        .fontSize(11)
        .fontColor($r('app.color.text_sub'))
        .width('100%')

      Divider().color($r('app.color.divider')).strokeWidth(0.5)

      Row() {
        Column({ space: 2 }) {
          Text('噪声抑制').fontSize(13).fontColor($r('app.color.text_main'))
          Text(this.noiseModeText).fontSize(11).fontColor($r('app.color.text_sub'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.noiseGate })
          .selectedColor($r('app.color.accent'))
          .onChange((isOn: boolean) => {
            this.noiseGate = isOn;
            if (this.software !== undefined) {
              this.software.setNoiseGate(isOn);
            }
          })
      }
      .width('100%')

      Row({ space: 12 }) {
        Text('阈值').fontSize(13).fontColor($r('app.color.text_sub'))
        Slider({ value: this.noiseThreshold, min: 40, max: 90, step: 1, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .selectedColor($r('app.color.accent'))
          .enabled(this.noiseGate)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.noiseThreshold = value;
            if (this.software !== undefined) {
              this.software.setThreshold(value);
            }
          })
        Text(`${Math.round(this.noiseThreshold)} dB`)
          .fontSize(13)
          .fontColor($r('app.color.text_main'))
          .width(52)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      Row({ space: 8 }) {
        Text(`当前电平 ${this.levelText()}`)
          .fontSize(11)
          .fontColor($r('app.color.text_sub'))
        Text(this.suppressing ? '超阈值 · 已抑制' : '正常')
          .fontSize(11)
          .fontColor(this.suppressing ? $r('app.color.bad') : $r('app.color.ok'))
        Blank()
        Text(`累计抑制 ${this.suppressedFrames} 帧`)
          .fontSize(11)
          .fontColor($r('app.color.text_sub'))
      }
      .width('100%')

      Divider().color($r('app.color.divider')).strokeWidth(0.5)

      this.recordList()
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.card'))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  envCard() {
    Column({ space: 8 }) {
      Text('运行环境').fontSize(14).fontColor($r('app.color.text_main')).fontWeight(FontWeight.Medium).width('100%')

      Row() {
        Text('输入设备').fontSize(12).fontColor($r('app.color.text_sub')).width(80)
        Text(this.inputText).fontSize(12).fontColor($r('app.color.text_main')).layoutWeight(1).maxLines(2)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row() {
        Text('输出设备').fontSize(12).fontColor($r('app.color.text_sub')).width(80)
        Text(this.outputText).fontSize(12).fontColor($r('app.color.text_main')).layoutWeight(1).maxLines(2)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row() {
        Text('麦克风权限').fontSize(12).fontColor($r('app.color.text_sub')).width(80)
        Text(this.permissionText).fontSize(12).fontColor($r('app.color.text_main')).layoutWeight(1).maxLines(2)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row() {
        Text('低时延监听').fontSize(12).fontColor($r('app.color.text_sub')).width(80)
        Text(this.hwSupported ? '支持（API 20+）' : '不支持')
          .fontSize(12)
          .fontColor($r('app.color.text_main'))
          .layoutWeight(1)
          .maxLines(2)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row() {
        Text('心率（广播）').fontSize(12).fontColor($r('app.color.text_sub')).width(80)
        Text(this.heartText())
          .fontSize(12)
          .fontColor(this.heartBpm > 0 ? $r('app.color.ok') : $r('app.color.text_main'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row({ space: 8 }) {
        Button('刷新环境')
          .height(30)
          .fontSize(12)
          .backgroundColor($r('app.color.chip'))
          .fontColor($r('app.color.text_sub'))
          .onClick(() => {
            this.hwSupported = LoopbackController.isSupported();
            this.refreshDevices();
          })

        Button(this.heartScanning ? '停止心率' : '扫描心率')
          .height(30)
          .fontSize(12)
          .backgroundColor($r('app.color.chip'))
          .fontColor(this.heartScanning ? $r('app.color.bad') : $r('app.color.text_sub'))
          .onClick(() => {
            this.toggleHeartRateScan();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.card'))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  logCard() {
    Column({ space: 8 }) {
      Row() {
        Text('日志').fontSize(14).fontColor($r('app.color.text_main')).fontWeight(FontWeight.Medium)
        Blank()
        Button('清空')
          .height(26)
          .fontSize(11)
          .backgroundColor($r('app.color.chip'))
          .fontColor($r('app.color.text_sub'))
          .onClick(() => {
            this.logs = [];
          })
      }
      .width('100%')

      if (this.logs.length === 0) {
        Text('暂无日志').fontSize(11).fontColor($r('app.color.text_sub')).width('100%')
      } else {
        Column({ space: 4 }) {
          ForEach(this.logs, (item: string, index: number) => {
            Text(item)
              .fontSize(11)
              .fontColor($r('app.color.text_sub'))
              .width('100%')
          }, (item: string, index: number) => `${index}-${item}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.card'))
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Column({ space: 4 }) {
        Text('聆心')
          .fontSize(26)
          .fontColor($r('app.color.text_main'))
          .fontWeight(FontWeight.Bold)
        Text('实时监听 · 低时延 / 降噪 / 录制')
          .fontSize(12)
          .fontColor($r('app.color.text_sub'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 16, bottom: 12 })

      Row({ space: 8 }) {
        this.tabButton('低时延监听', 0)
        this.tabButton('实时监听', 1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })

      Scroll() {
        Column({ space: 12 }) {
          if (this.modeIndex === 0) {
            this.hardwareCard()
          } else {
            this.softwareCard()
          }
          this.envCard()
          this.logCard()
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 12 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
    .padding({ top: this.topInset })
  }
}
