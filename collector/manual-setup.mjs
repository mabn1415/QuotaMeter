import { spawn } from 'node:child_process';

export const chromeExecutable = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

export function manualChromeArguments(profile, url) {
  return [
    `--user-data-dir=${profile}`,
    '--password-store=basic',
    '--use-mock-keychain',
    '--disable-sync',
    url
  ];
}

export function openManualChrome(profile, url, spawnProcess = spawn, signalTarget = process) {
  return new Promise((resolve, reject) => {
    const child = spawnProcess(chromeExecutable, manualChromeArguments(profile, url), {
      stdio: 'ignore'
    });
    let finishRequested = false;
    const cleanup = () => signalTarget.off('SIGTERM', finish);
    const finish = () => {
      finishRequested = true;
      child.kill('SIGTERM');
    };
    signalTarget.once('SIGTERM', finish);
    child.once('error', error => {
      cleanup();
      reject(error);
    });
    child.once('exit', (code, signal) => {
      cleanup();
      if (code === 0 || finishRequested) resolve();
      else reject(new Error(`通常のChromeが終了しました（code=${code ?? 'none'}, signal=${signal ?? 'none'}）。`));
    });
  });
}
