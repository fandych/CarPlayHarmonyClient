export const MAX_CONNECTION_LOG_LINES: number = 300;

export function appendConnectionLog(lines: string[], line: string): string[] {
  const appended = [...lines, line];
  return appended.length > MAX_CONNECTION_LOG_LINES
    ? appended.slice(appended.length - MAX_CONNECTION_LOG_LINES)
    : appended;
}
