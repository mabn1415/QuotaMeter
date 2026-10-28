import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { chromeExecutable, manualChromeArguments, openManualChrome } from './manual-setup.mjs';

test('manual setup opens dedicated Chrome with loopback debugging only', () => {
  const args = manualChromeArguments('/tmp/Quota Meter profile', 'https://chatgpt.com/', 54321);
  assert.deepEqual(args, [
    '--user-data-dir=/tmp/Quota Meter profile',
    '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=54321',
    '--password-store=basic', '--use-mock-keychain', '--disable-sync',
    'https://chatgpt.com/'
  ]);
  assert.ok(!args.some(value => /enable-automation|no-sandbox/i.test(value)));
});

test('manual setup waits for the ordinary Chrome process', async () => {
  let invocation;
  const signals = new EventEmitter();
  const fakeSpawn = (command, args, options) => {
    invocation = { command, args, options };
    const child = new EventEmitter();
    child.kill = () => true;
    queueMicrotask(() => child.emit('exit', 0, null));
    return child;
  };
  await openManualChrome('/tmp/profile', 'https://chatgpt.com/', fakeSpawn, signals);
  assert.equal(invocation.command, chromeExecutable);
  assert.equal(invocation.options.stdio, 'ignore');
  assert.equal(invocation.options.detached, true);
});

test('finish signal keeps the logged-in Chrome process alive for attachment', async () => {
  const signals = new EventEmitter();
  let killedWith;
  let unrefCalled = false;
  let child;
  const fakeSpawn = () => {
    child = new EventEmitter();
    child.kill = signal => {
      killedWith = signal;
      queueMicrotask(() => child.emit('exit', null, signal));
      return true;
    };
    child.unref = () => { unrefCalled = true; };
    return child;
  };
  const completion = openManualChrome('/tmp/profile', 'https://chatgpt.com/', fakeSpawn, signals);
  await new Promise(resolve => setImmediate(resolve));
  signals.emit('SIGTERM');
  await completion;
  assert.equal(killedWith, undefined);
  assert.equal(unrefCalled, true);
});
