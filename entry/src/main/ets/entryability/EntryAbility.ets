import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { emitter } from '@kit.BasicServicesKit';
import { WindowLayout } from './WindowLayout';
import { getClientController } from '../pages/ClientController';

const DOMAIN: number = 0x5453;
const TAG: string = 'TailscaleProbe';

export default class EntryAbility extends UIAbility {
  private layout: WindowLayout | undefined = undefined;
  private stageDestroyed: boolean = false;
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    getClientController().bindRuntime(this.context);
    hilog.info(DOMAIN, TAG, 'EntryAbility created');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.stageDestroyed = false;
    this.loadWindow(windowStage);
  }

  private async loadWindow(windowStage: window.WindowStage): Promise<void> {
    try {
      this.layout = new WindowLayout(windowStage.getMainWindowSync());
      await this.layout.start();
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Window layout failed: %{public}s', `${error}`);
    }
    if (this.stageDestroyed) { return; }
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(error));
        return;
      }
      hilog.info(DOMAIN, TAG, 'ArkUI content loaded');
    });
  }

  onWindowStageDestroy(): void {
    this.stageDestroyed = true;
    this.layout?.stop();
    this.layout = undefined;
  }

  onDestroy(): void {
    getClientController().destroyRuntime();
    hilog.info(DOMAIN, TAG, 'EntryAbility destroyed');
  }

  onForeground(): void {
    emitter.emit('tailscale.foreground');
  }

  onBackground(): void {
    emitter.emit('tailscale.background');
  }
}
