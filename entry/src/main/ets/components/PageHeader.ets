import { UIContext } from '@kit.ArkUI';
import { carPlayDiagnostics } from '../platform/diagnostics/CarPlayDiagnostics';
import { describeFailure } from '../platform/diagnostics/DiagnosticFormat';

export function showPageError(ui: UIContext, stage: string, error: Error): void {
  carPlayDiagnostics.log('ui', `${stage}失败：${describeFailure(error)}`, true);
  ui.getPromptAction().showToast({ message: `${stage}失败：${error.message || describeFailure(error)}` });
}

@Component
export struct PageHeader {
  title: string = '';

  build() {
    Row({ space: 16 }) {
      Button('返回')
        .type(ButtonType.Normal)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.accent'))
        .fontSize(16)
        .padding({ left: 0, right: 8 })
        .onClick(() => this.getUIContext().getRouter().back())
      Text(this.title)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary_text'))
    }
    .height(56)
    .width('100%')
  }
}
