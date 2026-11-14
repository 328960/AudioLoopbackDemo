import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const SAMPLE_RATE: number = 48000;
const CHANNEL_COUNT: number = 1;
const BYTES_PER_SAMPLE: number = 2;
/** 环形缓冲时长（秒）。越小延迟越低，越容易因抖动断音 */
const RING_SECONDS: number = 0.1;
/** 数字满量程对应的声压级近似值（dB SPL），用于把 dBFS 换算成可读声压级 */
const SPL_REFERENCE: number = 94;
/** 触发抑制后保留的增益，0.05 约等于 -26 dB */
const GATE_DAMP_GAIN: number = 0.05;
/** 增益平滑系数，避免硬切换产生咔哒声 */
const GATE_SMOOTH: number = 0.35;
/** 波形每秒的目标点数：点少一点，峰才清晰，不会糊成毛刺 */
const WAVE_POINTS_PER_SECOND: number = 80;
/** 波形回调间隔（帧）：1 = 每次采集回调都刷新 */
const WAVE_EVERY_FRAMES: number = 1;
/** 波形显示门限：电平低于 40 dB SPL 的段落直接画平（对应约 -54 dBFS） */
const WAVE_FLOOR_DB: number = 40;
/** WAVE_FLOOR_DB 换算成归一化后的阈值 */
const WAVE_FLOOR: number = (WAVE_FLOOR_DB - 34) / 60;
/** 录制落盘间隔（毫秒） */
const RECORD_FLUSH_MS: number = 500;

/** 供界面展示的降噪运行状态 */
export interface MonitorStats {
  levelDb: number;
  suppressing: boolean;
  suppressedFrames: number;
  noiseModeText: string;
}

/** 录制状态 */
export interface RecordState {
  recording: boolean;
  path: string;
  bytes: number;
}

export class SoftwareEarMonitor {
  /** 进程级单例：页面重建时复用，避免旧的采集器/播放器占着设备 */
  private static instance: SoftwareEarMonitor | undefined = undefined;

  private capturer: audio.AudioCapturer | undefined = undefined;
  private renderer: audio.AudioRenderer | undefined = undefined;
  private readDataCallback: ((buffer: ArrayBuffer) => void) | undefined = undefined;
  private writeDataCallback: ((buffer: ArrayBuffer) => audio.AudioDataCallbackResult) | undefined = undefined;

  private ring: Uint8Array = new Uint8Array(0);
  private writePos: number = 0;
  private readPos: number = 0;
  private filled: number = 0;

  /** 噪声门开关，默认开启 */
  private noiseGateEnabled: boolean = true;
  /** 抑制阈值（dB SPL），默认 60 */
  private thresholdDb: number = 60;
  private gain: number = 1;
  private suppressedFrames: number = 0;
  private frameCount: number = 0;
  private noiseModeText: string = '系统降噪不可用';

  /** 录制相关 */
  private recordFd: number = -1;
  private recordPath: string = '';
  private recordBytes: number = 0;
  private recordQueue: ArrayBuffer[] = [];
  private recordTimer: number = -1;
  private lastHeaderAt: number = 0;
  /** 录制期间的缩略波形，停止时写进 <文件名>.wave */
  private recordWave: number[] = [];

  private log: (message: string) => void = () => {};
  private onStats: ((stats: MonitorStats) => void) | undefined = undefined;
  private onWave: ((points: number[]) => void) | undefined = undefined;

  private constructor() {
  }

  static shared(): SoftwareEarMonitor {
    if (SoftwareEarMonitor.instance === undefined) {
      SoftwareEarMonitor.instance = new SoftwareEarMonitor();
    }
    return SoftwareEarMonitor.instance;
  }

  bind(log: (message: string) => void, onStats: (stats: MonitorStats) => void,
    onWave: (points: number[]) => void): void {
    this.log = log;
    this.onStats = onStats;
    this.onWave = onWave;
  }

  unbind(): void {
    this.log = () => {};
    this.onStats = undefined;
    this.onWave = undefined;
  }

  /** 采集器是否在跑（只采集模式下没有 renderer，也算在跑） */
  isRunning(): boolean {
    return this.capturer !== undefined;
  }

