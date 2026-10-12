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
import { getAccountSession } from './AccountSessionPlatform';

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
  peersUpdating: boolean = false;
  peersError: string = '';
  vpnProgress: string = '';
  vpnMessage: string = '';
  diagnosticBusy: boolean = false;
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
  public peersUpdating: boolean = false;
  public peersError: string = '';
  public vpnProgress: string = '';
  public vpnMessage: string = '';
  public diagnosticBusy: boolean = false;
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
  private dataEpoch: number = 0;
  private vpnSequence: number = 0;
  private vpnStopping: boolean = false;
  private accountStarting: boolean = false;
  private refreshTask: Promise<void> | undefined = undefined;
  private previewStore: SessionPreviewStore | undefined = undefined;
  private persistedPreview: string = '';
  private foregroundCallback = (_event: emitter.EventData): void => {
    this.foreground = true;
    if (!this.busy && !this.corePaused && (this.hasAccount() || this.awaitingLogin)) { this.recoverForeground(); }
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
  startupBlocking(): boolean { return false; }
  vpnToggleEnabled(): boolean {
    if (this.vpnWanted() || this.vpnRunning()) { return !this.vpnStopping; }
    return !this.busy && !this.vpnChanging && this.hasAccount() && !this.corePaused &&
      this.status.backendState !== 'NeedsLogin' && this.status.backendState !== 'NeedsMachineAuth';
  }
  vpnLabel(): string {
    if (this.vpnStopping) { return '正在关闭 VPN…'; }
    if (this.vpnChanging) { return this.vpnProgress || '正在连接 VPN…'; }
    if (this.vpnNeedsCleanup) { return '关闭待确认'; }
    if (this.vpn.connected) { return '已开启'; }
    if (this.vpnWanted()) { return this.recovery.phase === 'blocked' ? '需要重新连接' : '正在恢复连接…'; }
    return this.recovery.phase === 'failed' ? '连接失败' : '未开启';
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
    if(this.corePaused){return '账号已保留 · 同步已暂停';}
    if (this.vpn.connected) { return 'VPN 已开启'; }
    if (this.vpnWanted()) { return this.recovery.phase === 'blocked' ? 'VPN 需要重新连接' : 'VPN 正在恢复'; }
    if (isAuthenticated(this.status)) { return '已登录 · VPN 未开启'; }
    if (this.hasAccount()) { return '已保存账号 · VPN 未开启'; }
    return this.awaitingLogin ? '等待浏览器认证' : '尚未登录';
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
    if (isAuthenticated(result)) {
      if (result.tailscaleIPs?.some(tailnetIPv4)) { this.completeStartup(); }
      this.awaitingLogin = false;
      this.restoreDeadline = 0;
      this.stopPolling();
    }
  }

  async loadData(silent: boolean = false): Promise<void> {
    const epoch = this.dataEpoch;
    const filter = this.peerFilter.trim();
    let nextVpn: VpnState;
    if (this.networkStarted && this.network) {
      const snapshot = await this.network.observe();
      if (!snapshot) { throw new Error('网络服务记录缺失，请检查系统 VPN 状态'); }
      nextVpn = snapshot;
      if (this.mounted) { this.vpnNeedsCleanup = (snapshot.phase === 'cleanup_pending' || snapshot.phase === 'error') &&
        (!snapshot.detached || !snapshot.destroyed || !snapshot.descriptorClosed); }
    } else { nextVpn = readVpnState(await tailscale.getVpnStatus()); }
    if (!this.mounted || epoch !== this.dataEpoch) { return; }
    // Logs change independently of product state; don't redraw the dashboard
    // merely because the native log ring changed. Diagnostics fetch them on demand.
    if (this.vpn.ok !== nextVpn.ok || this.vpn.connected !== nextVpn.connected ||
      this.vpn.state !== nextVpn.state || this.vpn.ipv4 !== nextVpn.ipv4 ||
      this.vpn.txPackets !== nextVpn.txPackets || this.vpn.rxPackets !== nextVpn.rxPackets ||
      this.vpn.txBytes !== nextVpn.txBytes || this.vpn.rxBytes !== nextVpn.rxBytes ||
      this.vpn.error !== nextVpn.error || this.vpn.coreId !== nextVpn.coreId ||
      this.vpn.coreHost !== nextVpn.coreHost || this.vpn.coreAlive !== nextVpn.coreAlive || this.vpn.attached !== nextVpn.attached ||
      this.vpn.networkMapReady !== nextVpn.networkMapReady || this.vpn.assignedIPv4 !== nextVpn.assignedIPv4) { this.vpn = nextVpn; }
    if (!this.vpn.ok) { throw new Error(this.vpn.error || 'VPN service unavailable'); }
    this.notify();
    const raw: string = await serviceDeadline(tailscale.getStatus(), 5000, '读取本地账号状态');
    if (!this.mounted || epoch !== this.dataEpoch) { return; }
    if (!silent) { this.output = safeOutput(raw); }
    this.applyStatus(readControl(raw));
    if (this.vpn.networkMapReady || (isAuthenticated(this.status) && this.status.backendState === 'Running')) {
      const peerRaw: string = await serviceDeadline(tailscale.onlinePeers(filter),5000,'读取设备列表');
      if (!this.mounted || epoch !== this.dataEpoch) { return; }
      if (!silent) { this.output = safeOutput(peerRaw); }
      if (filter !== this.peerFilter.trim()) { return; }
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
    // OFF is also cancellation and must bypass an outstanding ON/read.
    if (!enabled && this.vpnStopping) { return; }
    if (enabled && (this.busy || this.vpnChanging)) { return; }
    if(enabled&&this.vpnNeedsCleanup){this.vpnMessage='请先重试关闭，确认旧网卡清理完成';this.notify();return;}
    if (enabled && !this.hasAccount()) { this.vpnMessage='请先登录 Tailscale';this.notify();return; }
    if (enabled && (this.status.backendState === 'NeedsLogin' || this.status.backendState === 'NeedsMachineAuth')) {
      this.vpnMessage = this.status.backendState === 'NeedsMachineAuth' ? '设备需要管理员批准' : '登录已失效，请重新登录';this.notify();return;
    }
    if (enabled && this.vpn.connected && this.vpnWanted()) { return; }
    const sequence=++this.vpnSequence; this.dataEpoch++;
    this.vpnChanging=true;this.vpnStopping=!enabled;this.vpnMessage='';
    this.vpnProgress=enabled?'正在准备连接…':'正在关闭 VPN…';this.notify();
    this.networkClient();
    try {
      await this.supervisor?.setWanted(enabled,(message:string)=>{
        if(this.mounted && sequence===this.vpnSequence){this.vpnProgress=message;this.notify();}
      });
      if (sequence!==this.vpnSequence) { return; }
      this.corePaused=false;this.vpnNeedsCleanup=false;
      this.vpnMessage=enabled?'VPN 已开启。':'VPN 已关闭，账号已保留。';
    } catch(e) {
      if(sequence!==this.vpnSequence){return;}
      this.vpnNeedsCleanup=e instanceof NetworkServiceError && !e.cleanupConfirmed;
      this.vpnMessage=`${enabled?'连接失败':'关闭失败'}：${e}`;
      if(this.vpnNeedsCleanup){this.vpnMessage+='；关闭状态待确认，可重试关闭。';}
      if (enabled && !this.vpnWanted() && !this.vpnNeedsCleanup) {
        try { await this.ensureAccount();
          const raw: string=await serviceDeadline<string>(tailscale.getStatus(),5000,'确认账号状态');
          if(this.mounted&&sequence===this.vpnSequence){this.applyStatus(readControl(raw));}
        } catch(_restoreError) { /* Keep display; exclusive lease still protects credentials. */ }
      }
    } finally {
      if(sequence===this.vpnSequence){
        this.vpnChanging=false;this.vpnStopping=false;this.vpnProgress='';
        if(this.mounted){this.scheduleVpnRefresh();this.notify();this.refreshData(true);}
      }
    }
  }

  async restoreSession(): Promise<void> {
    if(this.accountStarting){return;}
    if (this.corePaused) { this.restoringSession=false;this.completeStartup();this.notify();return; }
    this.accountStarting=true;this.beginStartup();this.restoringSession=true;
    if (this.appContext) {
      this.previewStore=new SessionPreviewStore(this.appContext.filesDir);
      const saved=this.previewStore.read();
      if(saved){this.previewAccount=saved.account;this.peers=saved.peers;this.lastUpdated=saved.updatedAt;
        this.peersStale=true;this.persistedPreview=JSON.stringify(saved);this.notify();}
    }
    let savedState=false;
    try{savedState=fileIo.accessSync(`${this.dataDir}/tailscaled.state`);}catch(_error){}
    if(!this.hasAccount()&&!savedState&&!this.networkPort?.read()?.serviceReady){
      this.completeStartup();this.restoringSession=false;this.accountStarting=false;this.notify();return;
    }
    this.restoreDeadline=Date.now()+15000;this.notify();
    try{
      await this.ensureAccount();
      if(this.mounted){this.completeStartup();}
    }catch(e){
      if(this.mounted){this.peersStale=true;this.message=`账号服务恢复失败：${e}`;this.failStartup(this.message);}
    }finally{
      this.accountStarting=false;
      if(this.mounted){this.restoringSession=false;this.scheduleLoginRefresh();this.notify();}
    }
    if(this.mounted&&this.startupPhase==='ready'){await this.refreshData(true);}
  }

  async refreshData(silent: boolean = false): Promise<void> {
    if (!this.mounted || this.corePaused) { return; }
    if (this.refreshTask) { return; }
    const epoch=this.dataEpoch;
    this.peersUpdating=true;this.peersError='';this.notify();
    this.refreshTask=this.loadData(silent);
    try{await this.refreshTask;}
    catch(e){
      if(this.mounted&&epoch===this.dataEpoch){this.peersError=`设备更新暂未完成：${e}`;this.peersStale=true;}
    }finally{
      this.refreshTask=undefined;this.peersUpdating=false;
      if(this.mounted){this.scheduleLoginRefresh();this.scheduleVpnRefresh();this.notify();}
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
    this.busy = true;this.dataEpoch++; this.notify();
    this.message = '';
    this.progress = '正在获取安全登录链接…';
    try {
      if (!this.mounted) { return; }
      await this.ensureAccount();
      if (!this.mounted) { return; }
      const raw: string = await tailscale.login();
      if (!this.mounted) { return; }
      this.output = safeOutput(raw);
      const result: ControlResult = readControl(raw);
      this.applyStatus(result);
      if (isAuthenticated(result)) { this.refreshData(true); }
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



  cancelLogin(): void {
    this.awaitingLogin=false;this.loginDeadline=0;this.stopPolling();
    this.message='已停止等待登录结果，可重新发起登录。';this.notify();
  }
  vpnCanRetry(): boolean {
    return !this.vpnChanging && !this.vpnNeedsCleanup && this.hasAccount() &&
      (this.recovery.phase==='failed' || this.recovery.phase==='blocked');
  }

  async logout(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.dataEpoch++;this.vpnSequence++;this.progress = '正在退出登录…';
    try {
      if (this.vpnRunning() || this.vpnWanted()) { await this.disconnectVpn(); }
      this.vpnChanging=false;this.vpnStopping=false;
      if (!this.mounted) { return; }
      await this.ensureAccount();
      const raw: string = await tailscale.logout();
      if (!this.mounted) { return; }
      this.output = safeOutput(raw);
      const result: ControlResult = readControl(raw);
      if (isAuthenticated(result)) { throw new Error('控制面仍报告已登录，请刷新后重试'); }
      this.applyStatus(result);
      this.dataEpoch++;this.clearAccountPreview();
      this.awaitingLogin = false;
      this.restoreDeadline = 0;
      this.stopPolling();
      this.page = 'main';
      this.message = '已退出登录。';
    } catch (error) { this.message = `退出失败：${error}`; }
    finally { this.busy = false; this.notify(); }
  }

  async diagnostic(operation: string): Promise<void> {
    if (this.diagnosticBusy) { return; }
    this.diagnosticBusy = true;
    this.progress = '正在执行诊断…';
    try {
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
        if(this.networkStarted){await this.networkClient().shutdown();}else{readControl(await tailscale.close());await getAccountSession().stopMonitor();}
        this.dataEpoch++;this.networkStarted = false;
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
        await this.ensureAccount(); this.output = '账号网络服务已就绪（VPN 未自动开启）。';
        this.corePaused = false;
        this.refreshData(true);
      } else if (operation === 'status') {
        const raw: string = await tailscale.getStatus();
        const snapshot = this.networkPort?.read();
        this.output = `${safeOutput(raw)}\nVPN：\n${safeOutput(await tailscale.getVpnStatus())}\n网络服务：\n${safeOutput(JSON.stringify(snapshot || {}))}\n自动恢复：\n${safeOutput(JSON.stringify(this.recovery))}`;
        this.applyStatus(readControl(raw));
      } else { this.output = safeOutput(await tailscale.diagnostics(this.dataDir)); }
    } catch (error) { this.output = `诊断失败：${error}`; }
    finally { this.diagnosticBusy = false; this.notify(); }
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
      await this.ensureAccount();
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
          if(changed && report.phase !== 'off') {
            this.vpnMessage = report.phase === 'connected' ? 'VPN 已开启。' :
              report.phase === 'blocked' || report.phase === 'failed' ? report.error : this.vpnChanging ? '' : `连接恢复中：${report.error}`;
          }
          this.notify();
        }));
      this.supervisor.start();
    }
    return this.network;
  }
  private async ensureAccount(): Promise<void> {
    if(!this.appContext){throw new Error('UI context unavailable');}
    await getAccountSession().ensure(this.dataDir,this.hostname);
    const live=readVpnState(await tailscale.getVpnStatus());
    this.networkClient();
    if(live.coreHost==='vpn'){
      const snapshot=await this.network?.observe();
      if(!snapshot){throw new Error('VPN 服务状态待确认');}
      this.networkStarted=snapshot.serviceReady;if(this.mounted){this.vpn=snapshot;}
    }else{
      this.networkStarted=false;if(this.mounted){this.vpn=live;}
    }
    if(this.mounted){this.corePaused=false;this.completeStartup();}
  }
  notify(): void {
    if (!this.mounted || !this.observer) { return; }
    const view = new ClientView();
    view.page = this.page;
    view.status = this.status;
    view.peers = this.peers;
    view.selectedPeer = this.selectedPeer;
    view.output = this.output;
    view.peersUpdating = this.peersUpdating;
    view.peersError = this.peersError;
    view.vpnProgress = this.vpnProgress;
    view.vpnMessage = this.vpnMessage;
    view.diagnosticBusy = this.diagnosticBusy;
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
      previous.peersUpdating === view.peersUpdating &&
      previous.peersError === view.peersError &&
      previous.vpnProgress === view.vpnProgress &&
      previous.vpnMessage === view.vpnMessage &&
      previous.diagnosticBusy === view.diagnosticBusy &&
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
