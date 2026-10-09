import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { close, diagnostics, getLogs, getVersion, start } from 'libtailscale_napi.so';

const DOMAIN: number = 0x5453;
const TAG: string = 'TailscaleProbe';

@Entry
@Component
struct Index {
  @State private output: string = 'Ready';
  @State private busy: boolean = false;
  @State private hostname: string = 'harmony-tsnet';
  private dataDir: string = '';

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.dataDir = `${context.filesDir}/tailscale`;
    this.showVersion();
  }

  private formatJSON(raw: string): string {
    try {
      return JSON.stringify(JSON.parse(raw), null, 2);
    } catch (_error) {
      return raw;
    }
  }

  private showVersion(): void {
    try {
      const result: string = getVersion();
      this.output = this.formatJSON(result);
      hilog.info(DOMAIN, TAG, 'version=%{public}s', result);
    } catch (error) {
      this.output = `Version query failed: ${error}`;
      hilog.error(DOMAIN, TAG, '%{public}s', this.output);
    }
  }

  private async runDiagnostics(): Promise<void> {
    this.busy = true;
    try {
      const result: string = await diagnostics(this.dataDir);
      this.output = this.formatJSON(result);
    } catch (error) {
      this.output = `Diagnostics failed: ${error}`;
    } finally {
      this.busy = false;
    }
  }

  private async startTsnet(): Promise<void> {
    this.busy = true;
    this.output = `Starting tsnet on worker thread...\nDir: ${this.dataDir}`;
    try {
      const result: string = await start(this.dataDir, this.hostname);
      this.output = this.formatJSON(result);
    } catch (error) {
      this.output = `tsnet.Start failed: ${error}`;
    } finally {
      this.busy = false;
    }
  }

  private async closeTsnet(): Promise<void> {
    this.busy = true;
    try {
      const result: string = await close();
      this.output = this.formatJSON(result);
    } catch (error) {
      this.output = `tsnet.Close failed: ${error}`;
    } finally {
      this.busy = false;
    }
  }

  private showLogs(): void {
    try {
      this.output = getLogs();
    } catch (error) {
      this.output = `Log query failed: ${error}`;
    }
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('Tailscale Go Runtime Probe')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .width('100%')

        Text(`Persistent state: ${this.dataDir}`)
          .fontSize(12)
          .fontColor('#64748b')
          .width('100%')

        TextInput({ text: this.hostname, placeholder: 'tsnet hostname' })
          .width('100%')
          .onChange((value: string) => {
            this.hostname = value;
          })

        Button('Query native versions')
          .width('100%')
          .enabled(!this.busy)
          .onClick(() => this.showVersion())

        Button('Run platform diagnostics')
          .width('100%')
          .enabled(!this.busy)
          .onClick(() => {
            this.runDiagnostics();
          })

        Button('Start tsnet asynchronously')
          .width('100%')
          .enabled(!this.busy)
          .onClick(() => {
            this.startTsnet();
          })

        Button('Read Go logs')
          .width('100%')
          .enabled(!this.busy)
          .onClick(() => this.showLogs())

        Button('Close tsnet')
          .width('100%')
          .enabled(!this.busy)
          .onClick(() => {
            this.closeTsnet();
          })

        Text(this.busy ? 'Working on NAPI worker thread...' : this.output)
          .fontFamily('monospace')
          .fontSize(12)
          .width('100%')
          .padding(12)
          .backgroundColor('#f1f5f9')
          .borderRadius(8)
          .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
    .height('100%')
  }
}
