import test from 'node:test';
import assert from 'node:assert/strict';
import { parseUsage } from './parser.mjs';
test('Japanese usage screen', () => {
  const t = `プランの利用上限\n5時間ごとの利用上限\nリセットまで22分\n残り0%\n週ごとの利用上限\nリセットまで6日0時間\n残り81%\n最近のプラン利用状況`;
  const v = parseUsage(t, new Date('2026-10-26T06:00:00Z'));
  assert.equal(v.fiveHour.remainingPercent, 0);
  assert.equal(v.weekly.remainingPercent, 81);
  assert.equal(v.fiveHour.resetAt, '2026-10-26T06:22:00.000Z');
});
test('fails closed when page does not contain usage', () => assert.throws(() => parseUsage('ログイン')));
