import { window } from '@kit.ArkUI';

// Paint the whole window, while keeping controls clear of the status bar,
// navigation indicator and display cutouts. Insets also update on rotation.
export class WindowLayout {
  private mainWindow: window.Window;
  private listening: boolean = false;
  private stopped: boolean = false;
  private changed = (_options: window.AvoidAreaOptions): void => { this.updateInsets(); };

  constructor(mainWindow: window.Window) { this.mainWindow = mainWindow; }

  private updateInsets(): void {
    const types: window.AvoidAreaType[] = [window.AvoidAreaType.TYPE_SYSTEM,
      window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR, window.AvoidAreaType.TYPE_CUTOUT];
    let top: number = 0;
    let bottom: number = 0;
    let left: number = 0;
    let right: number = 0;
    for (const type of types) {
      const area = this.mainWindow.getWindowAvoidArea(type);
      top = Math.max(top, area.topRect.height);
      bottom = Math.max(bottom, area.bottomRect.height);
      left = Math.max(left, area.leftRect.width);
      right = Math.max(right, area.rightRect.width);
    }
    const ui = this.mainWindow.getUIContext();
    AppStorage.setOrCreate('tailscale.safeTop', ui.px2vp(top));
    AppStorage.setOrCreate('tailscale.safeBottom', ui.px2vp(bottom));
    AppStorage.setOrCreate('tailscale.safeLeft', ui.px2vp(left));
    AppStorage.setOrCreate('tailscale.safeRight', ui.px2vp(right));
  }

  async start(): Promise<void> {
    // The gesture-navigation area may expose the window surface rather than
    // navigationBarColor (which controls the three-button navigation bar).
    // Paint it before loading content, including during first-frame/layout gaps.
    this.mainWindow.setWindowBackgroundColor('#EEF6FC');
    await this.mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#EAF4FF', navigationBarColor: '#EEF6FC',
      statusBarContentColor: '#142337', navigationBarContentColor: '#142337'
    });
    if (this.stopped) { return; }
    // Read safe areas before changing layout so content cannot load under the
    // system bars. Don't hide the system bars or the navigation indicator.
    this.updateInsets();
    this.mainWindow.on('avoidAreaChange', this.changed);
    this.listening = true;
    try {
      await this.mainWindow.setWindowLayoutFullScreen(true);
      if (!this.stopped) { this.updateInsets(); }
    } catch (error) {
      // Full-screen was not enabled: the normal window already avoids bars.
      // Reset our extra content insets rather than applying them twice.
      this.stop();
      AppStorage.setOrCreate('tailscale.safeTop', 0);
      AppStorage.setOrCreate('tailscale.safeBottom', 0);
      AppStorage.setOrCreate('tailscale.safeLeft', 0);
      AppStorage.setOrCreate('tailscale.safeRight', 0);
      throw new Error(`Full-screen layout failed: ${error}`);
    }
  }

  stop(): void {
    this.stopped = true;
    if (this.listening) {
      this.mainWindow.off('avoidAreaChange', this.changed);
      this.listening = false;
    }
  }
}
