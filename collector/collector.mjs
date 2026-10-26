import { chromium } from 'playwright';
import { chmod, mkdir, readFile, writeFile, rename, appendFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseUsage } from './parser.mjs';
import { diagnosticMessage } from './privacy.mjs';

// New files are private; keep the v3.0 profile path without copying credentials.
process.umask(0o077);
const base = join(homedir(), 'Library', 'Application Support', 'AllowanceMonitor');
const profile = join(base, 'chrome-profile');
const configPath = join(base, 'config.json');
const usagePath = join(base, 'usage.json');
const historyPath = join(base, 'history.jsonl');
const diagnosticsPath = join(base, 'collector-diagnostics.json');
const setup = process.argv.includes('--setup');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let context;
let page;
let windowController;
let windowMode = 'visible';
const requestedMode = (process.env.QUOTAMETER_CHROME_MODE ?? process.env.ALLOWANCE_MONITOR_CHROME_MODE) === 'visible' ? 'visible' : 'minimized';

// Keep a real, headed Chrome session. Minimize its window using Chrome's
// DevTools Protocol instead of switching to headless (which failed in v2.5).
async function minimizeChrome(page) {
  if (setup || requestedMode === 'visible') return;
  try {
    const session = await context.newCDPSession(page);
    const { windowId } = await session.send('Browser.getWindowForTarget');
    windowController = { session, windowId };
    await session.send('Browser.setWindowBounds', { windowId, bounds: { windowState: 'minimized' } });
    windowMode = 'minimized';
    console.log('WINDOW_MINIMIZED');
  } catch (error) {
    windowMode = 'visible';
    console.error('WINDOW_MINIMIZE_UNAVAILABLE: ' + diagnosticMessage(error));
    // Continue in the known-good visible mode rather than failing collection.
  }
}

async function restoreChrome() {
  if (!windowController || windowMode !== 'minimized') return;
  try {
    await windowController.session.send('Browser.setWindowBounds', {
      windowId: windowController.windowId, bounds: { windowState: 'normal' }
    });
    windowMode = 'visible-fallback';
    console.log('WINDOW_RESTORED_FOR_RETRY');
    await sleep(1200);
  } catch (error) {
    console.error('WINDOW_RESTORE_FAILED: ' + diagnosticMessage(error));
  }
}

