import test from 'node:test';
import assert from 'node:assert/strict';
import { diagnosticMessage } from './privacy.mjs';

test('diagnostics omit session URLs, home paths, and oversized messages', () => {
  const value = diagnosticMessage(new Error('Failed at https://chatgpt.com/c/private-id?session=example /test-home/profile'), '/test-home');
  assert.ok(!value.includes('private-id'));
  assert.ok(!value.includes('session='));
  assert.ok(!value.includes('/test-home'));
  assert.ok(value.includes('~/profile'));
  assert.equal(diagnosticMessage('x'.repeat(1000)).length, 800);
});
