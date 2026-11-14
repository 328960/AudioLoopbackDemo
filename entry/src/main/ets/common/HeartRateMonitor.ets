import { ble, connection } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 心率服务：0x180D */
const HR_SERVICE_UUID: string = '0000180D-0000-1000-8000-00805F9B34FB';
/** 心率测量特征值：0x2A37 */
const HR_MEASUREMENT_UUID: string = '00002A37-0000-1000-8000-00805F9B34FB';
/** AD 结构里的类型：Service Data - 16-bit UUID */
const AD_TYPE_SERVICE_DATA_16: number = 0x16;
/** 扫描多久后开始尝试连接（毫秒） */
const SCAN_WINDOW_MS: number = 4000;

/**
 * 读取周边设备的心率。
 *
 * 两条路：
 * 1. 广播里直接带心率（少数心率带会这么发）——扫到就用；
 * 2. 广播里没有（大多数手表，尤其是已连手机的），就扫描到设备后建立 GATT 连接，
 *    订阅心率测量特征值 0x2A37 的 notify。
 */
export class HeartRateMonitor {
  private static instance: HeartRateMonitor | undefined = undefined;

  private scanning: boolean = false;
  private scanCallback: ((results: ble.ScanResult[]) => void) | undefined = undefined;
  private onBpm: ((bpm: number, deviceId: string) => void) | undefined = undefined;
  private log: (message: string) => void = () => {};

  private candidates: string[] = [];
  private client: ble.GattClientDevice | undefined = undefined;
  private clientDeviceId: string = '';
  private subscribed: boolean = false;
  private scanTimer: number = -1;

  static shared(): HeartRateMonitor {
    if (HeartRateMonitor.instance === undefined) {
      HeartRateMonitor.instance = new HeartRateMonitor();
    }
    return HeartRateMonitor.instance;
  }

  bindLog(log: (message: string) => void): void {
    this.log = log;
  }

  isScanning(): boolean {
    return this.scanning;
  }

  start(onBpm: (bpm: number, deviceId: string) => void, onError?: (message: string) => void): boolean {
    if (this.scanning) {
      return true;
    }
    this.onBpm = onBpm;
    this.candidates = [];

    // 注意：不能走「已配对设备」——那里是经典蓝牙地址，GATT 连接会 1→3 立刻断开。
    // 必须用 BLE 扫描拿广播地址，所以这里只做扫描。
    try {
      this.scanCallback = (results: ble.ScanResult[]) => {
        for (let i = 0; i < results.length; i++) {
          const deviceId: string = results[i].deviceId;
          const bpm: number = HeartRateMonitor.parseHeartRate(results[i].data);
          if (bpm > 0 && this.onBpm !== undefined) {
            this.onBpm(bpm, deviceId);
          }
          if (this.candidates.indexOf(deviceId) < 0) {
            this.candidates.push(deviceId);
          }
        }
      };
      ble.on('BLEDeviceFind', this.scanCallback);
      // 按心率服务过滤；空数组在部分版本会被判成参数无效（401）
      const filter: ble.ScanFilter = { serviceUuid: HR_SERVICE_UUID };
      ble.startBLEScan([filter]);
      this.scanning = true;
      this.scanTimer = setTimeout(() => {
        this.stopScanOnly();
        this.connectNext();
      }, SCAN_WINDOW_MS);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      if (onError !== undefined) {
        onError(`code=${e.code}, message=${e.message}`);
      }
      this.stop();
      return false;
    }
  }

  /** 只停扫描，保留连接 */
  private stopScanOnly(): void {
    if (this.scanTimer >= 0) {
      clearTimeout(this.scanTimer);
      this.scanTimer = -1;
    }
    if (this.scanCallback !== undefined) {
      try {
        ble.off('BLEDeviceFind', this.scanCallback);
      } catch (err) {
        // 忽略
      }
      this.scanCallback = undefined;
    }
    try {
      ble.stopBLEScan();
    } catch (err) {
      // 忽略
    }
  }