function validChatGPT(url) {
  try { const u = new URL(url); return u.protocol === 'https:' && u.hostname === 'chatgpt.com'; }
  catch { return false; }
}
function parseVisible(text) {
  try {
    const result = parseUsage(text);
    return result.fiveHour && result.weekly ? result : null;
  } catch { return null; }
}
async function readUsage(page) {
  try { return parseVisible(await page.locator('body').innerText({ timeout: 5000 })); }
  catch { return null; }
}
async function waitForUsage(page, timeout = 9000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const usage = await readUsage(page);
    if (usage) return usage;
    await sleep(650);
  }
  return null;
}
async function clickCandidate(page, pattern) {
  const targets = [
    page.getByRole('button', { name: pattern }),
    page.getByRole('menuitem', { name: pattern }),
    page.getByRole('tab', { name: pattern }),
    page.getByRole('link', { name: pattern }),
    page.getByText(pattern)
  ];
  for (const target of targets) {
    try {
      const item = target.first();
      if (await item.isVisible({ timeout: 750 })) {
        await item.click({ timeout: 2500 });
        await sleep(500);
        return true;
      }
    } catch { /* another selector may work */ }
  }
  return false;
}
async function openUsageUI(page) {
  let usage = await waitForUsage(page, 1500);
  if (usage) return usage;

  // The settings modal is not necessarily addressable by URL. Navigate by
  // visible controls, never by internal/private API calls.
  const usageLabels = /使用状況|利用状況|Usage|My usage|Limits|利用上限/i;
  const settingsLabels = /設定|Settings/i;
  const accountLabels = /プロフィール|アカウント|Profile|Account|ユーザー|マイプラン/i;

  // Sometimes the account menu is already open.
  await clickCandidate(page, usageLabels);
  usage = await waitForUsage(page, 1800);
  if (usage) return usage;

  if (await clickCandidate(page, settingsLabels)) {
    usage = await waitForUsage(page, 1800);
    if (usage) return usage;
    if (await clickCandidate(page, usageLabels)) {
      usage = await waitForUsage(page, 5500);
      if (usage) return usage;
    }
  }

  // ChatGPT often hides Settings under a profile/account menu.
  if (await clickCandidate(page, accountLabels)) {
    usage = await waitForUsage(page, 1200);
    if (usage) return usage;
    if (await clickCandidate(page, settingsLabels)) {
      usage = await waitForUsage(page, 1600);
      if (usage) return usage;
      await clickCandidate(page, usageLabels);
      usage = await waitForUsage(page, 5500);
      if (usage) return usage;
    }
  }

  // Some versions use an icon-only profile button. Try accessible labels.
  const iconButtons = page.locator('button[aria-label*="profile" i],button[aria-label*="account" i],button[data-testid*="profile" i],button[data-testid*="account" i]');
  if (await iconButtons.count()) {
    try {
      await iconButtons.last().click({ timeout: 2500 });
      await clickCandidate(page, settingsLabels);
      await clickCandidate(page, usageLabels);
      usage = await waitForUsage(page, 5500);
      if (usage) return usage;
    } catch { /* ignored */ }
  }
  return null;
}
async function save(usage) {
  const temp = usagePath + '.tmp';
  await writeFile(temp, JSON.stringify(usage, null, 2));
  await rename(temp, usagePath);
  await appendFile(historyPath, JSON.stringify(usage) + '\n');
}
async function recordFailure(error) {
  const message = diagnosticMessage(error);
  const body = page ? await page.locator('body').innerText({ timeout: 3000 }).catch(() => '') : '';
  const loginLikely = /log in|sign in|ログイン|サインイン|メールアドレス|email address/i.test(body.slice(0, 1800)) && !/5時間ごとの利用上限/.test(body);
  const reason = /profile.*in use|user data directory is already in use|ProcessSingleton/i.test(message)
    ? 'PROFILE_BUSY'
    : /ReferenceError|is not defined/i.test(message) ? 'COLLECTOR_CODE_ERROR'
    : /Failed to launch|Executable doesn't exist|browserType.launchPersistentContext/i.test(message) ? 'CHROME_LAUNCH_FAILED'
    : loginLikely ? 'LOGIN_REQUIRED' : 'USAGE_NOT_FOUND';
  await writeFile(diagnosticsPath, JSON.stringify({ at: new Date().toISOString(), reason, message, windowMode, pageUrl: validChatGPT(page?.url()) ? 'https://chatgpt.com/' : null }, null, 2)).catch(() => {});
  console.error(`ERROR [${reason}]: ${message}`);
  if (reason === 'LOGIN_REQUIRED') console.error('Chromeで初期設定・再ログインを実行してください。');
  else if (reason === 'PROFILE_BUSY') console.error('初期設定用Chromeを閉じてから再試行してください。');
  else if (reason === 'CHROME_LAUNCH_FAILED') console.error('Chromeの起動に失敗しました。Chromeのインストール状態を確認してください。');
  else if (reason === 'COLLECTOR_CODE_ERROR') console.error('collector.mjsに実行時エラーがあります。');
  else console.error('使用状況画面の自動操作に失敗しました。初期設定で画面を開き直してください。');
}

