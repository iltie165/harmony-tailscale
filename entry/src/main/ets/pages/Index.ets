import { common, Want } from '@kit.AbilityKit';
import { emitter } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import tailscale from 'libtailscale_napi.so';
import { requestVpnProbe } from '../vpn/VpnProbeClient';
import { PlatformVpnProbeRequest } from '../vpn/VpnProbePlatform';
import { ControlResult, PeerInfo, readControl, readPeers, isAuthenticated,
  accountName, tailnetName, peerName, peerAddress, osLabel, safeOutput } from './ClientModel';

const BLUE: string = '#086CFA';
const INK: string = '#142337';
const MUTED: string = '#6D8094';

@Entry
@Component
struct Index {
  @State private page: string = 'main';
  @State private status: ControlResult = {};
  @State private peers: PeerInfo[] = [];
  @State private selectedPeer: PeerInfo | undefined = undefined;
  @State private output: string = '';
  @State private busy: boolean = false;
  @State private progress: string = '';
  @State private message: string = '';
  @State private hostname: string = 'harmony-tsnet';
  @State private peerFilter: string = '';
  @State private showFilter: boolean = false;
  @State private lastUpdated: string = '';
  @State private awaitingLogin: boolean = false;
  private dataDir: string = '';
  private appContext: common.UIAbilityContext | undefined = undefined;
  private pollTimer: number = -1;
  private loginDeadline: number = 0;
  private restoreDeadline: number = 0;
  private foreground: boolean = true;
  private mounted: boolean = false;
  private foregroundCallback = (_event: emitter.EventData): void => {
    this.foreground = true;
    if (!this.busy) { this.refreshData(); }
  };
  private backgroundCallback = (_event: emitter.EventData): void => { this.foreground = false; };

  aboutToAppear(): void {
    this.mounted = true;
    this.appContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.dataDir = `${this.appContext.filesDir}/tailscale`;
    emitter.on('tailscale.foreground', this.foregroundCallback);
    emitter.on('tailscale.background', this.backgroundCallback);
    this.restoreSession();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.stopPolling();
    emitter.off('tailscale.foreground', this.foregroundCallback);
    emitter.off('tailscale.background', this.backgroundCallback);
  }

  onBackPress(): boolean {
    if (this.page !== 'main') {
      this.page = this.page === 'diagnostics' ? 'settings' : 'main';
      return true;
    }
    return false;
  }

  private stopPolling(): void {
    if (this.pollTimer !== -1) { clearTimeout(this.pollTimer); this.pollTimer = -1; }
  }

  private scheduleLoginRefresh(): void {
    this.stopPolling();
    if (!this.mounted) { return; }
    if (this.awaitingLogin && Date.now() >= this.loginDeadline) {
      this.awaitingLogin = false;
      this.message = '尚未确认登录。完成浏览器认证后，点击登录重试。';
      return;
    }
    if (!this.awaitingLogin && Date.now() >= this.restoreDeadline) { return; }
    this.pollTimer = setTimeout(() => {
      this.pollTimer = -1;
      if (this.foreground && !this.busy) { this.refreshData(); }
      else { this.scheduleLoginRefresh(); }
    }, 2000);
  }

  private applyStatus(result: ControlResult): void {
    if (!this.mounted) { return; }
    this.status = result;
    if (!isAuthenticated(result)) {
      this.peers = [];
      this.selectedPeer = undefined;
      this.lastUpdated = '';
      if (this.page === 'detail') { this.page = 'main'; }
    } else {
      this.awaitingLogin = false;
      this.restoreDeadline = 0;
      this.stopPolling();
    }
  }

  private async loadData(): Promise<void> {
    const raw: string = await tailscale.getStatus();
    if (!this.mounted) { return; }
    this.output = safeOutput(raw);
    this.applyStatus(readControl(raw));
    if (isAuthenticated(this.status)) {
      const peerRaw: string = await tailscale.onlinePeers(this.peerFilter.trim());
      if (!this.mounted) { return; }
      this.output = safeOutput(peerRaw);
      this.peers = readPeers(peerRaw);
      this.lastUpdated = new Date().toLocaleTimeString();
    }
  }

