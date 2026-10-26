import { homedir } from 'node:os';

// Keep diagnostics useful without persisting session URLs or the user's home path.
export function diagnosticMessage(error, home = homedir()) {
  let message = String(error?.message || error);
  message = message.replace(/https?:\/\/[^\s"'<>]+/gi, '[URL omitted]');
  if (home) message = message.split(home).join('~');
  return message.slice(0, 800);
}