// Long-lived worker: keep the same headed/minimized Chrome and Playwright context.
// File-based request/response avoids exposing a local HTTP service or credentials.
const daemon = process.argv.includes('--daemon');
const commandPath = join(base, 'worker-command.json');
const responsePath = join(base, 'worker-response.json');
const workerStatePath = join(base, 'worker-state.json');
let initialUrl = 'https://chatgpt.com/';
let stopping = false;
let lastRequestId = '';
let collectedPreviously = false;
async function writeJSON(path, value) {
  const tmp = path + '.tmp';
  await writeFile(tmp, JSON.stringify(value, null, 2));
  await rename(tmp, path);
}
async function launchChrome() {
  context = await chromium.launchPersistentContext(profile, {
    channel: 'chrome', headless: false, viewport: { width: 1400, height: 950 }, locale: 'ja-JP'
  });
  context.on('close', () => { context = undefined; page = undefined; windowController = undefined; });
  page = context.pages()[0] || await context.newPage();
  await page.goto(initialUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await minimizeChrome(page);
}
async function ensureChrome() {
  if (context) {
    try {
      if (!page || page.isClosed()) page = context.pages().find(p => !p.isClosed()) || await context.newPage();
      await page.evaluate(() => document.readyState, { timeout: 5000 });
      return;
    } catch { await context.close().catch(() => {}); context = undefined; page = undefined; }
  }
  await launchChrome();
}
async function collectOnce() {
  await ensureChrome();
  // Never treat the previously rendered percentages as a fresh reading.
  // Settings may close on reload; openUsageUI restores it if needed.
  if (collectedPreviously) {
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 45000 });
  }
  let usage = await waitForUsage(page, 2500);
  if (!usage) usage = await openUsageUI(page);
  if (!usage) {
    await page.goto('https://chatgpt.com/', { waitUntil: 'domcontentloaded', timeout: 45000 });
    usage = await openUsageUI(page);
  }
  if (!usage && windowMode === 'minimized') {
    await restoreChrome();
    usage = await openUsageUI(page);
    if (usage) await minimizeChrome(page);
  }
  if (!usage) throw new Error('5時間枠・週間枠が見つかりません。ログイン状態またはChatGPT設定画面の構成を確認してください。');
  await save(usage);
  collectedPreviously = true;
  await writeJSON(diagnosticsPath, { at: new Date().toISOString(), reason: 'OK', windowMode });
  return usage;
}
async function runDaemon() {
  await writeJSON(workerStatePath, { pid: process.pid, startedAt: new Date().toISOString(), state: 'running' });
  const shutdown = () => { stopping = true; };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
  while (!stopping) {
    try {
      const request = JSON.parse(await readFile(commandPath, 'utf8'));
      if (request.id && request.id !== lastRequestId) {
        lastRequestId = request.id;
        if (request.action === 'stop') { stopping = true; break; }
        if (request.action === 'refresh') {
          try {
            await collectOnce();
            await writeJSON(responsePath, { id: request.id, ok: true, at: new Date().toISOString() });
          } catch (error) {
            await recordFailure(error);
            await writeJSON(responsePath, { id: request.id, ok: false, error: diagnosticMessage(error), at: new Date().toISOString() });
          }
        }
      }
    } catch (error) {
      if (error?.code !== 'ENOENT' && !(error instanceof SyntaxError)) console.error('WORKER_LOOP: ' + diagnosticMessage(error));
    }
    await sleep(500);
  }
  await context?.close().catch(() => {});
  await writeJSON(workerStatePath, { pid: process.pid, state: 'stopped', at: new Date().toISOString() });
}

try {
  await mkdir(base, { recursive: true, mode: 0o700 });
  await chmod(base, 0o700);
  let config = {};
  try { config = JSON.parse(await readFile(configPath, 'utf8')); } catch { /* first run */ }
  initialUrl = validChatGPT(config.usageUrl) ? config.usageUrl : 'https://chatgpt.com/';
  if (daemon) {
    await runDaemon();
  } else {
    await launchChrome();
    if (setup) {
      console.log('Chromeでログインし、設定 → 使用状況を開いてください（最大5分）。');
      let usage;
      for (let i = 0; i < 150; i++) {
        usage = await readUsage(page);
        if (usage) break;
        await sleep(2000);
      }
      if (!usage) throw new Error('5分以内に5時間枠と週間枠を検出できませんでした。');
      await writeJSON(configPath, { usageUrl: validChatGPT(page.url()) ? page.url() : 'https://chatgpt.com/' });
      await save(usage);
      console.log('SETUP_OK');
    } else {
      await collectOnce();
      console.log('REFRESH_OK');
    }
  }
} catch (error) {
  await recordFailure(error);
  process.exitCode = 1;
} finally {
  if (!daemon) await context?.close().catch(() => {});
}
