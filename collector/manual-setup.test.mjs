import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { manualChromeArguments, openManualChrome } from './manual-setup.mjs';

test('manual setup opens Chrome without automation or debugging flags', () => {
  const args = manualChromeArguments('/tmp/Quota Meter profile', 'https://chatgpt.com/');
  assert.deepEqual(args, [
    '-W', '-n', '-a', 'Google Chrome', '--args',
    '--user-data-dir=/tmp/Quota Meter profile',
    '--password-store=basic', '--use-mock-keychain', '--disable-sync',
    'https://chatgpt.com/'
  ]);
  assert.ok(!args.some(value => /automation|remote-debugging|no-sandbox/i.test(value)));
});

test('manual setup waits for the ordinary Chrome process', async () => {
  let invocation;
  const fakeSpawn = (command, args, options) => {
    invocation = { command, args, options };
    const child = new EventEmitter();
    queueMicrotask(() => child.emit('exit', 0, null));
    return child;
  };
  await openManualChrome('/tmp/profile', 'https://chatgpt.com/', fakeSpawn);
  assert.equal(invocation.command, '/usr/bin/open');
  assert.equal(invocation.options.stdio, 'ignore');
});
