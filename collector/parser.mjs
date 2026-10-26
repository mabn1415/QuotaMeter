// Parse user-visible page text only. No internal/private endpoints are called.
const normalize = s => s.replace(/\u00a0/g, ' ').replace(/[ \t]+/g, ' ');
function section(text, labels) {
  const lines = normalize(text).split(/\n/).map(s => s.trim()).filter(Boolean);
  const idx = lines.findIndex(s => labels.some(l => s.includes(l)));
  if (idx < 0) return null;
  // Stop before next limit heading, reset-purchase action or analytics section.
  const collected = [];
  for (let i = idx + 1; i < Math.min(lines.length, idx + 7); i++) {
    const line = lines[i];
    if (/^(?:5時間ごとの利用上限|週ごとの利用上限|週間の利用上限|最近のプラン利用状況|今すぐ使用上限をリセット)/.test(line)) break;
    collected.push(line);
  }
  return collected.join(' ');
}
function resetTime(s, now) {
  const match = s.match(/リセットまで\s*(?:(\d+)\s*日)?\s*(?:(\d+)\s*時間)?\s*(?:(\d+)\s*分)?/);
  if (!match || !match.slice(1).some(Boolean)) return null;
  const minutes = (Number(match[1] || 0) * 1440) + (Number(match[2] || 0) * 60) + Number(match[3] || 0);
  return new Date(now.getTime() + minutes * 60000).toISOString();
}
function extract(text, labels, now) {
  const s = section(text, labels);
  if (!s) return null;
  const pct = s.match(/残り\s*(\d{1,3}(?:\.\d+)?)\s*%/);
  if (!pct) return null;
  const value = Number(pct[1]);
  if (!Number.isFinite(value) || value < 0 || value > 100) return null;
  return { remainingPercent: value, resetAt: resetTime(s, now) };
}
export function parseUsage(text, now = new Date()) {
  const fiveHour = extract(text, ['5時間ごとの利用上限', '5時間の利用上限'], now);
  const weekly = extract(text, ['週ごとの利用上限', '週間の利用上限'], now);
  if (!fiveHour && !weekly) throw new Error('利用枠が見つかりません。ログイン状態・ページ構造・表示言語を確認してください。');
  return { fetchedAt: now.toISOString(), source: 'ChatGPT 使用状況（表示テキスト）', fiveHour, weekly };
}
