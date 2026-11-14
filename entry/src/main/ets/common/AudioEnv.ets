import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 音频环境查询：当前输入/输出设备、低时延监听能力 */
export class AudioEnv {
  static deviceTypeName(type: audio.DeviceType): string {
    if (type === audio.DeviceType.EARPIECE) {
      return '听筒';
    }
    if (type === audio.DeviceType.SPEAKER) {
      return '扬声器';
    }
    if (type === audio.DeviceType.WIRED_HEADSET) {
      return '有线耳机（带麦）';
    }
    if (type === audio.DeviceType.WIRED_HEADPHONES) {
      return '有线耳机（无麦）';
    }
    if (type === audio.DeviceType.BLUETOOTH_SCO) {
      return '蓝牙 SCO';
    }
    if (type === audio.DeviceType.BLUETOOTH_A2DP) {
      return '蓝牙 A2DP';
    }
    if (type === audio.DeviceType.MIC) {
      return '内置麦克风';
    }
    if (type === audio.DeviceType.USB_HEADSET) {
      return 'USB 耳机';
    }
    if (type === audio.DeviceType.DISPLAY_PORT) {
      return 'DisplayPort';
    }
    return `其他设备(${type})`;
  }

  static async listDevices(flag: audio.DeviceFlag): Promise<string[]> {
    const names: string[] = [];
    try {
      const manager: audio.AudioManager = audio.getAudioManager();
      const devices: audio.AudioDeviceDescriptors = await manager.getDevices(flag);
      for (let i = 0; i < devices.length; i++) {
        names.push(AudioEnv.deviceTypeName(devices[i].deviceType));
      }
    } catch (err) {
      const e = err as BusinessError;
      names.push(`查询失败(${e.code})`);
    }
    return names;
  }

  static joinNames(names: string[]): string {
    if (names.length === 0) {
      return '无';
    }
    let text: string = names[0];
    for (let i = 1; i < names.length; i++) {
      text = `${text} / ${names[i]}`;
    }
    return text;
  }
}