  isRecording(): boolean {
    return this.recordFd >= 0;
  }

  setNoiseGate(enabled: boolean): void {
    this.noiseGateEnabled = enabled;
    this.log(enabled ? '噪声抑制已开启' : '噪声抑制已关闭');
  }

  setThreshold(db: number): void {
    this.thresholdDb = db;
  }

  getThreshold(): number {
    return this.thresholdDb;
  }

  private push(buffer: ArrayBuffer): void {
    const view = new DataView(buffer);
    const sampleCount: number = Math.floor(buffer.byteLength / BYTES_PER_SAMPLE);
    if (sampleCount === 0) {
      return;
    }

    // 1) 电平 + 噪声门增益（放在采集回调里，这样「只采集不播放」也能算）
    let sumSquares: number = 0;
    for (let i = 0; i < sampleCount; i++) {
      const sample: number = view.getInt16(i * BYTES_PER_SAMPLE, true) / 32768;
      sumSquares += sample * sample;
    }
    const rms: number = Math.sqrt(sumSquares / sampleCount);
    const dbfs: number = rms > 0 ? 20 * Math.log10(rms) : -100;
    const levelDb: number = dbfs + SPL_REFERENCE;
    const suppressing: boolean = this.noiseGateEnabled && levelDb > this.thresholdDb;
    this.gain += ((suppressing ? GATE_DAMP_GAIN : 1) - this.gain) * GATE_SMOOTH;
    if (suppressing) {
      this.suppressedFrames++;
    }

    this.frameCount++;
    // 约每 25 帧（500 ms）回报一次电平，避免高频重渲染
    if (this.frameCount % 25 === 0 && this.onStats !== undefined) {
      this.onStats({
        levelDb: levelDb,
        suppressing: suppressing,
        suppressedFrames: this.suppressedFrames,
        noiseModeText: this.noiseModeText
      });
    }

    // 2) 波形：门限按整帧 RMS 电平判断，和界面显示的「当前电平」同一口径
    if (this.frameCount % WAVE_EVERY_FRAMES === 0 && this.onWave !== undefined) {
      this.onWave(this.computeWave(view, sampleCount, levelDb));
    }

    const src = new Uint8Array(buffer);

    // 3) 录制
    if (this.recordFd >= 0) {
      // 采集回调里的 buffer 会被系统复用，必须复制一份再排队落盘
      const copy = new ArrayBuffer(src.byteLength);
      new Uint8Array(copy).set(src);
      this.recordQueue.push(copy);
      // 顺带攒一份缩略波形，播放时可以还原录制时的样子（低于 40 dB 同样压平）
      if (this.frameCount % 2 === 0) {
        const level: number = Math.max(0, Math.min(1, (levelDb - 30) / 60));
        this.recordWave.push(levelDb < WAVE_FLOOR_DB ? 0 : level);
      }
    }

    // 4) 环形缓冲：只有需要播放时才填
    const size: number = this.ring.length;
    if (size === 0 || this.renderer === undefined) {
      return;
    }
    for (let i = 0; i < src.length; i++) {
      this.ring[this.writePos] = src[i];
      this.writePos = (this.writePos + 1) % size;
      if (this.filled < size) {
        this.filled++;
      } else {
        // 缓冲写满时丢弃最旧数据，保证延迟不会无限增长
        this.readPos = (this.readPos + 1) % size;
      }
    }
  }

  /** 从环形缓冲取数据，顺带做噪声门处理与波形统计 */
  private pop(buffer: ArrayBuffer): void {
    const size: number = this.ring.length;
    const dst = new Uint8Array(buffer);
    if (size === 0) {
      dst.fill(0);
      return;
    }
    for (let i = 0; i < dst.length; i++) {
      if (this.filled > 0) {
        dst[i] = this.ring[this.readPos];
        this.readPos = (this.readPos + 1) % size;
        this.filled--;
      } else {
        // 没有数据时补静音，避免爆音
        dst[i] = 0;
      }
    }
    this.applyNoiseGate(buffer);
  }

