import { common, Want, bundleManager } from '@kit.AbilityKit';
import { emitter } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import tailscale from 'libtailscale_napi.so';
import { requestVpnProbe } from '../vpn/VpnProbeClient';
import { PlatformVpnProbeRequest } from '../vpn/VpnProbePlatform';
import { VpnState, readVpnState, tailnetIPv4 } from '../vpn/VpnSessionModel';
import { vpnSdkPending } from '../vpn/VpnSessionClient';
import { ControlResult, PeerInfo, readControl, readPeers, isAuthenticated,
  accountName, tailnetName, peerName, peerAddress, osLabel, safeOutput } from './ClientModel';
import { SessionPreview, SessionPreviewStore, previewOf } from './SessionPreview';
import { readPlatformInfo } from './PlatformInfo';

import { fileIo } from '@kit.CoreFileKit';
import { NetworkServiceClient, NetworkServiceError, serviceDeadline } from '../vpn/NetworkServiceClient';
import { PlatformNetworkClient } from '../vpn/NetworkClientPlatform';
import { ServiceSnapshot } from '../vpn/NetworkServiceModel';
import { VpnRecoverySupervisor, RecoveryReport } from '../vpn/VpnRecoveryModel';
import { PlatformVpnRecovery } from '../vpn/VpnRecoveryPlatform';
export class ClientView {
  page: string = 'main';
  status: ControlResult = {};
  peers: PeerInfo[] = [];
  selectedPeer: PeerInfo | undefined = undefined;
  output: string = '';
  busy: boolean = false;
  progress: string = '';
  message: string = '';
  hostname: string = 'harmony-tsnet';
  peerFilter: string = '';
  showFilter: boolean = false;
  lastUpdated: string = '';
  awaitingLogin: boolean = false;
  restoringSession: boolean = true;
  startupPhase: string = 'checking';
  startupError: string = '';
  startupBlocking: boolean = true;
  previewAccount: ControlResult = {};
  peersStale: boolean = true;
  corePaused: boolean = false;
  appVersion: string = 'Alpha';
  vpn: VpnState = new VpnState();
  vpnChanging: boolean = false;
  vpnNeedsCleanup: boolean = false;
  vpnWanted: boolean = false;
  recovery: RecoveryReport = new RecoveryReport();
}

export class ClientController {
  public page: string = 'main';
  public status: ControlResult = {};
  public peers: PeerInfo[] = [];
  public selectedPeer: PeerInfo | undefined = undefined;
  public output: string = '';
  public busy: boolean = false;
  public progress: string = '';
  public message: string = '';
  public hostname: string = 'harmony-tsnet';
  public peerFilter: string = '';
  public showFilter: boolean = false;
  public lastUpdated: string = '';
  public awaitingLogin: boolean = false;
  public restoringSession: boolean = true;
  public startupPhase: string = 'checking';
  public startupError: string = '';
  private startupDismissed: boolean = false;
  private startupTimer: number = -1;
  public previewAccount: ControlResult = {};
  public peersStale: boolean = true;
  public corePaused: boolean = false;
  public appVersion: string = 'Alpha';
  public vpn: VpnState = new VpnState();
  public vpnChanging: boolean = false;
  public vpnNeedsCleanup: boolean = false;
  public recovery: RecoveryReport = new RecoveryReport();
  private supervisor: VpnRecoverySupervisor | undefined = undefined;
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
  private previewStore: SessionPreviewStore | undefined = undefined;
  private persistedPreview: string = '';
  private foregroundCallback = (_event: emitter.EventData): void => {
    this.foreground = true;
    if (!this.busy && !this.corePaused && this.hasAccount()) { this.recoverForeground(); }
  };
  private backgroundCallback = (_event: emitter.EventData): void => {
    this.foreground = false; this.stopPolling();
    if (this.vpnTimer !== -1) { clearTimeout(this.vpnTimer); this.vpnTimer = -1; }
  };

  attach(context: common.UIAbilityContext, observer: (view: ClientView) => void): void {
    this.mounted = true; this.foreground = true; this.lastView = undefined; this.observer = observer; this.appContext = context;
    this.dataDir = `${context.filesDir}/tailscale`;
    if (this.networkPort) { this.networkPort.update(context,this.hostname); }
    emitter.on('tailscale.foreground',this.foregroundCallback);
    emitter.on('tailscale.background',this.backgroundCallback);
    this.readAppVersion(); if (!this.busy) { this.restoreSession(); } this.notify();
  }
  bindRuntime(context: common.UIAbilityContext): void {
    this.appContext = context; this.dataDir = `${context.filesDir}/tailscale`;
    this.networkClient();
    this.supervisor?.start();
  }
  destroyRuntime(): void { this.supervisor?.stop(); }
  vpnWanted(): boolean { return this.supervisor?.wanted() === true; }

