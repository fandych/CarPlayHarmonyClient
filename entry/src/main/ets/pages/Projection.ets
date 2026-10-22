import { carPlaySessionController } from '../app/session/CarPlaySessionController';

@Entry
@Component
struct Projection {
  @State private deviceName: string = '';
  @State private state: string = '连接中';
  private unsubscribe: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.unsubscribe = carPlaySessionController.subscribe((snapshot) => {
      this.deviceName = snapshot.connectedDeviceName;
      this.state = snapshot.state;
    });
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  build() {
    Stack() {
      Column({ space: 24 }) {
        Row({ space: 12 }) {
          Text('CarPlayer')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Blank()
          Text('CARPLAY')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#99D7FF')
        }
        .width('100%')
        Column({ space: 10 }) {
          Text('欢迎使用 CarPlay')
            .fontSize(36)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Text(this.deviceName.length > 0 ? `已连接 ${this.deviceName}` : '正在连接车机')
            .fontSize(20)
            .fontColor('#C5D5E2')
          Text(`状态：${this.state}`)
            .fontSize(14)
            .fontColor('#8EA5B8')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        Row({ space: 16 }) {
          this.statusCard('导航', 'CarPlay 导航应用尚未接入')
          this.statusCard('媒体', 'CarPlay 媒体应用尚未接入')
          this.statusCard('连接', this.deviceName.length > 0 ? '无线连接' : '待机')
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .padding(48)
      .backgroundColor('#101820')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private statusCard(title: string, detail: string) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
      Text(detail)
        .fontSize(13)
        .fontColor('#AFC1CE')
        .maxLines(2)
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .padding(20)
    .borderRadius(18)
    .backgroundColor('#1C2A35')
  }
}
