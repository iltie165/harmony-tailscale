import { common, Want } from '@kit.AbilityKit';
import { emitter } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import tailscale from 'libtailscale_napi.so';
import { requestVpnProbe } from '../vpn/VpnProbeClient';
import { PlatformVpnProbeRequest } from '../vpn/VpnProbePlatform';
import { VpnState, VpnSessionReport, readVpnState, tailnetIPv4 } from '../vpn/VpnSessionModel';
import { startVpnSession, stopVpnSession, vpnSdkPending, boundedVpn, VpnSessionError } from '../vpn/VpnSessionClient';
import { PlatformSessionRequest } from '../vpn/VpnSessionRequest';
import { ControlResult, PeerInfo, readControl, readPeers, isAuthenticated,
  accountName, tailnetName, peerName, peerAddress, osLabel, safeOutput } from './ClientModel';

const BLUE: string = '#086CFA';
const INK: string = '#142337';
const MUTED: string = '#6D8094';

@Entry
@Component
struct Index {
  @StorageLink('tailscale.safeTop') private safeTop: number = 0;
  @StorageLink('tailscale.safeBottom') private safeBottom: number = 0;
  @StorageLink('tailscale.safeLeft') private safeLeft: number = 0;
  @StorageLink('tailscale.safeRight') private safeRight: number = 0;
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
  @State private restoringSession: boolean = true;
  @State private vpn: VpnState = new VpnState();
  @State private vpnChanging: boolean = false;
  @State private vpnNeedsCleanup: boolean = false;
  private vpnTimer: number = -1;
  private vpnRequestId: string = '';
  private dataDir: string = '';
  private appContext: common.UIAbilityContext | undefined = undefined;
  private pollTimer: number = -1;
  private loginDeadline: number = 0;
  private restoreDeadline: number = 0;
  private foreground: boolean = true;
  private mounted: boolean = false;
  private refreshTask: Promise<void> | undefined = undefined;
  private foregroundCallback = (_event: emitter.EventData): void => {
    this.foreground = true;
    if (!this.busy) { this.refreshData(true); }
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
    if (this.vpnTimer !== -1) { clearTimeout(this.vpnTimer); this.vpnTimer = -1; }
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
      if (this.foreground && !this.busy) { this.refreshData(true); }
      else { this.scheduleLoginRefresh(); }
    }, 2000);
  }

  private applyStatus(result: ControlResult): void {
    if (!this.mounted) { return; }
    if (JSON.stringify(this.status) !== JSON.stringify(result)) { this.status = result; }
    if (!isAuthenticated(result)) {
      this.peers = [];
      this.selectedPeer = undefined;
      this.lastUpdated = '';
      if (this.page === 'detail') { this.page = 'main'; }
    } else if (result.backendState === 'Running') {
      this.awaitingLogin = false;
      this.restoreDeadline = 0;
      this.stopPolling();
    }
  }

  private async loadData(silent: boolean = false): Promise<void> {
    const vpnRaw: string = await tailscale.getVpnStatus();
    if (!this.mounted) { return; }
    const nextVpn = readVpnState(vpnRaw);
    // Logs change independently of product state; don't redraw the dashboard
    // merely because the native log ring changed. Diagnostics fetch them on demand.
    if (this.vpn.ok !== nextVpn.ok || this.vpn.connected !== nextVpn.connected ||
      this.vpn.state !== nextVpn.state || this.vpn.ipv4 !== nextVpn.ipv4 ||
      this.vpn.txPackets !== nextVpn.txPackets || this.vpn.rxPackets !== nextVpn.rxPackets ||
      this.vpn.txBytes !== nextVpn.txBytes || this.vpn.rxBytes !== nextVpn.rxBytes ||
      this.vpn.error !== nextVpn.error) { this.vpn = nextVpn; }
    if (!this.vpn.ok) { this.vpnNeedsCleanup = true; throw new Error(this.vpn.error || 'VPN service unavailable'); }
    const raw: string = await tailscale.getStatus();
    if (!this.mounted) { return; }
    if (!silent) { this.output = safeOutput(raw); }
    this.applyStatus(readControl(raw));
    if (isAuthenticated(this.status) && this.status.backendState === 'Running') {
      const peerRaw: string = await tailscale.onlinePeers(this.peerFilter.trim());
      if (!this.mounted) { return; }
      if (!silent) { this.output = safeOutput(peerRaw); }
      const nextPeers = readPeers(peerRaw);
      const changed = JSON.stringify(this.peers) !== JSON.stringify(nextPeers);
      if (changed) {
        this.peers = nextPeers;
        if (this.selectedPeer) { this.selectedPeer = nextPeers.find((peer: PeerInfo) => peer.id === this.selectedPeer?.id); }
      }
      if (changed || !silent) { this.lastUpdated = new Date().toLocaleTimeString(); }
    } else if (isAuthenticated(this.status)) {
      // An authenticated account can be reconnecting; no stale online claims.
      this.peers = []; this.selectedPeer = undefined; this.lastUpdated = '';
    }
    this.scheduleVpnRefresh();
  }

  private scheduleVpnRefresh(): void {
    if (this.vpnTimer !== -1) { clearTimeout(this.vpnTimer); this.vpnTimer = -1; }
    if (!this.mounted || (!this.vpnRunning() &&
      !(isAuthenticated(this.status) && this.status.backendState !== 'Running'))) { return; }
    this.vpnTimer = setTimeout(() => {
      this.vpnTimer = -1;
      if (this.foreground && !this.busy) { this.refreshData(true); }
      else { this.scheduleVpnRefresh(); }
    }, 5000);
  }

  private vpnRunning(): boolean {
    return this.vpn.connected || this.vpnNeedsCleanup || (this.vpn.state === 'connecting' && tailnetIPv4(this.vpn.ipv4));
  }

  private async disconnectVpn(): Promise<void> {
    if (!this.appContext) { throw new Error('UI context unavailable'); }
    const port = new PlatformSessionRequest(this.appContext.filesDir);
    const raw = port.read();
    const report = raw ? JSON.parse(raw) as VpnSessionReport : undefined;
    const id = report?.requestId || this.vpnRequestId;
    if (!id) { throw new Error('Cannot identify VPN owner; use system VPN settings to disconnect'); }
    await stopVpnSession(port, id);
    this.vpnNeedsCleanup = false;
    // Close the UI proxy, never log out. Resume the discovery-only backend
    // after the service has joined its engine and released the state lease.
    readControl(await tailscale.close());
    this.vpn = new VpnState(); this.vpnRequestId = '';
    readControl(await tailscale.start(this.dataDir, this.hostname));
    this.restoreDeadline = Date.now() + 15000;
  }

  private async waitForVpnReady(): Promise<string> {
    const deadline = Date.now() + 30000;
    let state = this.status.backendState || 'unknown';
    while (this.mounted && Date.now() < deadline) {
      this.progress = `正在准备 VPN，等待核心连接（${state}，最多 30 秒）…`;
      // A read timeout occurs before acquiring any VPN resource. Do not label
      // it as unverified VPN cleanup or act on a late native result.
      const raw = await new Promise<string>((resolve, reject) => {
        const timer = setTimeout(() => {
          reject(new Error(`读取核心状态超时（${state}）。尚未启动 VPN，现有核心和账号已保留。`));
        }, Math.min(10000, deadline - Date.now()));
        tailscale.getStatus().then((value: string) => { clearTimeout(timer); resolve(value); },
          (error: Error) => { clearTimeout(timer); reject(error); });
      });
      if (!this.mounted) { throw new Error('VPN 开启已取消'); }
      const result = readControl(raw);
      this.applyStatus(result);
      state = result.backendState || 'unknown';
      if (!isAuthenticated(result)) { throw new Error(`账号需要重新认证（${state}），请先完成登录`); }
      if (state === 'Running') {
        const ipv4 = result.tailscaleIPs?.find((ip: string) => tailnetIPv4(ip));
        if (!ipv4) { throw new Error('未取得本机 Tailnet IPv4，请刷新后重试'); }
        return ipv4;
      }
      await new Promise<void>((resolve) => { setTimeout(resolve, Math.min(350, deadline - Date.now())); });
    }
    if (!this.mounted) { throw new Error('VPN 开启已取消'); }
    throw new Error(`等待核心连接超时（${state}）。尚未启动 VPN，账号已保留；请检查网络或查看核心状态。`);
  }

  private async setVpn(enabled: boolean): Promise<void> {
    if (this.busy || this.vpnChanging || (enabled === this.vpnRunning() && !this.vpnNeedsCleanup)) { return; }
    this.busy = true; this.vpnChanging = true; this.message = '';
    let handedOff: boolean = false;
    try {
      if (this.refreshTask) { await this.refreshTask.catch((_error: Error) => {}); }
      if (!this.mounted) { return; }
      if (vpnSdkPending()) { throw new Error('Previous VPN SDK operation is still pending'); }
      if (enabled) {
        if (this.vpnNeedsCleanup) { throw new Error('请先关闭 VPN，完成上一次清理'); }
        if (!isAuthenticated(this.status) || !this.appContext) { throw new Error('请先完成登录'); }
        const ipv4 = await this.waitForVpnReady();
        if (!this.mounted) { return; }
        this.progress = '正在将核心交给 VPN 服务…';
        readControl(await tailscale.close());
        handedOff = true;
        const id = `${Date.now()}-${Math.floor(Math.random() * 1000000000)}`;
        this.vpnRequestId = id;
        this.vpnNeedsCleanup = true;
        const port = new PlatformSessionRequest(this.appContext.filesDir, id, ipv4, this.hostname);
        await startVpnSession(port, id, () => !this.mounted, (stage: string) => {
          if (this.mounted) { this.progress = `正在连接 VPN：${stage}`; }
        });
        readControl(await boundedVpn(tailscale.start(this.dataDir, this.hostname), 10000, 'Connect VPN LocalAPI'));
        if (!this.mounted) { return; }
        await this.loadData();
        if (!this.vpn.connected) { throw new Error('VPN 服务尚未确认数据通路已启动'); }
        this.vpnNeedsCleanup = false;
        this.message = 'VPN 已开启。请通过 100.x 地址测试其他设备的服务。';
      } else {
        this.vpnNeedsCleanup = true;
        this.progress = '正在断开 VPN 并恢复普通网络…';
        await this.disconnectVpn();
        if (this.mounted) { await this.loadData(); this.message = 'VPN 已关闭，登录已保留。'; }
      }
    } catch (error) {
      if (this.mounted) {
        if (error instanceof VpnSessionError) { this.vpnNeedsCleanup = !error.cleanupConfirmed; }
        if (!enabled || handedOff || this.vpnNeedsCleanup) {
          this.vpn.ok = false; this.vpn.state = 'error'; this.vpn.error = `${error}`;
        }
        this.message = `VPN 操作失败：${error}`;
        // Startup denial/failure must not make normal account operations
        // unusable. The lease prevents reopening while cleanup is unfinished.
        if (!this.vpnNeedsCleanup && handedOff) {
          try { readControl(await tailscale.close()); readControl(await tailscale.start(this.dataDir, this.hostname)); }
          catch (restoreError) { this.message += `；核心恢复：${restoreError}`; }
        } else if (this.vpnNeedsCleanup) { this.message += '；尚未确认关闭，请再次关闭开关，或在系统 VPN 设置中断开。'; }
      }
    } finally { this.busy = false; this.vpnChanging = false; this.scheduleLoginRefresh(); this.scheduleVpnRefresh(); }
  }

  private async restoreSession(): Promise<void> {
    this.restoringSession = true;
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
    } finally { this.restoringSession = false; this.busy = false; this.scheduleLoginRefresh(); }
  }

  private async refreshData(silent: boolean = false): Promise<void> {
    if (this.busy || !this.mounted) { return; }
    if (this.refreshTask) { await this.refreshTask.catch((_error: Error) => {}); return; }
    if (!silent) {
      this.busy = true;
      this.progress = '正在更新状态与设备…';
      this.message = '';
    }
    this.refreshTask = this.loadData(silent);
    try { await this.refreshTask; }
    catch (error) {
      if (this.mounted) {
        this.message = `刷新失败：${error}`;
        this.peers = [];
        this.selectedPeer = undefined;
        this.lastUpdated = '';
      }
    } finally {
      this.refreshTask = undefined;
      if (!silent) { this.busy = false; }
      this.scheduleLoginRefresh();
      this.scheduleVpnRefresh();
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
      if (this.refreshTask) { await this.refreshTask.catch((_error: Error) => {}); }
      if (!this.mounted) { return; }
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
      if (this.refreshTask) { await this.refreshTask.catch((_error: Error) => {}); }
      if (!this.mounted) { return; }
      if (this.vpnRunning()) { await this.disconnectVpn(); }
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
      if (this.refreshTask) { await this.refreshTask.catch((_error: Error) => {}); }
      if (!this.mounted) { return; }
      if (this.vpnRunning() && (operation === 'close' || operation === 'start')) {
        throw new Error('VPN 运行期间请使用主界面开关管理核心');
      }
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
        this.output = `${safeOutput(raw)}\nVPN：\n${safeOutput(await tailscale.getVpnStatus())}`;
        this.applyStatus(readControl(raw));
      } else { this.output = safeOutput(await tailscale.diagnostics(this.dataDir)); }
    } catch (error) { this.output = `诊断失败：${error}`; }
    finally { this.busy = false; }
  }

  private confirmVpnProbe(): void {
    if (this.vpnRunning() || this.vpnChanging || vpnSdkPending()) { this.message = '请先关闭 VPN 再运行能力检查。'; return; }
    this.getUIContext().showAlertDialog({
      title: '验证系统 VPN 能力？',
      message: '系统将请求 VPN 授权，可能替换其他正在使用的 VPN。此检查仅验证网卡和网络保护接口，不接管 Tailnet 或默认路由，完成后自动关闭。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '开始检查', action: () => { this.runVpnProbe(); } }
    });
  }

  private async runVpnProbe(): Promise<void> {
    if (this.vpnRunning() || this.vpnChanging || vpnSdkPending()) { this.message = '请先关闭 VPN 再运行能力检查。'; return; }
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
      if (this.refreshTask) { await this.refreshTask.catch((_error: Error) => {}); }
      if (!this.mounted) { return; }
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
        this.message = report.ok ? (report.warning ?
          '基础接口检查通过；元数据查询受限，数据包读写及 Tailnet 数据通路尚未验证。' :
          '系统 VPN 能力检查通过；尚未验证 Tailnet 数据通路。') : '系统 VPN 能力检查失败，详见结果。';
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
      if (this.vpnRunning()) {
        Button(this.vpnNeedsCleanup ? '确认关闭 VPN' : '关闭 VPN')
          .fontColor(BLUE).backgroundColor('#E2F0FF').width('100%').margin({ bottom: 12 })
          .enabled(!this.busy).onClick(() => { this.setVpn(false); })
      }
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
      Text(this.vpnRunning() ? (this.vpn.connected ? '已登录 · VPN 已开启' : '已登录 · VPN 连接待确认') : '已登录 · VPN 未开启')
        .fontSize(12).fontColor('#427297')
    }.padding({ left: 12, right: 12, top: 8, bottom: 8 }).backgroundColor('#DEEEFB')
      .borderRadius(20).margin({ bottom: 18 }).alignSelf(ItemAlign.Start)
    Row({ space: 12 }) {
      Row() { this.icon($r('app.media.shield'), 26) }.width(48).height(48)
        .backgroundColor('#EDF2F6').borderRadius(24).justifyContent(FlexAlign.Center)
      Column({ space: 6 }) {
        Text('VPN').fontSize(17).fontWeight(FontWeight.Bold).fontColor(INK)
        Text(this.vpnChanging ? '正在切换…' : (this.vpnNeedsCleanup ? '关闭待确认' :
          (this.vpn.connected ? '已开启' : (this.vpn.state === 'connecting' ? '正在重连…' : (this.vpn.ok ? '已关闭' : '连接异常')))))
          .fontSize(13).fontColor(this.vpn.connected ? BLUE : MUTED)
        Text(this.vpn.connected ? `发送 ${this.vpn.txPackets} 包 · 接收 ${this.vpn.rxPackets} 包` : '仅连接 Tailnet IPv4 · 保留普通上网')
          .fontSize(11).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.vpnRunning() }).enabled(!this.busy && !this.vpnChanging)
        .onChange((enabled: boolean) => { this.setVpn(enabled); })
        .accessibilityText('连接或断开 Tailnet VPN')
    }.width('100%').padding(18).backgroundColor(Color.White).borderRadius(22).margin({ bottom: 22 })
    Text(`本机 IP：${this.status.tailscaleIPs?.join(' · ') || '暂无'}`)
      .width('100%').fontSize(12).fontColor(MUTED).margin({ bottom: 20 })
      .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
    this.notice()
    if (this.status.backendState !== 'Running') {
      Text('账号已保留，正在重新连接并同步设备…').fontSize(13).fontColor(MUTED)
        .width('100%').margin({ bottom: 16 })
    }
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
    // Stable unchanged rows; a changed row gets a new key so ForEach updates
    // its non-Observed PeerInfo builder instead of retaining stale text.
    ForEach(this.peers, (peer: PeerInfo) => { this.peerCard(peer) },
      (peer: PeerInfo) => `${peer.id}:${JSON.stringify(peer)}`)
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
    Text('3.2.1 Alpha · Tailscale Core 1.86.2').fontSize(12).fontColor(MUTED).margin({ top: 6 })
    Text('VPN Alpha：支持登录、在线设备和 Tailnet IPv4 互通。暂不支持 MagicDNS、IPv6、出口节点和子网路由。')
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
    Stack() {
    Scroll() {
      Column({ space: 8 }) {
        if (this.page === 'settings') { this.settings() }
        else if (this.page === 'diagnostics') { this.diagnostics() }
        else if (this.page === 'detail') { this.detail() }
        else if (this.restoringSession) {
          Column({ space: 16 }) {
            LoadingProgress().width(36).height(36).color(BLUE)
            Text('正在恢复账号…').fontSize(15).fontColor(MUTED)
          }.width('100%').padding({ top: 100, bottom: 100 })
        }
        else if (isAuthenticated(this.status)) { this.dashboard() }
        else { this.welcome() }
      }.width('100%').padding({ left: 24, right: 24, top: 24, bottom: 28 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
      .padding({ top: this.safeTop, bottom: this.safeBottom, left: this.safeLeft, right: this.safeRight })
    }.width('100%').height('100%')
      .linearGradient({ angle: 165, colors: [['#EAF4FF', 0], ['#F6FAFD', 0.6], ['#EEF6FC', 1]] })
  }
}
