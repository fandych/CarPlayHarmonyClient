import { PageHeader, showPageError } from '../components/PageHeader';
import { carPlaySessionController } from '../app/session/CarPlaySessionController';

@Entry
@Component
struct Logs {
  @State private lines: string[] = [];
  @State private options: SelectOption[] = [];
  @State private selected: number = 0;
  @State private exporting: boolean = false;
  @State private storageFailure: string = '';
  private names: string[] = [];
  private session: string = '';
  private unsubscribe: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.unsubscribe = carPlaySessionController.subscribe((snapshot) => {
      this.lines = snapshot.logs;
      this.storageFailure = snapshot.logFailure;
      if (this.session !== snapshot.logSession) {
        this.session = snapshot.logSession;
        this.refresh();
      }
    });
    this.refresh();
  }
  aboutToDisappear(): void { this.unsubscribe?.(); this.unsubscribe = undefined; }

  private refresh(): void {
    try {
      this.names = carPlaySessionController.logSessions();
      this.options = this.names.map((name: string): SelectOption => {
        return { value: `${name === this.session ? '当前 · ' : ''}${name}` };
      });
      this.selected = 0;
    } catch (error) {
      showPageError(this.getUIContext(), '读取日志列表', error);
    }
  }
  private async exportLog(): Promise<void> {
    const name = this.names[this.selected];
    if (name === undefined) {
      this.getUIContext().getPromptAction().showToast({ message: '暂无可导出的日志。' });
      return;
    }
    this.exporting = true;
    try {
      const saved = await carPlaySessionController.exportLogs(name);
      this.getUIContext().getPromptAction().showToast({ message: saved ? '日志快照已保存。' : '已取消保存。' });
    } catch (error) {
      showPageError(this.getUIContext(), '导出日志', error);
    } finally {
      this.exporting = false;
    }
  }

  build() {
    Column({ space: 14 }) {
      PageHeader({ title: '日志' })
      Row({ space: 8 }) {
        Select(this.options)
          .selected(this.selected)
          .value(this.options[this.selected]?.value ?? '暂无日志')
          .font({ size: 12 })
          .layoutWeight(1)
          .enabled(!this.exporting)
          .onSelect((index: number) => { this.selected = index; })
        Button('刷新').fontSize(13).enabled(!this.exporting).onClick(() => this.refresh())
        Button(this.exporting ? '保存中' : '导出')
          .fontSize(13)
          .enabled(!this.exporting && this.names.length > 0)
          .onClick(() => { void this.exportLog(); })
      }
      .width('100%')
      Text('界面显示最近 250 条；导出读取完整持久文件，保留最近 10 次会话。日志默认脱敏。')
        .fontSize(12).fontColor($r('app.color.secondary_text'))
      if (this.storageFailure.length > 0) {
        Text(`文件可能不完整：${this.storageFailure}`).fontSize(13).fontColor($r('app.color.danger'))
      }
      Scroll() {
        Column({ space: 9 }) {
          if (this.lines.length === 0) {
            Text('暂无运行日志。').fontColor($r('app.color.secondary_text'))
          } else {
            ForEach(this.lines, (line: string, index: number) => {
              Text(line).fontSize(11).fontColor($r('app.color.primary_text')).width('100%')
            }, (line: string, index: number) => `${index}-${line}`)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(14)
      }
      .width('100%')
      .layoutWeight(1)
      .borderRadius(14)
      .backgroundColor($r('app.color.card_background'))
    }
    .padding({ left: 20, right: 20, top: 20, bottom: 20 })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