  /** 依次尝试连接候选设备，订阅心率测量 */
  private connectNext(): void {
    const deviceId: string | undefined = this.candidates.shift();
    if (deviceId === undefined) {
      this.log('没有可连接的设备，请确认手表已开启「心率广播」');
      this.scanning = false;
      return;
    }
    try {
      const client: ble.GattClientDevice = ble.createGattClientDevice(deviceId);
      this.client = client;
      this.clientDeviceId = deviceId;
      this.subscribed = false;

      client.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
        this.log(`连接状态 ${state.state}（0=断开 1=连接中 2=已连接）`);
        if (state.state === 2) {
          this.subscribeHeartRate(client, deviceId);
        }
      });
      client.on('BLECharacteristicChange', (characteristic: ble.BLECharacteristic) => {
        const uuid: string = characteristic.characteristicUuid.toUpperCase();
        if (uuid === HR_MEASUREMENT_UUID.toUpperCase()) {
          const bpm: number = HeartRateMonitor.parseMeasurement(characteristic.characteristicValue);
          if (bpm > 0 && this.onBpm !== undefined) {
            this.onBpm(bpm, deviceId);
          }
        }
      });
      client.connect();
      this.log(`正在连接 ${deviceId} …`);
      // 10 秒还没订阅上就换下一台
      setTimeout(() => {
        if (!this.subscribed) {
          this.log(`连接 ${deviceId} 未拿到心率，换下一台`);
          this.disconnectCurrent();
          this.connectNext();
        }
      }, 10000);
    } catch (err) {
      const e = err as BusinessError;
      this.log(`连接失败: code=${e.code}`);
      this.connectNext();
    }
  }

  private async subscribeHeartRate(client: ble.GattClientDevice, deviceId: string): Promise<void> {
    try {
      const services: ble.GattService[] = await client.getServices();
      for (let i = 0; i < services.length; i++) {
        const service = services[i];
        if (service.serviceUuid.toUpperCase() !== HR_SERVICE_UUID.toUpperCase()) {
          continue;
        }
        for (let j = 0; j < service.characteristics.length; j++) {
          const characteristic = service.characteristics[j];
          if (characteristic.characteristicUuid.toUpperCase() === HR_MEASUREMENT_UUID.toUpperCase()) {
            await client.setCharacteristicChangeNotification(characteristic, true);
            this.subscribed = true;
            this.log(`已订阅 ${deviceId} 的心率测量`);
            return;
          }
        }
      }
      this.log('该设备的 GATT 服务里没有心率测量特征值');
    } catch (err) {
      const e = err as BusinessError;
      this.log(`读取 GATT 服务失败: code=${e.code}`);
    }
  }

  private disconnectCurrent(): void {
    const client = this.client;
    this.client = undefined;
    this.subscribed = false;
    if (client !== undefined) {
      try {
        client.disconnect();
      } catch (err) {
        // 忽略
      }
      try {
        client.close();
      } catch (err) {
        // 忽略
      }
    }
  }

  stop(): void {
    this.stopScanOnly();
    this.disconnectCurrent();
    this.scanning = false;
    this.candidates = [];
  }

  /** 广播数据里的心率（AD 结构：len | type | UUID 小端 | flags | value） */
  static parseHeartRate(data: ArrayBuffer): number {
    if (data.byteLength === 0) {
      return -1;
    }
    const bytes = new Uint8Array(data);
    let index: number = 0;
    while (index < bytes.length) {
      const length: number = bytes[index];
      if (length === 0) {
        break;
      }
      const type: number = bytes[index + 1];
      if (type === AD_TYPE_SERVICE_DATA_16 && index + 4 < bytes.length) {
        const uuidLow: number = bytes[index + 2];
        const uuidHigh: number = bytes[index + 3];
        if (uuidLow === 0x0D && uuidHigh === 0x18) {
          const flagsIndex: number = index + 4;
          const flags: number = bytes[flagsIndex];
          const wide: boolean = (flags & 0x01) !== 0;
          if (wide) {
            if (flagsIndex + 2 >= bytes.length) {
              return -1;
            }
            return bytes[flagsIndex + 1] | (bytes[flagsIndex + 2] << 8);
          }
          if (flagsIndex + 1 >= bytes.length) {
            return -1;
          }
          return bytes[flagsIndex + 1];
        }
      }
      index += length + 1;
    }
    return -1;
  }

  /** 心率测量值（0x2A37）：flags.bit0 = 0 → 1 字节，= 1 → 2 字节小端 */
  static parseMeasurement(value: ArrayBuffer): number {
    if (value.byteLength < 2) {
      return -1;
    }
    const bytes = new Uint8Array(value);
    const flags: number = bytes[0];
    const wide: boolean = (flags & 0x01) !== 0;
    if (wide) {
      if (bytes.length < 3) {
        return -1;
      }
      return bytes[1] | (bytes[2] << 8);
    }
    return bytes[1];
  }
}