  private applyNoiseGate(buffer: ArrayBuffer): void {
    if (this.gain > 0.999) {
      return;
    }
    const view = new DataView(buffer);
    const sampleCount: number = Math.floor(buffer.byteLength / BYTES_PER_SAMPLE);
    for (let i = 0; i < sampleCount; i++) {
      const offset: number = i * BYTES_PER_SAMPLE;
      const sample: number = view.getInt16(offset, true);
      view.setInt16(offset, Math.round(sample * this.gain), true);
    }
  }

  /**
   * 每段只取绝对值最大的采样点（保留正负号），画出来就是一条上下摆动的单线。
   * levelDb 是整帧 RMS 电平：低于门限时整帧画平，和界面显示的口径一致。
   */
  private computeWave(view: DataView, sampleCount: number, levelDb: number): number[] {
    const points: number[] = [];
    const frameSeconds: number = sampleCount / SAMPLE_RATE;
    const pointCount: number = Math.max(2,
      Math.min(32, Math.round(WAVE_POINTS_PER_SECOND * frameSeconds)));

    if (levelDb < WAVE_FLOOR_DB) {
      for (let i = 0; i < pointCount; i++) {
        points.push(0);
      }
      return points;
    }

    const segment: number = Math.max(1, Math.floor(sampleCount / pointCount));
    for (let b = 0; b < pointCount; b++) {
      const start: number = b * segment;
      const end: number = Math.min(start + segment, sampleCount);
      let peak: number = 0;
      for (let i = start; i < end; i++) {
        const value: number = view.getInt16(i * BYTES_PER_SAMPLE, true) / 32768;
        if (Math.abs(value) > Math.abs(peak)) {
          peak = value;
        }
      }
      const normalized: number = SoftwareEarMonitor.normalizeDb(Math.abs(peak));
      points.push(peak >= 0 ? normalized : -normalized);
    }
    return points;
  }

  /** 线性幅度转 dB 并归一化到 0~1，-60 dBFS 以下算 0 */
  private static normalizeDb(value: number): number {
    const db: number = 20 * Math.log10(Math.abs(value) + 1e-6);
    return Math.max(0, Math.min(1, (db + 60) / 60));
  }

  // ---------------------------------------------------------------------
  // 录制：把采集到的 PCM 先攒在内存里，定时批量落盘，避免阻塞音频回调
  // ---------------------------------------------------------------------

  async startRecording(dirPath: string): Promise<string> {
    if (this.recordFd >= 0) {
      return this.recordPath;
    }
    try {
      if (!fs.accessSync(dirPath)) {
        fs.mkdirSync(dirPath, true);
      }
      const stamp: string = `${Date.now()}`;
      this.recordPath = `${dirPath}/monitor-${stamp}.wav`;
      const file = fs.openSync(this.recordPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      this.recordFd = file.fd;
      this.recordBytes = 0;
      this.recordQueue = [];
      this.lastHeaderAt = Date.now();
      // 先写 44 字节占位头，停止录制时回填真实长度
      fs.writeSync(this.recordFd, this.buildWavHeader(0));

      this.recordTimer = setInterval(() => {
        this.flushRecordQueue();
      }, RECORD_FLUSH_MS);

      this.log('开始录制');
      return this.recordPath;
    } catch (err) {
      const e = err as BusinessError;
      this.log(`录制启动失败: code=${e.code}, message=${e.message}`);
      this.recordFd = -1;
      return '';
    }
  }

  async stopRecording(): Promise<string> {
    if (this.recordFd < 0) {
      return '';
    }
    if (this.recordTimer >= 0) {
      clearInterval(this.recordTimer);
      this.recordTimer = -1;
    }
    this.flushRecordQueue();

    const path: string = this.recordPath;
    const bytes: number = this.recordBytes;
    try {
      fs.closeSync(this.recordFd);
      // 回填 WAV 头里的真实数据长度
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE);
      fs.writeSync(file.fd, this.buildWavHeader(bytes));
      fs.closeSync(file);
      // 缩略波形存成同名 .wave 文件，播放时用来还原
      this.saveWaveSidecar(path);
      this.log(`录制结束，共 ${(bytes / 1024).toFixed(1)} KB`);
    } catch (err) {
      const e = err as BusinessError;
      this.log(`录制收尾失败: code=${e.code}, message=${e.message}`);
    }

    this.recordFd = -1;
    this.recordPath = '';
    this.recordBytes = 0;
    this.recordQueue = [];
    this.recordWave = [];
    return path;
  }

