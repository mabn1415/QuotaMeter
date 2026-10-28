import { spawn } from 'node:child_process';
import { chmodSync, mkdirSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { join } from 'node:path';

export const chromeExecutable = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

export const chromeDebugPortPath = profile => join(profile, 'QuotaMeterDevToolsPort');

export function manualChromeArguments(profile, url, debugPort) {
  return [
    `--user-data-dir=${profile}`,
    '--remote-debugging-address=127.0.0.1',
    `--remote-debugging-port=${debugPort}`,
    '--password-store=basic',
    '--use-mock-keychain',
    '--disable-sync',
    url
  ];
}

export async function chooseChromeDebugPort(profile) {
  mkdirSync(profile, { recursive: true, mode: 0o700 });
  const server = createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : 0;
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  if (!Number.isInteger(port) || port < 1024) throw new Error('Chrome の接続ポートを確保できません。');
  const path = chromeDebugPortPath(profile);
  writeFileSync(path, `${port}\n`, { mode: 0o600 });
  chmodSync(path, 0o600);
  return port;
}

export async function openManualChrome(profile, url, spawnProcess = spawn, signalTarget = process) {
  const debugPort = await chooseChromeDebugPort(profile);
  return new Promise((resolve, reject) => {
    const child = spawnProcess(chromeExecutable, manualChromeArguments(profile, url, debugPort), {
      stdio: 'ignore',
      detached: true
    });
    let settled = false;
    const cleanup = () => signalTarget.off('SIGTERM', finish);
    const complete = () => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve();
    };
    const finish = () => {
      // Keep this exact Chrome process alive. The worker will attach to it over
      // loopback CDP instead of relaunching a Playwright-configured browser.
      child.unref?.();
      complete();
    };
    signalTarget.once('SIGTERM', finish);
    child.once('error', error => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    });
    child.once('exit', (code, signal) => {
      if (settled) return;
      if (code === 0) complete();
      else {
        settled = true;
        cleanup();
        reject(new Error(`通常のChromeが終了しました（code=${code ?? 'none'}, signal=${signal ?? 'none'}）。`));
      }
    });
  });
}