  async readAppVersion(): Promise<void> {
    try {
      const info = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (this.mounted) { this.appVersion = info.versionName; this.notify(); }
    } catch (_error) { /* Version lookup does not block account restoration. */ }
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.stopStartupTimer();
    this.stopPolling();
    if (this.vpnTimer !== -1) { clearTimeout(this.vpnTimer); this.vpnTimer = -1; }
    emitter.off('tailscale.foreground', this.foregroundCallback);
    emitter.off('tailscale.background', this.backgroundCallback); this.observer = undefined;
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

  hasAccount(): boolean { return isAuthenticated(this.status) || this.previewAccount.self !== undefined; }
  startupBlocking(): boolean { return !this.startupDismissed && this.startupPhase !== 'ready'; }
  vpnToggleEnabled(): boolean {
    return !this.busy && !this.vpnChanging && (this.vpnWanted() || this.vpnRunning() ||
      (this.startupPhase === 'ready' && !this.corePaused && this.vpn.networkMapReady &&
        tailnetIPv4(this.vpn.assignedIPv4)) ||
      (!this.corePaused && this.startupPhase === 'ready' && isAuthenticated(this.status) &&
        this.status.backendState === 'Running' && this.status.tailscaleIPs?.some(tailnetIPv4) === true));
  }
  private stopStartupTimer(): void {
    if (this.startupTimer !== -1) { clearTimeout(this.startupTimer); this.startupTimer = -1; }
  }
  private beginStartup(): void {
    this.stopStartupTimer();
    this.startupPhase = 'checking'; this.startupError = ''; this.startupDismissed = false;
    this.startupTimer = setTimeout(() => {
      this.startupTimer = -1;
      if (this.mounted && this.startupPhase === 'checking') {
        this.failStartup('本地网络服务初始化超过 30 秒，可重试或查看诊断。账号记录已保留。'); this.notify();
      }
    }, 30000);
  }
  private failStartup(message: string): void {
    if (this.startupPhase === 'ready') { return; }
    this.stopStartupTimer(); this.startupPhase = 'failed'; this.startupError = message;
  }
  private completeStartup(): void {
    this.stopStartupTimer(); this.startupPhase = 'ready'; this.startupError = '';
  }
  dismissStartup(): void { this.startupDismissed = true; this.notify(); }
  async retryStartup(): Promise<void> {
    if (this.busy) { return; }
    await this.restoreSession();
  }
  displayAccount(): ControlResult { return this.previewAccount.self ? this.previewAccount : this.status; }
  private savePreview(): void {
    const snapshot = this.hasAccount() ? previewOf(this.displayAccount(),
      this.peerFilter.trim() ? [] : this.peers, this.peerFilter.trim() ? '' : this.lastUpdated) : new SessionPreview();
    const text = JSON.stringify(snapshot);
    if (text === this.persistedPreview || !this.previewStore) { return; }
    try { this.previewStore.write(snapshot); this.persistedPreview = text; }
    catch (_error) { hilog.warn(0x5453, 'TailscaleProbe', 'Display cache write failed; live state is unchanged'); }
  }
  private clearAccountPreview(): void {
    this.previewAccount = {}; this.peers = []; this.selectedPeer = undefined;
    this.lastUpdated = ''; this.peersStale = true;
    this.savePreview();
  }
  connectionLabel(): string {
    if (this.corePaused) { return '账号已保留 · 网络连接已暂停'; }
    if (this.vpn.networkMapReady && this.status.backendState !== 'Running') {
      return this.vpn.connected ? 'VPN 已开启 · 通路状态同步中' : '网络配置已就绪 · VPN 未开启';
    }
    if (!isAuthenticated(this.status)) { return '已保存账号 · 正在核对连接状态'; }
    if (this.status.backendState !== 'Running') { return '账号已保留 · 正在连接'; }
    return this.vpnWanted() || this.vpnRunning() ? (this.vpn.connected ? '已登录 · VPN 已开启' :
      (this.recovery.phase === 'blocked' ? '已登录 · VPN 恢复待处理' : '已登录 · VPN 正在恢复')) : '已登录 · VPN 未开启';
  }

  displayHealth(): string[] {
    return (this.status.health || []).map((message: string) =>
      this.vpn.networkMapReady && message === 'Tailscale is starting. Please wait.' ?
        '网络配置已就绪，正在建立直连或中继通路。' : message);
  }

  private scheduleLoginRefresh(): void {
    this.stopPolling();
    if (!this.mounted) { return; }
    if (this.awaitingLogin && Date.now() >= this.loginDeadline) {
      this.awaitingLogin = false;
      this.message = '尚未确认登录。完成浏览器认证后，点击登录重试。'; this.notify();
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
    if (result.backendState === 'NeedsLogin' || result.backendState === 'NeedsMachineAuth') {
      this.completeStartup();
      this.clearAccountPreview();
      if (result.backendState === 'NeedsMachineAuth') { this.message = '设备需要管理员批准，请在 Tailscale 管理后台完成授权。'; }
      if (this.page === 'detail') { this.page = 'main'; }
    } else if (isAuthenticated(result)) {
      const previous = this.previewAccount.self;
      const current = result.self;
      const previousTailnet = this.previewAccount.tailnet?.magicDNSSuffix;
      const currentTailnet = result.tailnet?.magicDNSSuffix;
      if ((previous?.userLogin && current?.userLogin && previous.userLogin !== current.userLogin) ||
        (previous?.id && current?.id && previous.id !== current.id) ||
        (previousTailnet && currentTailnet && previousTailnet !== currentTailnet)) {
        this.previewAccount = {};
        this.peers = []; this.selectedPeer = undefined; this.lastUpdated = ''; this.peersStale = true;
      }
      const nextAccount: ControlResult = { self: result.self || this.previewAccount.self,
        tailnet: result.tailnet || this.previewAccount.tailnet,
        tailscaleIPs: result.tailscaleIPs?.length ? result.tailscaleIPs : this.previewAccount.tailscaleIPs };
      if (JSON.stringify(nextAccount) !== JSON.stringify(this.previewAccount)) { this.previewAccount = nextAccount; }
      this.savePreview();
    }
    if (isAuthenticated(result) && result.backendState === 'Running') {
      if (result.tailscaleIPs?.some(tailnetIPv4)) { this.completeStartup(); }
      this.awaitingLogin = false;
      this.restoreDeadline = 0;
      this.stopPolling();
    }
  }

  async loadData(silent: boolean = false): Promise<void> {
    let nextVpn: VpnState;
    if (this.networkStarted && this.network) {
      const snapshot = await this.network.observe();
      if (!snapshot) { throw new Error('网络服务记录缺失，请检查系统 VPN 状态'); }
      nextVpn = snapshot;
      if (this.mounted) { this.vpnNeedsCleanup = (snapshot.phase === 'cleanup_pending' || snapshot.phase === 'error') &&
        (!snapshot.detached || !snapshot.destroyed || !snapshot.descriptorClosed); }
    } else { nextVpn = readVpnState(await tailscale.getVpnStatus()); }
    if (!this.mounted) { return; }
    // Logs change independently of product state; don't redraw the dashboard
    // merely because the native log ring changed. Diagnostics fetch them on demand.
    if (this.vpn.ok !== nextVpn.ok || this.vpn.connected !== nextVpn.connected ||
      this.vpn.state !== nextVpn.state || this.vpn.ipv4 !== nextVpn.ipv4 ||
      this.vpn.txPackets !== nextVpn.txPackets || this.vpn.rxPackets !== nextVpn.rxPackets ||
      this.vpn.txBytes !== nextVpn.txBytes || this.vpn.rxBytes !== nextVpn.rxBytes ||
      this.vpn.error !== nextVpn.error || this.vpn.coreId !== nextVpn.coreId ||
      this.vpn.coreAlive !== nextVpn.coreAlive || this.vpn.attached !== nextVpn.attached ||
      this.vpn.networkMapReady !== nextVpn.networkMapReady || this.vpn.assignedIPv4 !== nextVpn.assignedIPv4) { this.vpn = nextVpn; }
    if (!this.vpn.ok) { throw new Error(this.vpn.error || 'VPN service unavailable'); }
    this.notify();
    const raw: string = await serviceDeadline(tailscale.getStatus(), 5000, '读取本地账号状态');
    if (!this.mounted) { return; }
    if (!silent) { this.output = safeOutput(raw); }
    this.applyStatus(readControl(raw));
    if (this.vpn.networkMapReady || (isAuthenticated(this.status) && this.status.backendState === 'Running')) {
      const peerRaw: string = await tailscale.onlinePeers(this.peerFilter.trim());
      if (!this.mounted) { return; }
      if (!silent) { this.output = safeOutput(peerRaw); }
      const nextPeers = readPeers(peerRaw);
      const changed = JSON.stringify(this.peers) !== JSON.stringify(nextPeers);
      if (changed) {
        this.peers = nextPeers;
        if (this.selectedPeer) { this.selectedPeer = nextPeers.find((peer: PeerInfo) => peer.id === this.selectedPeer?.id) || this.selectedPeer; }
      }
      if (changed || !silent || this.peersStale) { this.lastUpdated = new Date().toLocaleString(); }
      this.peersStale = false;
      this.savePreview();
    } else if (this.hasAccount()) {
      // Retain explicitly labelled historical data, not a live online claim.
      this.peersStale = true;
    }
    this.scheduleVpnRefresh();
  }

  private scheduleVpnRefresh(): void {
    if (this.vpnTimer !== -1) { clearTimeout(this.vpnTimer); this.vpnTimer = -1; }
    if (!this.mounted || !this.foreground || this.corePaused || (!this.vpnRunning() && !this.hasAccount())) { return; }
    this.vpnTimer = setTimeout(() => {
      this.vpnTimer = -1;
      if (this.foreground && !this.busy) { this.refreshData(true); }
      else { this.scheduleVpnRefresh(); }
    }, 5000);
  }

  vpnRunning(): boolean {
    return this.vpn.connected || this.vpnNeedsCleanup || (this.vpn.state === 'connecting' && tailnetIPv4(this.vpn.ipv4));
  }

  async disconnectVpn(): Promise<void> {
    this.networkClient();
    await this.supervisor?.setWanted(false, (message: string) => {
      if (this.mounted) { this.progress = message; this.notify(); }
    });
    if (this.mounted) { this.vpnNeedsCleanup = false; }
  }



  async setVpn(enabled: boolean): Promise<void> {
    if (enabled && this.startupPhase !== 'ready') {
      this.message = '连接尚未准备完成，请等待或重试连接。'; this.notify(); return;
    }
    if (this.busy || this.vpnChanging || (enabled === this.vpnWanted() && !this.vpnNeedsCleanup &&
      (enabled ? this.vpn.connected : !this.vpnRunning()))) { return; }
    this.busy = true; this.vpnChanging = true; this.message = ''; this.notify();
    try {
      // OFF must revoke recovery before waiting for an unrelated peer refresh.
      if (!enabled) { await this.disconnectVpn(); }
      if (!this.mounted) { return; }
      if (enabled && !this.hasAccount() && !this.vpn.networkMapReady) { throw new Error('请先完成登录'); }
      this.networkClient();
      if (enabled) { await this.supervisor?.setWanted(true, (message: string) => {
        if (this.mounted) { this.progress = message; this.notify(); }
      }); }
      if (!this.mounted) { return; }
      this.corePaused = false;
      this.vpnNeedsCleanup = false;
      this.message = enabled ? 'VPN 已开启。' : 'VPN 已关闭，核心和登录已保留。';
      try { await this.loadData(true); }
      catch (e) { if (this.mounted) { this.peersStale = true; this.message += `设备同步暂未完成：${e}`; } }
    } catch (e) {
      if (this.mounted) {
        this.vpnNeedsCleanup = e instanceof NetworkServiceError ? !e.cleanupConfirmed : false;
        if (this.vpnNeedsCleanup) {
          const uncertain = new VpnState();
          uncertain.ok=false;uncertain.state='error';uncertain.error=`${e}`;
          uncertain.coreId=this.vpn.coreId;uncertain.coreAlive=this.vpn.coreAlive;
          uncertain.ipv4=this.vpn.ipv4;uncertain.attached=this.vpn.attached;this.vpn=uncertain;
        }
        this.message = enabled && this.vpnWanted() ? `VPN 暂未连接：${e}；${this.recovery.phase === 'blocked' ? '自动恢复已暂停' : '将自动重试'}` : `VPN 操作失败：${e}`;
        if (this.vpnNeedsCleanup) { this.message += '；关闭状态待确认，请重试关闭或检查系统 VPN 设置。'; }
        // A live authentication result, never the display cache, can revoke the view.
        try { this.applyStatus(readControl(await tailscale.getStatus())); } catch (_error) {}
      }
    } finally {
      this.busy = false; this.vpnChanging = false;
      if (this.mounted) {
        this.scheduleLoginRefresh(); this.scheduleVpnRefresh(); this.notify();
      }
    }
  }

  async restoreSession(): Promise<void> {
    if (this.corePaused) { this.restoringSession = false; this.completeStartup(); this.notify(); return; }
    this.beginStartup();
    this.restoringSession = true;
    if (this.appContext) {
      this.previewStore = new SessionPreviewStore(this.appContext.filesDir);
      const saved = this.previewStore.read();
      if (saved) {
        this.previewAccount = saved.account; this.peers = saved.peers;
        this.lastUpdated = saved.updatedAt; this.peersStale = true;
        this.persistedPreview = JSON.stringify(saved);
        this.notify();
        // The first frame can display saved metadata while native startup runs.
        this.restoringSession = false;
      }
    }
    let savedState = false;
    try { savedState = fileIo.accessSync(`${this.dataDir}/tailscaled.state`); } catch (_error) {}
    if (!this.hasAccount() && !savedState && !this.networkPort?.read()?.serviceReady) {
      this.completeStartup();
      this.restoringSession = false; this.busy = false; this.restoreDeadline = 0; this.notify(); return;
    }
    this.busy = true;
    this.restoreDeadline = Date.now() + 15000;
    this.progress = '正在恢复网络服务…'; this.notify();
    try {
      await this.ensureService();
      if (!this.mounted) { return; }
      // The overlay covers local bootstrap only, not a remote control/DERP
      // handshake. Account and device updates run independently below.
      this.completeStartup();
    } catch (error) {
      if (this.mounted) {
        this.restoreDeadline = 0;
        this.peersStale = true;
        this.message = `恢复状态失败：${error}`;
        this.failStartup(this.message);
      }
    } finally {
      this.busy = false;
      if (this.mounted) { this.restoringSession = false; this.scheduleLoginRefresh(); this.notify(); }
    }
    if (this.mounted && this.startupPhase === 'ready') { await this.refreshData(true); }
  }

  async refreshData(silent: boolean = false): Promise<void> {
    if (this.busy || !this.mounted) { return; }
    if (this.refreshTask) { await this.refreshTask.catch((_error: Error) => {}); return; }
    if (!silent) {
      this.busy = true;
      this.progress = '正在更新状态与设备…';
      this.message = ''; this.notify();
    }
    this.refreshTask = this.loadData(silent);
    try { await this.refreshTask; }
    catch (error) {
      if (this.mounted) {
        this.message = `刷新失败：${error}`;
        this.failStartup(this.message);
        this.peersStale = true;
      }
    } finally {
      this.refreshTask = undefined;
      if (!silent) { this.busy = false; }
      this.scheduleLoginRefresh();
      this.scheduleVpnRefresh(); this.notify();
    }
  }

  async openSystemBrowser(url: string): Promise<void> {
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

  async login(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.notify();
    this.message = '';
    this.progress = '正在获取安全登录链接…';
    try {
      if (this.refreshTask) { await this.refreshTask.catch((_error: Error) => {}); }
      if (!this.mounted) { return; }
      await this.ensureService();
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
    finally { this.busy = false; this.scheduleLoginRefresh(); this.notify(); }
  }



  async logout(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.progress = '正在退出登录…';
    try {
      if (this.vpnRunning() || this.vpnWanted()) { await this.disconnectVpn(); }
      if (this.refreshTask) { await this.refreshTask.catch((_error: Error) => {}); }
      if (!this.mounted) { return; }
      const raw: string = await tailscale.logout();
      if (!this.mounted) { return; }
      this.output = safeOutput(raw);
      const result: ControlResult = readControl(raw);
      if (isAuthenticated(result)) { throw new Error('控制面仍报告已登录，请刷新后重试'); }
      this.applyStatus(result);
      this.clearAccountPreview();
      this.awaitingLogin = false;
      this.restoreDeadline = 0;
      this.stopPolling();
      this.page = 'main';
      this.message = '已退出登录。';
    } catch (error) { this.message = `退出失败：${error}`; }
    finally { this.busy = false; this.notify(); }
  }

  async diagnostic(operation: string): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.progress = '正在执行诊断…';
    try {
      if (this.refreshTask) { await this.refreshTask.catch((_error: Error) => {}); }
      if (!this.mounted) { return; }
      if (this.vpnRunning() && (operation === 'close' || operation === 'start')) {
        throw new Error('VPN 运行期间请使用主界面开关管理核心');
      }
      if (operation === 'versions') { this.output = `${safeOutput(tailscale.getVersion())}\n系统信息：\n${JSON.stringify(readPlatformInfo())}`; }
      else if (operation === 'logs') { this.output = safeOutput(tailscale.getLogs()); }
      else if (operation === 'browser') {
        await this.openSystemBrowser('https://login.tailscale.com/');
        this.output = '系统浏览器已成功唤起。';
      } else if (operation === 'close') {
        if (this.vpnWanted()) { await this.disconnectVpn(); }
        await this.networkClient().shutdown(); this.networkStarted = false;
        this.output = '网络服务已停止；账号凭据未注销。';
        // Closing a runtime is not revoking credentials. Keep the saved view.
        if (isAuthenticated(this.status)) {
          this.previewAccount = previewOf(this.status, [], '').account; this.savePreview();
        }
        this.corePaused = true; this.peersStale = true;
        this.status = { ok: true, lifecycleState: 'closed' };
        this.awaitingLogin = false;
        this.restoreDeadline = 0;
        this.stopPolling();
        if (this.vpnTimer !== -1) { clearTimeout(this.vpnTimer); this.vpnTimer = -1; }
      } else if (operation === 'start') {
        await this.ensureService(); this.output = '网络服务已就绪。';
        this.corePaused = false;
        await this.loadData(true);
      } else if (operation === 'status') {
        const raw: string = await tailscale.getStatus();
        const snapshot = this.networkPort?.read();
        this.output = `${safeOutput(raw)}\nVPN：\n${safeOutput(await tailscale.getVpnStatus())}\n网络服务：\n${safeOutput(JSON.stringify(snapshot || {}))}\n自动恢复：\n${safeOutput(JSON.stringify(this.recovery))}`;
        this.applyStatus(readControl(raw));
      } else { this.output = safeOutput(await tailscale.diagnostics(this.dataDir)); }
    } catch (error) { this.output = `诊断失败：${error}`; }
    finally { this.busy = false; this.notify(); }
  }

  canProbe(): boolean {
    if (this.networkStarted || this.vpnRunning() || this.vpnChanging || vpnSdkPending() || this.network?.pending()) {
      this.message = '请先停止网络服务，再运行能力检查。'; this.notify(); return false;
    }
    return true;
  }

  async runVpnProbe(): Promise<void> {
    if (!this.canProbe()) { return; }
    if (this.busy || !this.mounted || !this.appContext) { return; }
    this.busy = true; this.notify();
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
          if (raw) { this.output = safeOutput(raw); } this.notify();
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
    } finally { this.busy = false; this.progress = ''; this.notify(); }
  }




  private network: NetworkServiceClient | undefined = undefined;
  private networkPort: PlatformNetworkClient | undefined = undefined;
  private networkStarted: boolean = false;
  private async recoverForeground(): Promise<void> {
    const previousCore = this.vpn.coreId;
    try {
      await this.ensureService();
      if (!this.mounted) { return; }
      if (previousCore && this.vpn.coreId!==previousCore && !this.vpn.connected) {
        this.message=this.vpnWanted() ? '网络服务已恢复，正在自动恢复 VPN。' : '网络服务已恢复，VPN 未开启。';
      }
      await this.refreshData(true);
    } catch(e) {
      if(this.mounted){this.peersStale=true;this.message=`网络服务恢复失败：${e}`;this.notify();}
    }
  }
  private lastView: ClientView | undefined = undefined;
  private observer: ((view: ClientView) => void) | undefined = undefined;
  private networkClient(): NetworkServiceClient {
    if (!this.appContext) { throw new Error('UI context unavailable'); }
    if (!this.networkPort) { this.networkPort = new PlatformNetworkClient(this.appContext,this.hostname); }
    else { this.networkPort.update(this.appContext,this.hostname); }
    if (!this.network) { this.network = new NetworkServiceClient(this.networkPort); }
    if (!this.supervisor) {
      this.supervisor = new VpnRecoverySupervisor(new PlatformVpnRecovery(this.network, this.networkPort, this.appContext.filesDir,
        (snapshot: ServiceSnapshot) => {
          this.networkStarted = snapshot.serviceReady;
          // Updating runtime state is allowed without a page; notify() never
          // sends an unmounted observer a result.
          this.vpn = snapshot;
          this.vpnNeedsCleanup = (!snapshot.detached || !snapshot.destroyed || !snapshot.descriptorClosed) && !snapshot.ok;
          this.notify();
        }, (report: RecoveryReport) => {
          const changed = this.recovery.phase !== report.phase || this.recovery.error !== report.error;
          const next = new RecoveryReport(); next.phase = report.phase; next.attempts = report.attempts;
          next.nextRetryAt = report.nextRetryAt; next.interruptedAt = report.interruptedAt;
          next.recoveredAt = report.recoveredAt; next.lastRecoveryMs = report.lastRecoveryMs; next.error = report.error;
          this.recovery = next;
          if (report.phase === 'retry_wait' || report.phase === 'blocked') {
            this.vpn.connected = false;
          }
          if (changed && report.phase !== 'off') {
            if (report.phase === 'connected') { this.message = 'VPN 已恢复。'; }
            else if (report.phase === 'blocked') { this.message = report.error; }
            else { this.message = `VPN 正在自动恢复：${report.error}`; }
          }
          this.notify();
        }));
      this.supervisor.start();
    }
    return this.network;
  }
  private async ensureService(): Promise<void> {
    const snapshot = await this.networkClient().ensure((message: string) => {
      if (this.mounted) { this.progress = message; this.notify(); }
    });
    this.networkStarted = snapshot.serviceReady;
    if (this.mounted) { this.vpn = snapshot; this.corePaused = false; }
  }
  notify(): void {
    if (!this.mounted || !this.observer) { return; }
    const view = new ClientView();
    view.page = this.page;
    view.status = this.status;
    view.peers = this.peers;
    view.selectedPeer = this.selectedPeer;
    view.output = this.output;
    view.busy = this.busy;
    view.progress = this.progress;
    view.message = this.message;
    view.hostname = this.hostname;
    view.peerFilter = this.peerFilter;
    view.showFilter = this.showFilter;
    view.lastUpdated = this.lastUpdated;
    view.awaitingLogin = this.awaitingLogin;
    view.restoringSession = this.restoringSession;
    view.startupPhase = this.startupPhase; view.startupError = this.startupError;
    view.startupBlocking = this.startupBlocking();
    view.previewAccount = this.previewAccount;
    view.peersStale = this.peersStale;
    view.corePaused = this.corePaused;
    view.appVersion = this.appVersion;
    view.vpn = this.vpn;
    view.vpnChanging = this.vpnChanging;
    view.vpnNeedsCleanup = this.vpnNeedsCleanup;
    view.vpnWanted = this.vpnWanted(); view.recovery = this.recovery;

    const previous = this.lastView;
    if (previous && previous.page === view.page &&
      previous.status === view.status &&
      previous.peers === view.peers &&
      previous.selectedPeer === view.selectedPeer &&
      previous.output === view.output &&
      previous.busy === view.busy &&
      previous.progress === view.progress &&
      previous.message === view.message &&
      previous.hostname === view.hostname &&
      previous.peerFilter === view.peerFilter &&
      previous.showFilter === view.showFilter &&
      previous.lastUpdated === view.lastUpdated &&
      previous.awaitingLogin === view.awaitingLogin &&
      previous.restoringSession === view.restoringSession &&
      previous.startupPhase === view.startupPhase && previous.startupError === view.startupError &&
      previous.startupBlocking === view.startupBlocking &&
      previous.previewAccount === view.previewAccount &&
      previous.peersStale === view.peersStale &&
      previous.corePaused === view.corePaused &&
      previous.appVersion === view.appVersion &&
      previous.vpn === view.vpn &&
      previous.vpnChanging === view.vpnChanging &&
      previous.vpnNeedsCleanup === view.vpnNeedsCleanup && previous.vpnWanted === view.vpnWanted &&
      previous.recovery === view.recovery) { return; }
    this.lastView = view;
    this.observer(view);
  }
}
let shared: ClientController | undefined = undefined;
export function getClientController(): ClientController {
  if (!shared) { shared = new ClientController(); }
  return shared;
}
