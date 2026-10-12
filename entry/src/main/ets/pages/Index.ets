import { common } from '@kit.AbilityKit';
import { ClientView, ClientController, getClientController } from './ClientController';
import { PeerInfo, accountName, tailnetName, peerName, peerAddress, osLabel } from './ClientModel';
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
  @State private view: ClientView = new ClientView();
  private model: ClientController = getClientController();
  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.model.attach(context,(view: ClientView) => { this.view = view; });
  }
  aboutToDisappear(): void { this.model.aboutToDisappear(); }
  onBackPress(): boolean { const result = this.model.onBackPress(); this.model.notify(); return result; }
  private async refreshData(silent: boolean = false): Promise<void> { await this.model.refreshData(silent); }
  private async login(): Promise<void> { await this.model.login(); }
  private async setVpn(enabled: boolean): Promise<void> { await this.model.setVpn(enabled); }
  private async diagnostic(operation: string): Promise<void> { await this.model.diagnostic(operation); }
  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({title:'退出 Tailscale？',message:'将注销这台设备的登录状态。',
      primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:'退出登录',action:()=>{this.model.logout();}}});
  }
  private confirmVpnProbe(): void {
    if (!this.model.canProbe()) { return; }
    this.getUIContext().showAlertDialog({title:'验证系统 VPN 能力？',message:'系统将请求 VPN 授权，检查完成后会关闭临时网卡。',
      primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:'开始检查',action:()=>{this.model.runVpnProbe();}}});
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
          this.model.page = this.view.page === 'diagnostics' ? 'settings' : 'main'; this.model.notify();
        })
      Text(title).fontSize(22).fontWeight(FontWeight.Bold).fontColor(INK).layoutWeight(1)
    }.width('100%').margin({ bottom: 16 })
  }

  @Builder
  private notice() {
    if (this.view.busy || this.view.message) {
      Row({ space: 10 }) {
        if (this.view.busy) { LoadingProgress().width(20).height(20).color(BLUE) }
        Text(this.view.busy ? this.view.progress : this.view.message)
          .fontSize(13).fontColor(INK).layoutWeight(1).lineHeight(20)
      }.width('100%').padding(14).backgroundColor('#E5F0FF').borderRadius(16)
        .margin({ bottom: 16 }).accessibilityText(this.view.busy ? this.view.progress : this.view.message)
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
          .height(32).onClick(() => { this.model.page = 'settings'; this.model.notify(); })
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
      if (this.model.vpnRunning()) {
        Button(this.view.vpnNeedsCleanup ? '确认关闭 VPN' : '关闭 VPN')
          .fontColor(BLUE).backgroundColor('#E2F0FF').width('100%').margin({ bottom: 12 })
          .enabled(!this.view.busy).onClick(() => { this.setVpn(false); })
      }
      Button() {
        Row({ space: 12 }) {
          if (this.view.busy) { LoadingProgress().width(20).height(20).color(Color.White) }
          Text(this.view.awaitingLogin ? '刷新登录状态' : '登录 Tailscale')
            .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Color.White)
          if (!this.view.busy) { Text('→').fontSize(23).fontColor(Color.White) }
        }.justifyContent(FlexAlign.Center)
      }.height(54).width('100%').borderRadius(27)
        .linearGradient({ angle: 100, colors: [['#20A2F4', 0], [BLUE, 1]] })
        .enabled(!this.view.busy).onClick(() => {
          if (this.view.awaitingLogin) { this.refreshData(); } else { this.login(); }
        })
      if (this.view.awaitingLogin) {
        Button('重新发起登录').backgroundColor(Color.Transparent).fontColor(BLUE)
          .enabled(!this.view.busy).onClick(() => { this.login(); })
      }
      Text('首次需授权网络服务；授权后 VPN 开关仍保持关闭。').fontSize(11).fontColor('#8C9DAC')
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
        Text('').width(6).height(6).backgroundColor(this.view.peersStale ? MUTED : '#16CF74').borderRadius(3)
        Text(this.view.peersStale ? '待更新' : '在线').fontSize(11).fontColor(this.view.peersStale ? MUTED : '#089A52')
      }
      this.icon($r('app.media.chevron_right'), 14)
    }.width('100%').padding(16).borderRadius(20).backgroundColor(Color.White)
      .margin({ bottom: 10 }).onClick(() => { this.model.selectedPeer = peer; this.model.notify(); this.model.page = 'detail'; this.model.notify(); })
      .accessibilityText(`${peerName(peer)}，${osLabel(peer.os || '')}，在线，查看详情`)
  }

  @Builder
  private dashboard() {
    Row({ space: 12 }) {
      Text(accountName(this.model.displayAccount()).slice(0, 1).toUpperCase()).fontSize(19).fontColor(BLUE)
        .fontWeight(FontWeight.Bold).width(44).height(44).textAlign(TextAlign.Center)
        .backgroundColor('#DAEAFF').borderRadius(22)
      Column({ space: 5 }) {
        Text(accountName(this.model.displayAccount())).fontSize(16).fontWeight(FontWeight.Medium).fontColor(INK)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(tailnetName(this.model.displayAccount())).fontSize(12).fontColor(MUTED)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button({ type: ButtonType.Normal }) { this.icon($r('app.media.settings')) }
        .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(16)
        .accessibilityText('设置').onClick(() => { this.model.page = 'settings'; this.model.notify(); })
    }.width('100%').margin({ bottom: 20 })
    Row({ space: 7 }) {
      Text('').width(7).height(7).backgroundColor(BLUE).borderRadius(4)
      Text(this.model.connectionLabel())
        .fontSize(12).fontColor('#427297')
    }.padding({ left: 12, right: 12, top: 8, bottom: 8 }).backgroundColor('#DEEEFB')
      .borderRadius(20).margin({ bottom: 18 }).alignSelf(ItemAlign.Start)
    Row({ space: 12 }) {
      Row() { this.icon($r('app.media.shield'), 26) }.width(48).height(48)
        .backgroundColor('#EDF2F6').borderRadius(24).justifyContent(FlexAlign.Center)
      Column({ space: 6 }) {
        Text('VPN').fontSize(17).fontWeight(FontWeight.Bold).fontColor(INK)
        Text(this.view.vpnChanging ? '正在切换…' : (this.view.vpnNeedsCleanup ? '关闭待确认' :
          (this.view.vpn.connected ? '已开启' : (this.view.vpnWanted ?
            (this.view.recovery.phase === 'blocked' ? '恢复待处理' : '正在自动恢复…') : (this.view.vpn.ok ? '已关闭' : '连接异常')))))
          .fontSize(13).fontColor(this.view.vpn.connected ? BLUE : MUTED)
        Text(this.view.vpn.connected ? `发送 ${this.view.vpn.txPackets} 包 · 接收 ${this.view.vpn.rxPackets} 包` : '仅连接 Tailnet IPv4 · 保留普通上网')
          .fontSize(11).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.view.vpnWanted || this.model.vpnRunning() }).enabled(this.model.vpnToggleEnabled())
        .onChange((enabled: boolean) => { this.setVpn(enabled); })
        .accessibilityText('连接或断开 Tailnet VPN')
    }.width('100%').padding(18).backgroundColor(Color.White).borderRadius(22).margin({ bottom: 22 })
    Text(this.view.vpn.networkMapReady ? `本机 IP：${this.view.vpn.assignedIPv4}` :
      `${this.view.status.backendState === 'Running' && this.view.status.tailscaleIPs?.length ? '本机 IP' : '最近记录的 IP'}：${this.model.displayAccount().tailscaleIPs?.join(' · ') || '暂无'}`)
      .width('100%').fontSize(12).fontColor(MUTED).margin({ bottom: 20 })
      .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
    this.notice()
    if (this.view.status.backendState !== 'Running' && !this.view.vpn.networkMapReady) {
      Text(this.view.corePaused ? '网络连接已暂停，账号记录已保留。' : '账号记录已保留，正在核对连接并同步设备…').fontSize(13).fontColor(MUTED)
        .width('100%').margin({ bottom: 16 })
    }
    if (this.view.startupPhase === 'failed') {
      Text(this.view.startupError).fontSize(13).fontColor(MUTED).width('100%')
      Button('重试连接').enabled(!this.view.busy).onClick(() => { this.model.retryStartup(); })
        .fontColor(BLUE).backgroundColor('#E3EFFF').margin({ bottom: 16 })
    }
    if (this.view.status.health && this.view.status.health.length > 0) {
      Text(this.model.displayHealth().join('\n')).fontSize(12).fontColor('#966010')
        .width('100%').padding(14).backgroundColor('#FFF4DE').borderRadius(16).margin({ bottom: 16 })
    }
    Row() {
      Text(`${this.view.peersStale ? '最近设备' : '在线设备'} (${this.view.peers.length})`).fontSize(17).fontWeight(FontWeight.Bold)
        .fontColor(INK).layoutWeight(1)
      Button(this.view.showFilter ? '收起' : '筛选').fontSize(12).fontColor(MUTED)
        .backgroundColor(Color.Transparent).height(40).onClick(() => { this.model.showFilter = !this.view.showFilter; this.model.notify(); })
      Button() {
        Row({ space: 5 }) { this.icon($r('app.media.refresh'), 16); Text('刷新').fontSize(12).fontColor(BLUE) }
      }.backgroundColor(Color.Transparent).height(40).enabled(!this.view.busy).onClick(() => { this.refreshData(); })
    }.width('100%').margin({ bottom: 8 })
    if (this.view.showFilter) {
      TextInput({ text: this.view.peerFilter, placeholder: '名称 / tag:server / user:name' })
        .height(44).fontSize(13).backgroundColor(Color.White).borderRadius(14).enabled(!this.view.busy)
        .onChange((value: string) => { this.model.peerFilter = value; this.model.notify(); }).onSubmit(() => { this.refreshData(); })
        .margin({ bottom: 8 })
      Text('仅展示当前账号可见的在线设备；不支持 ACL group: 组查询。')
        .fontSize(11).fontColor(MUTED).width('100%').margin({ bottom: 12 })
    }
    // Stable unchanged rows; a changed row gets a new key so ForEach updates
    // its non-Observed PeerInfo builder instead of retaining stale text.
    ForEach(this.view.peers, (peer: PeerInfo) => { this.peerCard(peer) },
      (peer: PeerInfo) => `${peer.id}:${JSON.stringify(peer)}`)
    if (this.view.peers.length === 0 && !this.view.busy) {
      Column({ space: 12 }) {
        this.icon($r('app.media.device_desktop'), 36)
        Text(this.view.peersStale ? '设备信息待更新' : (this.view.peerFilter ? '没有匹配的在线设备' : '暂无可见的在线设备'))
          .fontSize(15).fontColor(INK)
        Text('点击刷新重试，或检查设备是否在线及访问策略。')
          .fontSize(12).fontColor(MUTED).textAlign(TextAlign.Center)
      }.width('100%').padding(24).backgroundColor(Color.White).borderRadius(20)
    }
    if (this.view.lastUpdated) {
      Text(`${this.view.peersStale ? '历史数据 · ' : ''}更新于 ${this.view.lastUpdated}`).fontSize(11).fontColor(MUTED).width('100%')
        .margin({ top: 8, bottom: 16 })
    }
    Row({ space: 12 }) {
      Button() {
        Row({ space: 8 }) { this.icon($r('app.media.settings'), 18); Text('设置').fontSize(14).fontColor(INK) }
      }.layoutWeight(1).height(48).borderRadius(16).backgroundColor(Color.Transparent)
        .border({ width: 1, color: '#DDE6EF' }).onClick(() => { this.model.page = 'settings'; this.model.notify(); })
      Button() {
        Row({ space: 8 }) { this.icon($r('app.media.logout'), 18); Text('退出登录').fontSize(14).fontColor(INK) }
      }.layoutWeight(1).height(48).borderRadius(16).backgroundColor(Color.Transparent)
        .border({ width: 1, color: '#DDE6EF' }).enabled(!this.view.busy).onClick(() => { this.confirmLogout(); })
    }.width('100%').margin({ top: 18, bottom: 12 })
  }

  @Builder
  private settings() {
    this.sectionHeader('设置')
    this.notice()
    Column({ space: 10 }) {
      Text('账号与网络').fontSize(12).fontColor(MUTED).width('100%')
      Text(this.model.hasAccount() ? accountName(this.model.displayAccount()) : '未登录')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor(INK).width('100%')
      if (this.model.hasAccount()) {
        Text(tailnetName(this.model.displayAccount())).fontSize(13).fontColor(MUTED).width('100%')
      }
      Text('官方 Tailscale 控制面').fontSize(13).fontColor(MUTED).width('100%')
    }.padding(20).width('100%').backgroundColor(Color.White).borderRadius(22).margin({ bottom: 16 })
    Column({ space: 10 }) {
      Text('设备名称').fontSize(14).fontWeight(FontWeight.Medium).fontColor(INK).width('100%')
      TextInput({ text: this.view.hostname, placeholder: 'harmony-tsnet' }).fontSize(14).enabled(!this.view.busy)
        .backgroundColor('#F1F6FB').onChange((value: string) => { this.model.hostname = value; this.model.notify(); })
      Text('在下次创建网络服务时生效。').fontSize(11).fontColor(MUTED).width('100%')
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
      .onClick(() => { this.model.page = 'diagnostics'; this.model.notify(); }).margin({ bottom: 24 })
    Text('Tailscale for HarmonyOS').fontSize(14).fontColor(INK)
    Text(`${this.view.appVersion} · Tailscale Core 1.86.2`).fontSize(12).fontColor(MUTED).margin({ top: 6 })
    Text('VPN Alpha：支持登录、在线设备和 Tailnet IPv4 互通。暂不支持 MagicDNS、IPv6、出口节点和子网路由。')
      .fontSize(12).fontColor(MUTED).textAlign(TextAlign.Center).margin({ top: 16 })
  }

  @Builder
  private diagnosticButton(label: string, operation: string) {
    Button(label).fontSize(13).fontColor(BLUE).backgroundColor('#E3EFFF').borderRadius(14)
      .width('100%').height(44).enabled(!this.view.busy).onClick(() => { this.diagnostic(operation); })
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
      .enabled(!this.view.busy).onClick(() => { this.confirmVpnProbe(); })
    this.diagnosticButton('查询核心状态', 'status')
    this.diagnosticButton('启动网络服务', 'start')
    this.diagnosticButton('停止网络服务（不会注销账号）', 'close')
    Text(this.view.output || '选择一项检查，结果会显示在这里。')
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
    if (this.view.selectedPeer) {
      Column() {
        this.icon(this.peerIcon(this.view.selectedPeer.os || ''), 46)
        Text(peerName(this.view.selectedPeer)).fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor(INK).margin({ top: 16, bottom: 8 })
        Text(this.view.peersStale || !this.view.peers.some((peer: PeerInfo) => peer.id === this.view.selectedPeer?.id) ? '最近记录 · 当前状态待确认' : '在线 · 最近一次查询结果').fontSize(12).fontColor(MUTED).margin({ bottom: 28 })
        this.detailRow('Tailscale IP', peerAddress(this.view.selectedPeer))
        this.detailRow('系统', osLabel(this.view.selectedPeer.os || ''))
        this.detailRow('DNS 名称', this.view.selectedPeer.dnsName || '未提供')
        this.detailRow('所属用户', this.view.selectedPeer.userLogin || this.view.selectedPeer.userName || '未提供')
        this.detailRow('设备标签', this.view.selectedPeer.tags?.join(' · ') || '无')
      }.width('100%').padding(24).backgroundColor(Color.White).borderRadius(24)
    }
  }

  @Builder
  private startupOverlay() {
    Column() {
      Column({ space: 16 }) {
        if (this.view.startupPhase === 'checking') {
          LoadingProgress().width(40).height(40).color(BLUE)
          Text('正在启动网络服务').fontSize(20).fontWeight(FontWeight.Medium).fontColor(INK)
          Text(this.view.progress || '正在初始化本地核心…').fontSize(14).fontColor(MUTED)
            .textAlign(TextAlign.Center)
          Text('账号和设备信息将在后台更新').fontSize(12).fontColor(MUTED)
        } else {
          Text('连接尚未就绪').fontSize(20).fontWeight(FontWeight.Medium).fontColor(INK)
          Text(this.view.startupError).fontSize(14).fontColor(MUTED).textAlign(TextAlign.Center)
          Button(this.view.busy ? '正在等待系统操作结束…' : '重试连接').width('100%')
            .enabled(!this.view.busy).fontColor(Color.White).backgroundColor(BLUE)
            .onClick(() => { this.model.retryStartup(); })
          Button('查看诊断').fontColor(BLUE).backgroundColor(Color.Transparent)
            .onClick(() => { this.model.page = 'diagnostics'; this.model.dismissStartup(); })
          Button('暂时查看账号与设备').fontColor(MUTED).backgroundColor(Color.Transparent)
            .onClick(() => { this.model.dismissStartup(); })
        }
      }.width('100%').padding(28).backgroundColor(Color.White).borderRadius(24)
    }.width('100%').height('100%').padding({ left: 24, right: 24, top: this.safeTop, bottom: this.safeBottom })
      .justifyContent(FlexAlign.Center).backgroundColor('#D9EEF6FC')
      .onClick(() => {}).accessibilityText(this.view.startupPhase === 'checking' ? '正在初始化本地网络服务' : '本地服务尚未就绪')
  }

  build() {
    Stack() {
    Scroll() {
      Column({ space: 8 }) {
        if (this.view.page === 'settings') { this.settings() }
        else if (this.view.page === 'diagnostics') { this.diagnostics() }
        else if (this.view.page === 'detail') { this.detail() }
        else if (this.model.hasAccount()) { this.dashboard() }
        else { this.welcome() }
      }.width('100%').padding({ left: 24, right: 24, top: 24, bottom: 28 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
      .padding({ top: this.safeTop, bottom: this.safeBottom, left: this.safeLeft, right: this.safeRight })
      .enabled(!this.view.startupBlocking)
    if (this.view.startupBlocking) { this.startupOverlay() }
    }.width('100%').height('100%')
      .backgroundColor('#EEF6FC')
      .linearGradient({ angle: 165, colors: [['#EAF4FF', 0], ['#F6FAFD', 0.6], ['#EEF6FC', 1]] })
      .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT],
        [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
  }
}
