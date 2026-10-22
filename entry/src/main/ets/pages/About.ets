import { bundleManager } from '@kit.AbilityKit';
import { PageHeader, showPageError } from '../components/PageHeader';

@Entry
@Component
struct About {
  @State private version: string = '';

  aboutToAppear(): void {
    try {
      this.version = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (error) {
      showPageError(this.getUIContext(), '读取版本', error);
    }
  }

  build() {
    Column({ space: 20 }) {
      PageHeader({ title: '关于' })
      Text('CarPlay Harmony Client').fontSize(25).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary_text'))
      Text(this.version.length > 0 ? `版本 ${this.version}` : '版本信息不可用')
        .fontColor($r('app.color.secondary_text'))
      Text('参考 CarDeck 发送端与 DiPlay 接收端的实验性鸿蒙无线发送端。')
        .fontColor($r('app.color.primary_text'))
      Text('当前提供蓝牙/iAP2、网络与配对诊断、手动备用配置和完整日志。媒体投屏链路仍需接入和真机验收；发现服务或蓝牙连接成功不等于已经投屏。')
        .fontSize(14).fontColor($r('app.color.secondary_text'))
      Text('手动蓝牙地址必须是本人手机的真实地址，不是车机地址或占位地址。配置 JSON 不包含 Wi-Fi 密码、私钥或配对证明；Wi-Fi 密码由系统 Asset 安全存储保护。')
        .fontSize(14).fontColor($r('app.color.secondary_text'))
      Text('非 Apple 官方认证产品；不代表获得 CarPlay 或车厂认证。')
        .fontSize(13).fontColor($r('app.color.warning'))
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 24, right: 24, top: 20, bottom: 20 })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