  /** 把录制时的缩略波形写成 JSON sidecar */
  private saveWaveSidecar(wavPath: string): void {
    try {
      const wavePath: string = `${wavPath}.wave`;
      const file = fs.openSync(wavePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fs.writeSync(file.fd, JSON.stringify(this.recordWave));
      fs.closeSync(file);
    } catch (err) {
      const e = err as BusinessError;
      this.log(`保存波形失败: code=${e.code}, message=${e.message}`);
    }
  }

  private flushRecordQueue(): void {
    if (this.recordFd < 0 || this.recordQueue.length === 0) {
      return;
    }
    try {
      for (let i = 0; i < this.recordQueue.length; i++) {
        const chunk: ArrayBuffer = this.recordQueue[i];
        fs.writeSync(this.recordFd, chunk);
        this.recordBytes += chunk.byteLength;
      }
      // 定期回填一次头：万一进程被系统杀掉，文件也不会因为长度为 0 而打不开
      if (Date.now() - this.lastHeaderAt > 2000) {
        this.lastHeaderAt = Date.now();
        this.rewriteHeader(this.recordBytes);
      }
    } catch (err) {
      const e = err as BusinessError;
      this.log(`写入录音失败: code=${e.code}, message=${e.message}`);
    }
    this.recordQueue = [];
  }

  /** 在文件开头重写 44 字节头（另开一个 fd，避免打乱追加写入的位置） */
  private rewriteHeader(dataSize: number): void {
    try {
      const file = fs.openSync(this.recordPath, fs.OpenMode.READ_WRITE);
      fs.writeSync(file.fd, this.buildWavHeader(dataSize));
      fs.closeSync(file);
    } catch (err) {
      // 回填失败不影响继续录制
    }
  }

  /** 生成 44 字节 WAV 头（PCM / 单声道 / 16 bit / 48 kHz） */
  private buildWavHeader(dataSize: number): ArrayBuffer {
    const header = new ArrayBuffer(44);
    const view = new DataView(header);
    this.writeAscii(view, 0, 'RIFF');
    view.setUint32(4, 36 + dataSize, true);
    this.writeAscii(view, 8, 'WAVE');
    this.writeAscii(view, 12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, CHANNEL_COUNT, true);
    view.setUint32(24, SAMPLE_RATE, true);
    view.setUint32(28, SAMPLE_RATE * CHANNEL_COUNT * BYTES_PER_SAMPLE, true);
    view.setUint16(32, CHANNEL_COUNT * BYTES_PER_SAMPLE, true);
    view.setUint16(34, 16, true);
    this.writeAscii(view, 36, 'data');
    view.setUint32(40, dataSize, true);
    return header;
  }

  private writeAscii(view: DataView, offset: number, text: string): void {
    for (let i = 0; i < text.length; i++) {
      view.setUint8(offset + i, text.charCodeAt(i));
    }
  }

  /** 创建采集器时就应用系统级降噪，必须在 start 之前设置 */
  private applySystemNoiseReduction(capturer: audio.AudioCapturer): void {
    try {
      const modes: audio.NoiseReductionMode[] = capturer.getSupportedNoiseReductionModes();
      let chosen: audio.NoiseReductionMode | undefined = undefined;
      let label: string = '不支持';
      for (let i = 0; i < modes.length; i++) {
        if (modes[i] === audio.NoiseReductionMode.PURE_VOCALS) {
          chosen = modes[i];
          label = '人声增强';
          break;
        }
      }
      if (chosen === undefined) {
        for (let i = 0; i < modes.length; i++) {
          if (modes[i] === audio.NoiseReductionMode.STANDARD) {
            chosen = modes[i];
            label = '标准';
            break;
          }
        }
      }
      if (chosen === undefined) {
        this.noiseModeText = '设备不支持';
        this.log('设备不支持系统降噪，仅使用应用层噪声门');
        return;
      }
      capturer.setNoiseReductionMode(chosen);
      this.noiseModeText = `系统降噪：${label}`;
      this.log(`已启用系统降噪：${label}`);
    } catch (err) {
      const e = err as BusinessError;
      this.noiseModeText = '系统降噪不可用';
      this.log(`设置系统降噪失败: code=${e.code}, message=${e.message}`);
    }
  }

  /**
   * 启动采集。
   * @param captureOnly true = 只采集不播放（给低时延监听做波形和录制用）
   */
  async start(captureOnly: boolean = false): Promise<boolean> {
    if (this.capturer !== undefined) {
      return true;
    }
    const ringSize: number = Math.floor(SAMPLE_RATE * CHANNEL_COUNT * BYTES_PER_SAMPLE * RING_SECONDS);
    this.ring = new Uint8Array(ringSize);
    this.writePos = 0;
    this.readPos = 0;
    this.filled = 0;
    this.gain = 1;
    this.suppressedFrames = 0;
    this.frameCount = 0;

    try {
      const capturerOptions: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_MIC,
          capturerFlags: 0
        }
      };
      this.capturer = await audio.createAudioCapturer(capturerOptions);
      this.applySystemNoiseReduction(this.capturer);

      const onReadData: (buffer: ArrayBuffer) => void = (buffer: ArrayBuffer) => {
        this.push(buffer);
      };
      this.readDataCallback = onReadData;
      this.capturer.on('readData', onReadData);

      if (!captureOnly) {
        const rendererOptions: audio.AudioRendererOptions = {
          streamInfo: {
            samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
            channels: audio.AudioChannel.CHANNEL_1,
            sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
            encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
          },
          rendererInfo: {
            usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
            rendererFlags: 0
          }
        };
        this.renderer = await audio.createAudioRenderer(rendererOptions);

        const onWriteData: (buffer: ArrayBuffer) => audio.AudioDataCallbackResult = (buffer: ArrayBuffer) => {
          this.pop(buffer);
          return audio.AudioDataCallbackResult.VALID;
        };
        this.writeDataCallback = onWriteData;
        this.renderer.on('writeData', onWriteData);
      }

      await this.capturer.start();
      if (this.renderer !== undefined) {
        await this.renderer.start();
      }
      this.log(captureOnly
        ? `旁路采集已启动（48kHz / 单声道 / S16LE）`
        : `实时监听已启动（48kHz / 单声道 / S16LE，阈值 ${this.thresholdDb} dB）`);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      this.log(`采集启动失败: code=${e.code}, message=${e.message}`);
      await this.stop();
      return false;
    }
  }

  async stop(): Promise<void> {
    const capturer = this.capturer;
    const renderer = this.renderer;
    this.capturer = undefined;
    this.renderer = undefined;

    if (capturer !== undefined) {
      try {
        if (this.readDataCallback !== undefined) {
          capturer.off('readData', this.readDataCallback);
          this.readDataCallback = undefined;
        }
        await capturer.stop();
      } catch (err) {
        const e = err as BusinessError;
        this.log(`停止采集失败: code=${e.code}, message=${e.message}`);
      }
      try {
        await capturer.release();
      } catch (err) {
        const e = err as BusinessError;
        this.log(`释放采集器失败: code=${e.code}, message=${e.message}`);
      }
    }

    if (renderer !== undefined) {
      try {
        if (this.writeDataCallback !== undefined) {
          renderer.off('writeData', this.writeDataCallback);
          this.writeDataCallback = undefined;
        }
        await renderer.stop();
      } catch (err) {
        const e = err as BusinessError;
        this.log(`停止播放失败: code=${e.code}, message=${e.message}`);
      }
      try {
        await renderer.release();
      } catch (err) {
        const e = err as BusinessError;
        this.log(`释放播放器失败: code=${e.code}, message=${e.message}`);
      }
    }

    this.filled = 0;
    this.log('实时监听已停止');
  }

  /** 退出前把还在录的文件收尾 */
  async shutdown(): Promise<void> {
    if (this.recordFd >= 0) {
      await this.stopRecording();
    }
    await this.stop();
  }
}