  private async restoreSession(): Promise<void> {
    this.busy = true;
    this.restoreDeadline = Date.now() + 15000;
    this.progress = '正在恢复登录状态…';
    try {
      readControl(await tailscale.start(this.dataDir, this.hostname));
      if (!this.mounted) { return; }
      await this.loadData();
    } catch (error) {
      this.restoreDeadline = 0;
      this.message = `恢复状态失败：${error}`;
    } finally { this.busy = false; this.scheduleLoginRefresh(); }
  }

  private async refreshData(): Promise<void> {
    if (this.busy || !this.mounted) { return; }
    this.busy = true;
    this.progress = '正在更新状态与设备…';
    this.message = '';
    try { await this.loadData(); }
    catch (error) {
      this.message = `刷新失败：${error}`;
      this.peers = [];
      this.lastUpdated = '';
    } finally {
      this.busy = false;
      this.scheduleLoginRefresh();
    }
  }

  private async openSystemBrowser(url: string): Promise<void> {
    if (!this.appContext) { throw new Error('UIAbilityContext is unavailable'); }
    try { await this.appContext.openLink(url, { appLinkingOnly: false }); }
    catch (openLinkError) {
      const browserWant: Want = {
        action: 'ohos.want.action.viewData', uri: url, entities: ['entity.system.browsable']
      };
      try { await this.appContext.startAbility(browserWant); }
      catch (startAbilityError) {
        throw new Error(`openLink failed: ${openLinkError}; startAbility failed: ${startAbilityError}`);
      }
    }
  }

