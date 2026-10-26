import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { chromeExecutable, manualChromeArguments, openManualChrome } from './manual-setup.mjs';

test('manual setup opens Chrome without automation or debugging flags', () => {
  const args = manualChromeArguments('/tmp/Quota Meter profile', 'https://chatgpt.com/');
  assert.deepEqual(args, [
    '--user-data-dir=/tmp/Quota Meter profile',
    '--password-store=basic', '--use-mock-keychain', '--disable-sync',
    'https://chatgpt.com/'
  ]);
  assert.ok(!args.some(value => /automation|remote-debugging|no-sandbox/i.test(value)));
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
});

test('finish signal closes only the dedicated Chrome process', async () => {
  const signals = new EventEmitter();
  let killedWith;
  let child;
  const fakeSpawn = () => {
    child = new EventEmitter();
    child.kill = signal => {
      killedWith = signal;
      queueMicrotask(() => child.emit('exit', null, signal));
      return true;
    };
    return child;
  };
  const completion = openManualChrome('/tmp/profile', 'https://chatgpt.com/', fakeSpawn, signals);
  signals.emit('SIGTERM');
  await completion;
  assert.equal(killedWith, 'SIGTERM');
});
