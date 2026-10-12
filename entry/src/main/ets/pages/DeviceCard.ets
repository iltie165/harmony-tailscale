import { PeerRow } from './ClientController';
import { PeerInfo, peerName, osLabel } from './ClientModel';

const INK: string = '#142337';
const MUTED: string = '#6D8094';

@Component
export struct DeviceCard {
  @ObjectLink row: PeerRow;
  @Prop stale: boolean = true;
  onSelect: (peer: PeerInfo) => void = (_peer: PeerInfo): void => {};

  private peerIcon(os: string): Resource {
    switch (os.toLowerCase()) {
      case 'windows': return $r('app.media.device_windows');
      case 'linux': return $r('app.media.device_linux');
      case 'macos': case 'darwin': return $r('app.media.device_mac');
      case 'ios': case 'android': case 'harmonyos': case 'openharmony': return $r('app.media.device_phone');
      default: return $r('app.media.device_desktop');
    }
  }

  build() {
    Row({ space: 12 }) {
      Row() {
        Image(this.peerIcon(this.row.peer.os || '')).width(26).height(26).objectFit(ImageFit.Contain)
      }.width(48).height(48).backgroundColor('#ECF4FC').borderRadius(16).justifyContent(FlexAlign.Center)
      Column({ space: 4 }) {
        Text(peerName(this.row.peer)).fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.row.peer.tailscaleIPs?.[0] || '暂无 IP').fontSize(12).fontColor(MUTED)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(osLabel(this.row.peer.os || '')).fontSize(11).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Row({ space: 4 }) {
        Text('').width(6).height(6).backgroundColor(this.stale ? MUTED : '#16CF74').borderRadius(3)
        Text(this.stale ? '待更新' : '在线').fontSize(11).fontColor(this.stale ? MUTED : '#089A52')
      }
      Image($r('app.media.chevron_right')).width(14).height(14).objectFit(ImageFit.Contain)
    }.width('100%').padding(16).borderRadius(20).backgroundColor(Color.White).margin({ bottom: 10 })
      .onClick(() => { this.onSelect(this.row.peer); })
      .accessibilityText(`${peerName(this.row.peer)}，${osLabel(this.row.peer.os || '')}，${this.stale ? '上次记录' : '在线'}，查看详情`)
  }
}
