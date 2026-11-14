import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { LoopbackController } from '../common/AudioLoopbackController';
import { SoftwareEarMonitor } from '../common/SoftwareEarMonitor';

const DOMAIN: number = 0x0001;
const TAG: string = 'AudioLoopbackDemo';

export default class EntryAbility extends UIAbility {
  private stage: window.WindowStage | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    // COLOR_MODE_NOT_SET = 跟随系统深浅色，页面颜色由 resources/dark 限定符自动切换
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setColorMode failed: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
    LoopbackController.shared().stop();
    SoftwareEarMonitor.shared().shutdown();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    this.stage = windowStage;
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });

    this.applyImmersive(windowStage, this.isDarkMode());
  }

  /** 系统深浅色切换时同步系统栏配色 */
  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(DOMAIN, TAG, 'onConfigurationUpdate, colorMode=%{public}d', newConfig.colorMode);
    const isDark: boolean = newConfig.colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    if (this.stage !== undefined) {
      this.applyImmersive(this.stage, isDark);
    }
  }

  private isDarkMode(): boolean {
    try {
      return this.context.config.colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } catch (err) {
      return true;
    }
  }

  /**
   * 沉浸式：窗口铺满 + 系统栏配色跟随深浅色。
   *
   * 只设 statusBarColor 在部分机型上不生效（状态栏仍由系统画白底），
   * 必须配合 setWindowLayoutFullScreen(true)，让状态栏区域透出窗口背景色。
   */
  private applyImmersive(windowStage: window.WindowStage, isDark: boolean): void {
    const bg: string = isDark ? '#0E0E10' : '#F2F3F5';
    const content: string = isDark ? '#FFFFFF' : '#000000';
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();

      mainWindow.setWindowLayoutFullScreen(true).then(() => {
        hilog.info(DOMAIN, TAG, '%{public}s', 'setWindowLayoutFullScreen ok');
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(err));
      });

      mainWindow.setWindowBackgroundColor(bg);

      mainWindow.setWindowSystemBarProperties({
        statusBarColor: bg,
        statusBarContentColor: content,
        navigationBarColor: bg,
        navigationBarContentColor: content
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'applyImmersive failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
    this.stage = undefined;
    LoopbackController.shared().stop();
    SoftwareEarMonitor.shared().shutdown();
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  /**
   * 退到后台时主动停掉监听。
   *
   * 系统会把后台应用的音频输出挂起，但 AudioLoopback 状态可能仍报
   * AVAILABLE_RUNNING，回来时界面显示「运行中」却没有声音。
   * 与其留着这个假状态，不如彻底停掉，回到前台由页面同步成「就绪」。
   */
  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground, stop monitoring');
    LoopbackController.shared().stop();
    SoftwareEarMonitor.shared().shutdown();
  }
}
