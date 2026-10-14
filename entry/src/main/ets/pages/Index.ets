import { DeviceCard } from './DeviceCard';
import { common } from '@kit.AbilityKit';
import { ClientView, ClientController, PeerRow, getClientController } from './ClientController';
import { PeerInfo, accountName, tailnetName, peerName, peerAddress, osLabel } from './ClientModel';
import { HELP_SECTIONS, HelpSection, PRIVACY_TEXT } from './ProductInfo';
const BLUE: string = '#086CFA';
const INK: string = '#142337';
const MUTED: string = '#6D8094';
@Entry
@Component
struct Index {
  @State private licensePage: number = 0;
  @StorageLink('tailscale.safeTop') private safeTop: number = 0;
  @StorageLink('tailscale.safeBottom') private safeBottom: number = 0;
  @StorageLink('tailscale.safeLeft') private safeLeft: number = 0;
  @StorageLink('tailscale.safeRight') private safeRight: number = 0;
  @State private view: ClientView = new ClientView();
  private model: ClientController = getClientController();
  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.model.attach(context,(view: ClientView) => { this.view.apply(view); });
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
          this.model.onBackPress(); this.model.notify();
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
      if (this.view.vpnRunning) {
        Button(this.view.vpnNeedsCleanup ? '确认关闭 VPN' : '关闭 VPN')
          .fontColor(BLUE).backgroundColor('#E2F0FF').width('100%').margin({ bottom: 12 })
          .enabled(!this.view.busy).onClick(() => { this.setVpn(false); })
      }
      Button() {
        Row({ space: 12 }) {
          if (this.view.busy) { LoadingProgress().width(20).height(20).color(Color.White) }
          Text(this.view.loginStage === 'approval' ? '检查授权状态' : this.view.loginStage === 'browser' ? '检查登录结果' : '登录 Tailscale')
            .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Color.White)
          if (!this.view.busy) { Text('→').fontSize(23).fontColor(Color.White) }
        }.justifyContent(FlexAlign.Center)
      }.height(54).width('100%').borderRadius(27)
        .linearGradient({ angle: 100, colors: [['#20A2F4', 0], [BLUE, 1]] })
        .enabled(!this.view.busy).onClick(() => {
          if (this.view.loginStage !== 'idle') { this.model.checkLoginResult(); } else { this.login(); }
        })
      if (this.view.loginStage !== 'idle') {
        if (this.view.awaitingLogin) {
          Button('取消等待').backgroundColor(Color.Transparent).fontColor(MUTED)
            .onClick(() => { this.model.cancelLogin(); })
        }
        Button('重新发起登录').backgroundColor(Color.Transparent).fontColor(BLUE)
          .enabled(!this.view.busy).onClick(() => { this.login(); })
      }
      Text('登录只认证账号；VPN 可通过首页开关开启。').fontSize(11).fontColor('#8C9DAC')
        .margin({ top: 24, bottom: 12 })
      Button('使用帮助').backgroundColor(Color.Transparent).fontColor(BLUE)
        .onClick(() => { this.model.openInfoPage('help'); })
    }.width('100%')
  }

  @Builder
  private dashboard() {
    Row({ space: 12 }) {
      Text(accountName(this.view.account).slice(0, 1).toUpperCase()).fontSize(19).fontColor(BLUE)
        .fontWeight(FontWeight.Bold).width(44).height(44).textAlign(TextAlign.Center)
        .backgroundColor('#DAEAFF').borderRadius(22)
      Column({ space: 5 }) {
        Text(accountName(this.view.account)).fontSize(16).fontWeight(FontWeight.Medium).fontColor(INK)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(tailnetName(this.view.account)).fontSize(12).fontColor(MUTED)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button({ type: ButtonType.Normal }) { this.icon($r('app.media.settings')) }
        .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(16)
        .accessibilityText('设置').onClick(() => { this.model.page = 'settings'; this.model.notify(); })
    }.width('100%').margin({ bottom: 20 })
    Row({ space: 7 }) {
      Text('').width(7).height(7).backgroundColor(BLUE).borderRadius(4)
      Text(this.view.connectionLabel)
        .fontSize(12).fontColor('#427297')
    }.padding({ left: 12, right: 12, top: 8, bottom: 8 }).backgroundColor('#DEEEFB')
      .borderRadius(20).margin({ bottom: 18 }).alignSelf(ItemAlign.Start)
    Row({ space: 12 }) {
      Row() { this.icon($r('app.media.shield'), 26) }.width(48).height(48)
        .backgroundColor('#EDF2F6').borderRadius(24).justifyContent(FlexAlign.Center)
      Column({ space: 6 }) {
        Text('VPN').fontSize(17).fontWeight(FontWeight.Bold).fontColor(INK)
        Text(this.view.vpnLabel).fontSize(13).fontColor(this.view.vpnConnected ? BLUE : MUTED)
        Text(this.view.vpnConnected ? `发送 ${this.view.vpn.txPackets} 包 · 接收 ${this.view.vpn.rxPackets} 包` : '仅连接 Tailnet IPv4 · 保留普通上网')
          .fontSize(11).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.view.vpnConnected }).enabled(!this.view.vpnChanging && this.view.vpnToggleEnabled)
        .onChange((enabled: boolean) => {
          if (!this.view.vpnChanging && enabled !== this.view.vpnConnected) { this.setVpn(enabled); }
        })
        .accessibilityText('连接或断开 Tailnet VPN')
    }.width('100%').padding(18).backgroundColor(Color.White).borderRadius(22).margin({ bottom: 22 })
    if (this.view.vpnWanted && !this.view.vpn.connected) {
      Button('取消连接').fontColor(BLUE).backgroundColor('#E3EFFF')
        .onClick(() => { this.setVpn(false); }).margin({ bottom: 12 })
    }
    if (this.view.vpnCanRetry) {
      Button('重试连接').fontColor(BLUE).backgroundColor('#E3EFFF').onClick(() => { this.setVpn(true); })
    }
    if (this.view.vpnNeedsCleanup) {
      Button('重试关闭').fontColor(BLUE).backgroundColor('#E3EFFF').onClick(() => { this.setVpn(false); })
    }
    if (this.view.vpnMessage) {
      Text(this.view.vpnMessage).fontSize(13).fontColor(MUTED).width('100%').margin({ bottom: 12 })
    }

    Text(this.view.vpn.networkMapReady ? `本机 IP：${this.view.vpn.assignedIPv4}` :
      `${this.view.status.backendState === 'Running' && this.view.status.tailscaleIPs?.length ? '本机 IP' : '最近记录的 IP'}：${this.view.account.tailscaleIPs?.join(' · ') || '暂无'}`)
      .width('100%').fontSize(12).fontColor(MUTED).margin({ bottom: 20 })
      .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
    Button('复制本机 IPv4').fontSize(12).fontColor(BLUE).backgroundColor(Color.Transparent)
      .onClick(() => { this.model.copyLocalIPv4(); }).margin({ bottom: 12 })
    this.notice()
    if (this.view.restoringSession) {
      Text('正在恢复账号信息…').fontSize(13).fontColor(MUTED).width('100%').margin({ bottom: 12 })
    }
    if (this.view.startupPhase === 'failed') {
      Text(this.view.startupError).fontSize(13).fontColor(MUTED).width('100%')
      Button('重试账号同步').enabled(!this.view.restoringSession).onClick(() => { this.model.retryStartup(); })
        .fontColor(BLUE).backgroundColor('#E3EFFF').margin({ bottom: 16 })
    }
    if (this.view.status.health && this.view.status.health.length > 0) {
      Text(this.view.healthMessage).fontSize(12).fontColor('#966010')
        .width('100%').padding(14).backgroundColor('#FFF4DE').borderRadius(16).margin({ bottom: 16 })
    }
    Row() {
      Text(`${this.view.peersStale ? '最近设备' : '在线设备'} (${this.view.peers.length})`).fontSize(17).fontWeight(FontWeight.Bold)
        .fontColor(INK).layoutWeight(1)
      Button(this.view.showFilter ? '收起' : '筛选').fontSize(12).fontColor(MUTED)
        .backgroundColor(Color.Transparent).height(40).onClick(() => { this.model.showFilter = !this.view.showFilter; this.model.notify(); })
      Button() {
        Row({ space: 5 }) {
          if (this.view.peersUpdating) { LoadingProgress().width(16).height(16).color(BLUE) }
          else { this.icon($r('app.media.refresh'), 16) }
          Text('刷新').fontSize(12).fontColor(BLUE)
        }
      }.backgroundColor(Color.Transparent).height(40).enabled(!this.view.peersUpdating).onClick(() => { this.refreshData(); })
        .accessibilityText(this.view.peersUpdating ? '正在更新设备' : '刷新设备')
    }.width('100%').margin({ bottom: 8 })
    if (this.view.showFilter) {
      TextInput({ text: this.view.peerFilter, placeholder: '名称 / tag:server / user:name' })
        .height(44).fontSize(13).backgroundColor(Color.White).borderRadius(14).enabled(!this.view.busy)
        .onChange((value: string) => { this.model.peerFilter = value; this.model.notify(); }).onSubmit(() => { this.refreshData(); })
        .margin({ bottom: 8 })
      Text('仅展示当前账号可见的在线设备；不支持 ACL group: 组查询。')
        .fontSize(11).fontColor(MUTED).width('100%').margin({ bottom: 12 })
    }
    ForEach(this.view.peerRows, (row: PeerRow) => {
      DeviceCard({row:row,stale:this.view.peersStale,onSelect:(peer:PeerInfo):void=>{
        this.model.selectedPeer=peer;this.model.page='detail';this.model.notify();
      }})
    }, (row:PeerRow) => row.id)
    if (this.view.peersError) {
      Text(this.view.peersError).fontSize(12).fontColor(MUTED).width('100%').margin({ bottom: 12 })
    }
    if (this.view.peers.length === 0) {
      Column({ space: 12 }) {
        this.icon($r('app.media.device_desktop'), 36)
        Text(this.view.peersStale ? '设备信息待更新' : (this.view.peerFilter ? '没有匹配的在线设备' : '暂无可见的在线设备'))
          .fontSize(15).fontColor(INK)
        Text('点击刷新重试，或检查设备是否在线及访问策略。')
          .fontSize(12).fontColor(MUTED).textAlign(TextAlign.Center)
      }.width('100%').padding(24).backgroundColor(Color.White).borderRadius(20)
    }
    if (this.view.lastSynced) {
      Text(`${this.view.peersStale ? '历史数据 · ' : ''}最近同步 ${this.view.lastSynced}`).fontSize(11).fontColor(MUTED).width('100%')
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
      Text(this.view.accountAvailable ? accountName(this.view.account) : '未登录')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor(INK).width('100%')
      if (this.view.accountAvailable) {
        Text(tailnetName(this.view.account)).fontSize(13).fontColor(MUTED).width('100%')
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
    this.infoEntry('使用与排障', '连接设备、访问范围和常见问题', 'help')
    this.infoEntry('关于与开源许可', '社区版本、源码、隐私和许可证', 'about')
    Text('Tailscale for HarmonyOS').fontSize(14).fontColor(INK)
    Text(`${this.view.appVersion} · Tailscale Core 1.86.2`).fontSize(12).fontColor(MUTED).margin({ top: 6 })
    Text('VPN Alpha：支持登录、在线设备和 Tailnet IPv4 互通。暂不支持 MagicDNS、IPv6、出口节点和子网路由。')
      .fontSize(12).fontColor(MUTED).textAlign(TextAlign.Center).margin({ top: 16 })
  }

  @Builder
  private diagnosticButton(label: string, operation: string) {
    Button(label).fontSize(13).fontColor(BLUE).backgroundColor('#E3EFFF').borderRadius(14)
      .width('100%').height(44).enabled(!this.view.diagnosticBusy).onClick(() => { this.diagnostic(operation); })
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
    Button('查看反馈摘要').fontSize(13).fontColor(BLUE).backgroundColor('#E3EFFF')
      .width('100%').height(44).onClick(() => { this.model.openInfoPage('report'); })
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
        Button('复制设备 IPv4').fontColor(BLUE).backgroundColor('#E3EFFF')
          .onClick(() => { this.model.copyPeerIPv4(); }).margin({ bottom: 20 })
        Text('请在目标应用中使用 IPv4 和服务端口；本版尚未支持 MagicDNS。')
          .fontSize(12).fontColor(MUTED).margin({ bottom: 20 })
        this.detailRow('系统', osLabel(this.view.selectedPeer.os || ''))
        this.detailRow('DNS 名称', this.view.selectedPeer.dnsName || '未提供')
        this.detailRow('所属用户', this.view.selectedPeer.userLogin || this.view.selectedPeer.userName || '未提供')
        this.detailRow('设备标签', this.view.selectedPeer.tags?.join(' · ') || '无')
      }.width('100%').padding(24).backgroundColor(Color.White).borderRadius(24)
    }
  }

  @Builder
  private infoEntry(title: string, subtitle: string, page: string) {
    Button() {
      Row({ space: 12 }) {
        Column({ space: 6 }) {
          Text(title).fontSize(15).fontColor(INK)
          Text(subtitle).fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        this.icon($r('app.media.chevron_right'), 16)
      }.padding(18).width('100%')
    }.width('100%').backgroundColor(Color.White).borderRadius(18).margin({ bottom: 12 })
      .onClick(() => { this.model.openInfoPage(page); })
  }
  @Builder
  private help() {
    this.sectionHeader('使用与排障')
    ForEach(HELP_SECTIONS, (section: HelpSection) => {
      Column({ space: 10 }) {
        Text(section.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(INK).width('100%')
        Text(section.body).fontSize(14).fontColor(MUTED).lineHeight(22).width('100%')
      }.padding(18).width('100%').backgroundColor(Color.White).borderRadius(18).margin({ bottom: 12 })
    }, (section: HelpSection) => section.title)
  }
  @Builder
  private about() {
    this.sectionHeader('关于')
    Text('harmony-tailscale').fontSize(24).fontWeight(FontWeight.Bold).fontColor(INK)
    Text(`${this.view.appVersion} · 社区 Alpha`).fontSize(14).fontColor(BLUE).margin({ top: 8, bottom: 16 })
    Text('非官方社区客户端，与 Tailscale Inc.、华为无隶属或官方背书关系。')
      .fontSize(14).fontColor(MUTED).lineHeight(22).margin({ bottom: 16 })
    Button('查看项目源码').width('100%').fontColor(BLUE).onClick(() => { this.model.openProjectLink('source'); })
    Button('发行与安装说明').width('100%').fontColor(BLUE).onClick(() => { this.model.openProjectLink('releases'); })
    Button('提交问题反馈').width('100%').fontColor(BLUE).onClick(() => { this.model.openProjectLink('issues'); })
    Text('隐私与数据').fontSize(18).fontColor(INK).margin({ top: 22, bottom: 12 })
    Text(PRIVACY_TEXT).fontSize(14).fontColor(MUTED).lineHeight(22).width('100%')
    Button('查看上游隐私政策').fontColor(BLUE).backgroundColor(Color.Transparent)
      .onClick(() => { this.model.openProjectLink('privacy'); })
    Text('项目代码与文档使用 MIT。上游软件保留各自许可；本地声明可离线查看。')
      .fontSize(13).fontColor(MUTED).lineHeight(22).margin({ top: 16 })
    Button('开源许可证与第三方声明').width('100%').fontColor(BLUE)
      .onClick(() => { this.licensePage = 0; this.model.openInfoPage('licenses'); })
  }
  @Builder
  private licenses() {
    this.sectionHeader('开源许可证')
    if (this.view.legalLoading) { LoadingProgress().width(32).height(32).color(BLUE) }
    if (this.view.legalText) {
      Text(`第 ${this.licensePage + 1} / ${Math.max(1, Math.ceil(this.view.legalText.length / 12000))} 页`)
        .fontSize(12).fontColor(MUTED)
      Row({ space: 12 }) {
        Button('上一页').enabled(this.licensePage > 0).onClick(() => { this.licensePage--; })
        Button('下一页').enabled((this.licensePage + 1) * 12000 < this.view.legalText.length)
          .onClick(() => { this.licensePage++; })
      }.margin({ bottom: 16 })
      Text(this.view.legalText.slice(this.licensePage * 12000, (this.licensePage + 1) * 12000))
        .fontFamily('monospace').fontSize(12).fontColor(INK).width('100%')
        .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
    } else if (!this.view.legalLoading) {
      Button('重试读取声明').onClick(() => { this.model.loadLicenses(); }).fontColor(BLUE)
    }
  }
  @Builder
  private feedback() {
    this.sectionHeader('反馈摘要')
    Text('以下内容在本机生成，不含账号、IP、登录链接或原始日志。不会自动发送；请核对后复制并补充问题经过。')
      .fontSize(13).fontColor(MUTED).lineHeight(22).margin({ bottom: 16 })
    Text(this.view.feedbackText).fontFamily('monospace').fontSize(12).fontColor(INK)
      .width('100%').padding(16).backgroundColor(Color.White).borderRadius(16)
      .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
    Button('复制摘要').width('100%').fontColor(BLUE).onClick(() => { this.model.copyFeedbackSummary(); })
    Button('刷新摘要快照').width('100%').fontColor(BLUE).onClick(() => { this.model.refreshFeedbackSummary(); })
    Button('打开问题反馈').width('100%').fontColor(BLUE).onClick(() => { this.model.openProjectLink('issues'); })
  }

  build() {
    Stack() {
    Scroll() {
      Column({ space: 8 }) {
        if (this.view.utilityMessage) {
          Text(this.view.utilityMessage).fontSize(13).fontColor(INK).width('100%').padding(12)
            .backgroundColor('#E5F0FF').borderRadius(14)
        }
        if (this.view.page === 'settings') { this.settings() }
        else if (this.view.page === 'diagnostics') { this.diagnostics() }
        else if (this.view.page === 'detail') { this.detail() }
        else if (this.view.page === 'about') { this.about() }
        else if (this.view.page === 'help') { this.help() }
        else if (this.view.page === 'licenses') { this.licenses() }
        else if (this.view.page === 'report') { this.feedback() }
        else if (this.view.accountAvailable) { this.dashboard() }
        else { this.welcome() }
      }.width('100%').padding({ left: 24, right: 24, top: 24, bottom: 28 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
      .padding({ top: this.safeTop, bottom: this.safeBottom, left: this.safeLeft, right: this.safeRight })

    }.width('100%').height('100%')
      .backgroundColor('#EEF6FC')
      .linearGradient({ angle: 165, colors: [['#EAF4FF', 0], ['#F6FAFD', 0.6], ['#EEF6FC', 1]] })
      .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT],
        [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
  }
}
