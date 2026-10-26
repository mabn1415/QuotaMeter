import { spawn } from 'node:child_process';

export function manualChromeArguments(profile, url) {
  return [
    '-W',
    '-n',
    '-a',
    'Google Chrome',
    '--args',
    `--user-data-dir=${profile}`,
    '--password-store=basic',
    '--use-mock-keychain',
    '--disable-sync',
    url
  ];
}

export function openManualChrome(profile, url, spawnProcess = spawn) {
  return new Promise((resolve, reject) => {
    const child = spawnProcess('/usr/bin/open', manualChromeArguments(profile, url), {
      stdio: 'ignore'
    });
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`通常のChromeが終了しました（code=${code ?? 'none'}, signal=${signal ?? 'none'}）。`));
    });
  });
}