  private async login(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.message = '';
    this.progress = '正在获取安全登录链接…';
    try {
      readControl(await tailscale.start(this.dataDir, this.hostname));
      if (!this.mounted) { return; }
      const raw: string = await tailscale.login();
      if (!this.mounted) { return; }
      this.output = safeOutput(raw);
      const result: ControlResult = readControl(raw);
      this.applyStatus(result);
      if (isAuthenticated(result)) { await this.loadData(); }
      else if (result.authUrl) {
        this.progress = '正在打开系统浏览器…';
        await this.openSystemBrowser(result.authUrl);
        if (!this.mounted) { return; }
        hilog.info(0x5453, 'TailscaleProbe', 'Official login browser dispatched');
        this.awaitingLogin = true;
        this.loginDeadline = Date.now() + 120000;
        this.message = '请在浏览器中完成认证，返回后将自动更新。';
      } else { throw new Error('控制面未返回登录链接，请在设置中查看诊断结果。'); }
    } catch (error) { this.message = `登录失败：${error}`; }
    finally { this.busy = false; this.scheduleLoginRefresh(); }
  }

  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({
      title: '退出 Tailscale？', message: '将注销这台设备的登录状态。再次使用时需要重新认证。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '退出登录', action: () => { this.logout(); } }
    });
  }

  private async logout(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.progress = '正在退出登录…';
    try {
      const raw: string = await tailscale.logout();
      if (!this.mounted) { return; }
      this.output = safeOutput(raw);
      const result: ControlResult = readControl(raw);
      if (isAuthenticated(result)) { throw new Error('控制面仍报告已登录，请刷新后重试'); }
      this.applyStatus(result);
      this.awaitingLogin = false;
      this.restoreDeadline = 0;
      this.stopPolling();
      this.page = 'main';
      this.message = '已退出登录。';
    } catch (error) { this.message = `退出失败：${error}`; }
    finally { this.busy = false; }
  }

  private async diagnostic(operation: string): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.progress = '正在执行诊断…';
    try {
      if (operation === 'versions') { this.output = safeOutput(tailscale.getVersion()); }
      else if (operation === 'logs') { this.output = safeOutput(tailscale.getLogs()); }
      else if (operation === 'browser') {
        await this.openSystemBrowser('https://login.tailscale.com/');
        this.output = '系统浏览器已成功唤起。';
      } else if (operation === 'close') {
        const raw: string = await tailscale.close();
        readControl(raw);
        this.output = safeOutput(raw);
        this.applyStatus({ ok: true, loggedIn: false, lifecycleState: 'closed' });
        this.awaitingLogin = false;
        this.restoreDeadline = 0;
        this.stopPolling();
      } else if (operation === 'start') {
        this.output = safeOutput(await tailscale.start(this.dataDir, this.hostname));
      } else if (operation === 'status') {
        const raw: string = await tailscale.getStatus();
        this.output = safeOutput(raw);
        this.applyStatus(readControl(raw));
      } else { this.output = safeOutput(await tailscale.diagnostics(this.dataDir)); }
    } catch (error) { this.output = `诊断失败：${error}`; }
    finally { this.busy = false; }
  }

  private confirmVpnProbe(): void {
    this.getUIContext().showAlertDialog({
      title: '验证系统 VPN 能力？',
      message: '系统将请求 VPN 授权，可能替换其他正在使用的 VPN。此检查仅验证网卡和网络保护接口，不接管 Tailnet 或默认路由，完成后自动关闭。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '开始检查', action: () => { this.runVpnProbe(); } }
    });
  }

  private async runVpnProbe(): Promise<void> {
    if (this.busy || !this.mounted || !this.appContext) { return; }
    this.busy = true;
    this.message = '';
    this.output = '';
    this.progress = '等待系统 VPN 授权并验证能力…';
    const requestId = `${Date.now()}-${Math.floor(Math.random() * 1000000000)}`;
    const want: Want = {
      bundleName: 'com.ezoo.tailscaleprobe', abilityName: 'VpnProbeAbility',
      parameters: { probeRequestId: requestId }
    };
    const port = new PlatformVpnProbeRequest(want, this.appContext.filesDir);
    try {
      const report = await requestVpnProbe(port, requestId, () => !this.mounted,
        (stage: string, raw: string) => {
          if (!this.mounted) { return; }
          switch (stage) {
            case 'startVpnExtensionAbility': this.progress = '正在请求系统 VPN 授权并启动扩展（最多 60 秒）…'; break;
            case 'awaitExtensionReport': this.progress = '启动调用已返回，等待 VPN 扩展报告（最多 30 秒）…'; break;
            case 'starting': this.progress = 'VPN 扩展已运行，准备网卡检查…'; break;
            case 'create': this.progress = 'VPN 扩展正在创建虚拟网卡…'; break;
            case 'protectProcessNet': this.progress = '正在验证进程网络保护…'; break;
            case 'inspectDescriptor': this.progress = '正在检查虚拟网卡描述符…'; break;
            case 'cleanup': this.progress = '正在关闭网卡并清理 VPN 连接…'; break;
            case 'stopVpnExtensionAbility': this.progress = '正在停止 VPN 扩展（最多 10 秒）…'; break;
          }
          if (raw) { this.output = safeOutput(raw); }
        });
      if (this.mounted) {
        this.output = JSON.stringify(report);
        this.message = report.ok ? '系统 VPN 能力检查通过；尚未验证 Tailnet 数据通路。' : '系统 VPN 能力检查失败，详见结果。';
      }
    } catch (error) {
      if (this.mounted) {
        this.message = '系统 VPN 能力检查未完成，详见下方错误与最后阶段；尚未确认清理。';
        this.output += `\nVPN 能力检查失败：${error}`;
      }
    } finally { this.busy = false; this.progress = ''; }
  }

  private peerIcon(os: string): Resource {
    switch (os.toLowerCase()) {
      case 'windows': return $r('app.media.device_windows');
      case 'linux': return $r('app.media.device_linux');
      case 'macos': case 'darwin': return $r('app.media.device_mac');
      case 'ios': case 'android': case 'harmonyos': case 'openharmony': return $r('app.media.device_phone');
      default: return $r('app.media.device_desktop');
    }
  }

  @Builder
  private icon(source: Resource, size: number = 22) {
    Image(source).width(size).height(size).objectFit(ImageFit.Contain)
  }

  @Builder
  private sectionHeader(title: string) {
    Row() {
      Button({ type: ButtonType.Normal }) { this.icon($r('app.media.chevron_left')) }
        .backgroundColor(Color.Transparent).width(44).height(44).borderRadius(16)
        .accessibilityText('返回').onClick(() => {
          this.page = this.page === 'diagnostics' ? 'settings' : 'main';
        })
      Text(title).fontSize(22).fontWeight(FontWeight.Bold).fontColor(INK).layoutWeight(1)
    }.width('100%').margin({ bottom: 16 })
  }

  @Builder
  private notice() {
    if (this.busy || this.message) {
      Row({ space: 10 }) {
        if (this.busy) { LoadingProgress().width(20).height(20).color(BLUE) }
        Text(this.busy ? this.progress : this.message)
          .fontSize(13).fontColor(INK).layoutWeight(1).lineHeight(20)
      }.width('100%').padding(14).backgroundColor('#E5F0FF').borderRadius(16)
        .margin({ bottom: 16 }).accessibilityText(this.busy ? this.progress : this.message)
    }
  }

  @Builder
  private feature(source: Resource, title: string, subtitle: string) {
    Row({ space: 16 }) {
      Row() { this.icon(source, 22) }.width(42).height(42).justifyContent(FlexAlign.Center)
        .backgroundColor('#E2F0FF').borderRadius(21)
      Column({ space: 4 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK)
        Text(subtitle).fontSize(12).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start)
    }.width('100%').margin({ bottom: 20 })
  }

  @Builder
  private welcome() {
    Column() {
      Row() {
        Blank()
        Button('设置').fontSize(13).fontColor(MUTED).backgroundColor(Color.Transparent)
          .height(32).onClick(() => { this.page = 'settings'; })
      }.width('100%')
      Image($r('app.media.network_hero')).width('100%').height(190)
        .objectFit(ImageFit.Contain).accessibilityText('安全连接电脑、手机与服务器')
      Text('Tailscale').fontSize(32).fontWeight(FontWeight.Bold).fontColor(INK)
      Text('for HarmonyOS').fontSize(23).fontWeight(FontWeight.Medium).fontColor(BLUE).margin({ top: 4 })
      Text('安全连接你的所有设备').fontSize(15).fontColor(MUTED).margin({ top: 12, bottom: 24 })
      this.feature($r('app.media.users'), '查看在线设备', '随时了解 Tailnet 中可见的设备')
      this.feature($r('app.media.shield'), '使用官方账号登录', '通过系统浏览器完成安全认证')
      this.feature($r('app.media.network'), '你的专属连接空间', '按设备标签、用户或名称筛选')
      this.notice()
      Button() {
        Row({ space: 12 }) {
          if (this.busy) { LoadingProgress().width(20).height(20).color(Color.White) }
          Text(this.awaitingLogin ? '刷新登录状态' : '登录 Tailscale')
            .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Color.White)
          if (!this.busy) { Text('→').fontSize(23).fontColor(Color.White) }
        }.justifyContent(FlexAlign.Center)
      }.height(54).width('100%').borderRadius(27)
        .linearGradient({ angle: 100, colors: [['#20A2F4', 0], [BLUE, 1]] })
        .enabled(!this.busy).onClick(() => {
          if (this.awaitingLogin) { this.refreshData(); } else { this.login(); }
        })
      if (this.awaitingLogin) {
        Button('重新发起登录').backgroundColor(Color.Transparent).fontColor(BLUE)
          .enabled(!this.busy).onClick(() => { this.login(); })
      }
      Text('随时随地 · 安全连接 · 高效工作').fontSize(11).fontColor('#8C9DAC')
        .margin({ top: 24, bottom: 12 })
    }.width('100%')
  }

  @Builder
  private peerCard(peer: PeerInfo) {
    Row({ space: 12 }) {
      Row() { this.icon(this.peerIcon(peer.os || ''), 26) }
        .width(48).height(48).backgroundColor('#ECF4FC').borderRadius(16).justifyContent(FlexAlign.Center)
      Column({ space: 4 }) {
        Text(peerName(peer)).fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(peer.tailscaleIPs?.[0] || '暂无 IP').fontSize(12).fontColor(MUTED)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(osLabel(peer.os || '')).fontSize(11).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Row({ space: 4 }) {
        Text('').width(6).height(6).backgroundColor('#16CF74').borderRadius(3)
        Text('在线').fontSize(11).fontColor('#089A52')
      }
      this.icon($r('app.media.chevron_right'), 14)
    }.width('100%').padding(16).borderRadius(20).backgroundColor(Color.White)
      .margin({ bottom: 10 }).onClick(() => { this.selectedPeer = peer; this.page = 'detail'; })
      .accessibilityText(`${peerName(peer)}，${osLabel(peer.os || '')}，在线，查看详情`)
  }

  @Builder
  private dashboard() {
    Row({ space: 12 }) {
      Text(accountName(this.status).slice(0, 1).toUpperCase()).fontSize(19).fontColor(BLUE)
        .fontWeight(FontWeight.Bold).width(44).height(44).textAlign(TextAlign.Center)
        .backgroundColor('#DAEAFF').borderRadius(22)
      Column({ space: 5 }) {
        Text(accountName(this.status)).fontSize(16).fontWeight(FontWeight.Medium).fontColor(INK)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(tailnetName(this.status)).fontSize(12).fontColor(MUTED)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button({ type: ButtonType.Normal }) { this.icon($r('app.media.settings')) }
        .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(16)
        .accessibilityText('设置').onClick(() => { this.page = 'settings'; })
    }.width('100%').margin({ bottom: 20 })
    Row({ space: 7 }) {
      Text('').width(7).height(7).backgroundColor(BLUE).borderRadius(4)
      Text('已登录 · VPN 尚未接入').fontSize(12).fontColor('#427297')
    }.padding({ left: 12, right: 12, top: 8, bottom: 8 }).backgroundColor('#DEEEFB')
      .borderRadius(20).margin({ bottom: 18 }).alignSelf(ItemAlign.Start)
    Row({ space: 12 }) {
      Row() { this.icon($r('app.media.shield'), 26) }.width(48).height(48)
        .backgroundColor('#EDF2F6').borderRadius(24).justifyContent(FlexAlign.Center)
      Column({ space: 6 }) {
        Text('VPN').fontSize(17).fontWeight(FontWeight.Bold).fontColor(INK)
        Text('尚未接入').fontSize(13).fontColor('#7B8C9D')
        Text('系统 VPN 功能将在后续版本提供').fontSize(11).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: false }).enabled(false)
        .accessibilityText('系统 VPN 尚未接入，开关不可用')
    }.width('100%').padding(18).backgroundColor(Color.White).borderRadius(22).margin({ bottom: 22 })
    Text(`本机 IP：${this.status.tailscaleIPs?.join(' · ') || '暂无'}`)
      .width('100%').fontSize(12).fontColor(MUTED).margin({ bottom: 20 })
      .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
    this.notice()
    if (this.status.health && this.status.health.length > 0) {
      Text(this.status.health.join('\n')).fontSize(12).fontColor('#966010')
        .width('100%').padding(14).backgroundColor('#FFF4DE').borderRadius(16).margin({ bottom: 16 })
    }
    Row() {
      Text(`在线设备 (${this.peers.length})`).fontSize(17).fontWeight(FontWeight.Bold)
        .fontColor(INK).layoutWeight(1)
      Button(this.showFilter ? '收起' : '筛选').fontSize(12).fontColor(MUTED)
        .backgroundColor(Color.Transparent).height(40).onClick(() => { this.showFilter = !this.showFilter; })
      Button() {
        Row({ space: 5 }) { this.icon($r('app.media.refresh'), 16); Text('刷新').fontSize(12).fontColor(BLUE) }
      }.backgroundColor(Color.Transparent).height(40).enabled(!this.busy).onClick(() => { this.refreshData(); })
    }.width('100%').margin({ bottom: 8 })
    if (this.showFilter) {
      TextInput({ text: this.peerFilter, placeholder: '名称 / tag:server / user:name' })
        .height(44).fontSize(13).backgroundColor(Color.White).borderRadius(14).enabled(!this.busy)
        .onChange((value: string) => { this.peerFilter = value; }).onSubmit(() => { this.refreshData(); })
        .margin({ bottom: 8 })
      Text('仅展示当前账号可见的在线设备；不支持 ACL group: 组查询。')
        .fontSize(11).fontColor(MUTED).width('100%').margin({ bottom: 12 })
    }
    ForEach(this.peers, (peer: PeerInfo) => { this.peerCard(peer) }, (peer: PeerInfo) => peer.id)
    if (this.peers.length === 0 && !this.busy) {
      Column({ space: 12 }) {
        this.icon($r('app.media.device_desktop'), 36)
        Text(this.message ? '暂时无法获取设备' : (this.peerFilter ? '没有匹配的在线设备' : '暂无可见的在线设备'))
          .fontSize(15).fontColor(INK)
        Text('点击刷新重试，或检查设备是否在线及访问策略。')
          .fontSize(12).fontColor(MUTED).textAlign(TextAlign.Center)
      }.width('100%').padding(24).backgroundColor(Color.White).borderRadius(20)
    }
    if (this.lastUpdated) {
      Text(`更新于 ${this.lastUpdated}`).fontSize(11).fontColor(MUTED).width('100%')
        .margin({ top: 8, bottom: 16 })
    }
    Row({ space: 12 }) {
      Button() {
        Row({ space: 8 }) { this.icon($r('app.media.settings'), 18); Text('设置').fontSize(14).fontColor(INK) }
      }.layoutWeight(1).height(48).borderRadius(16).backgroundColor(Color.Transparent)
        .border({ width: 1, color: '#DDE6EF' }).onClick(() => { this.page = 'settings'; })
      Button() {
        Row({ space: 8 }) { this.icon($r('app.media.logout'), 18); Text('退出登录').fontSize(14).fontColor(INK) }
      }.layoutWeight(1).height(48).borderRadius(16).backgroundColor(Color.Transparent)
        .border({ width: 1, color: '#DDE6EF' }).enabled(!this.busy).onClick(() => { this.confirmLogout(); })
    }.width('100%').margin({ top: 18, bottom: 12 })
  }

  @Builder
  private settings() {
    this.sectionHeader('设置')
    this.notice()
    Column({ space: 10 }) {
      Text('账号与网络').fontSize(12).fontColor(MUTED).width('100%')
      Text(isAuthenticated(this.status) ? accountName(this.status) : '未登录')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor(INK).width('100%')
      if (isAuthenticated(this.status)) {
        Text(tailnetName(this.status)).fontSize(13).fontColor(MUTED).width('100%')
      }
      Text('官方 Tailscale 控制面').fontSize(13).fontColor(MUTED).width('100%')
    }.padding(20).width('100%').backgroundColor(Color.White).borderRadius(22).margin({ bottom: 16 })
    Column({ space: 10 }) {
      Text('设备名称').fontSize(14).fontWeight(FontWeight.Medium).fontColor(INK).width('100%')
      TextInput({ text: this.hostname, placeholder: 'harmony-tsnet' }).fontSize(14).enabled(!this.busy)
        .backgroundColor('#F1F6FB').onChange((value: string) => { this.hostname = value; })
      Text('在关闭核心后重新启动时生效。').fontSize(11).fontColor(MUTED).width('100%')
    }.padding(20).width('100%').backgroundColor(Color.White).borderRadius(22).margin({ bottom: 16 })
    Button() {
      Row({ space: 12 }) {
        this.icon($r('app.media.settings'))
        Column({ space: 4 }) {
          Text('诊断与日志').fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK)
          Text('版本、网络检查与原始结果').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        this.icon($r('app.media.chevron_right'), 16)
      }.padding(18).width('100%')
    }.width('100%').height(80).backgroundColor(Color.White).borderRadius(22)
      .onClick(() => { this.page = 'diagnostics'; }).margin({ bottom: 24 })
    Text('Tailscale for HarmonyOS').fontSize(14).fontColor(INK)
    Text('3.1.3 · Tailscale Core 1.86.2').fontSize(12).fontColor(MUTED).margin({ top: 6 })
    Text('此版本支持登录与设备发现，尚不提供全设备 VPN。')
      .fontSize(12).fontColor(MUTED).textAlign(TextAlign.Center).margin({ top: 16 })
  }

  @Builder
  private diagnosticButton(label: string, operation: string) {
    Button(label).fontSize(13).fontColor(BLUE).backgroundColor('#E3EFFF').borderRadius(14)
      .width('100%').height(44).enabled(!this.busy).onClick(() => { this.diagnostic(operation); })
  }

  @Builder
  private diagnostics() {
    this.sectionHeader('诊断与日志')
    this.notice()
    this.diagnosticButton('查询版本', 'versions')
    this.diagnosticButton('平台与控制面检查', 'platform')
    this.diagnosticButton('读取 Go 日志', 'logs')
    this.diagnosticButton('测试系统浏览器', 'browser')
    Button('验证系统 VPN 能力（不连接 Tailnet）').fontSize(13).fontColor(BLUE)
      .backgroundColor('#E3EFFF').borderRadius(14).width('100%').height(44)
      .enabled(!this.busy).onClick(() => { this.confirmVpnProbe(); })
    this.diagnosticButton('查询核心状态', 'status')
    this.diagnosticButton('启动核心', 'start')
    this.diagnosticButton('关闭核心（不会注销账号）', 'close')
    Text(this.output || '选择一项检查，结果会显示在这里。')
      .fontFamily('monospace').fontSize(12).fontColor(INK).width('100%').padding(16)
      .backgroundColor(Color.White).borderRadius(16).textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
      .margin({ top: 12, bottom: 16 })
  }

  @Builder
  private detailRow(label: string, value: string) {
    Column({ space: 6 }) {
      Text(label).fontSize(12).fontColor(MUTED).width('100%')
      Text(value).fontSize(15).fontColor(INK).width('100%').textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
    }.width('100%').margin({ bottom: 20 })
  }

  @Builder
  private detail() {
    this.sectionHeader('设备详情')
    if (this.selectedPeer) {
      Column() {
        this.icon(this.peerIcon(this.selectedPeer.os || ''), 46)
        Text(peerName(this.selectedPeer)).fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor(INK).margin({ top: 16, bottom: 8 })
        Text('在线 · 最近一次查询结果').fontSize(12).fontColor('#089A52').margin({ bottom: 28 })
        this.detailRow('Tailscale IP', peerAddress(this.selectedPeer))
        this.detailRow('系统', osLabel(this.selectedPeer.os || ''))
        this.detailRow('DNS 名称', this.selectedPeer.dnsName || '未提供')
        this.detailRow('所属用户', this.selectedPeer.userLogin || this.selectedPeer.userName || '未提供')
        this.detailRow('设备标签', this.selectedPeer.tags?.join(' · ') || '无')
      }.width('100%').padding(24).backgroundColor(Color.White).borderRadius(24)
    }
  }

  build() {
    Scroll() {
      Column({ space: 8 }) {
        if (this.page === 'settings') { this.settings() }
        else if (this.page === 'diagnostics') { this.diagnostics() }
        else if (this.page === 'detail') { this.detail() }
        else if (isAuthenticated(this.status)) { this.dashboard() }
        else { this.welcome() }
      }.width('100%').padding({ left: 24, right: 24, top: 24, bottom: 28 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
      .linearGradient({ angle: 165, colors: [['#EAF4FF', 0], ['#F6FAFD', 0.6], ['#EEF6FC', 1]] })
  }
}
