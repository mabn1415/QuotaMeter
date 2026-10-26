#!/usr/bin/env node
// Audit only the shareable source tree. Never print matching credential values.
import { readdir, readFile, lstat } from 'node:fs/promises';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const excluded = new Set(['.build', '.swiftpm', 'dist', '.git', 'collector/node_modules']);
const topFiles = new Set(['.gitignore', 'Package.swift', 'README.org', 'VERIFICATION.org', 'LICENSE']);
const allowed = path => topFiles.has(path) ||
  /^Sources\/QuotaMeter\/[A-Za-z0-9_-]+\.swift$/.test(path) ||
  /^Tests\/QuotaMeterTests\/[A-Za-z0-9_-]+\.swift$/.test(path) ||
  /^collector\/(collector\.mjs|manual-setup\.mjs|manual-setup\.test\.mjs|parser\.mjs|parser\.test\.mjs|privacy\.mjs|privacy\.test\.mjs|package\.json|package-lock\.json)$/.test(path) ||
  /^scripts\/(build-app\.sh|check-environment\.sh|install-app\.sh|install-deps\.sh|setup\.sh|audit-source\.mjs)$/.test(path);
const findings = [];
const files = [];
async function walk(dir) {
  for (const name of (await readdir(dir)).sort()) {
    const full = join(dir, name);
    const path = relative(root, full);
    if (excluded.has(path) || /^\..+\.~undo-tree~$/.test(name)) continue;
    const stat = await lstat(full);
    if (stat.isSymbolicLink()) { findings.push(`${path}: symbolic link`); continue; }
    if (stat.isDirectory()) { await walk(full); continue; }
    if (!allowed(path)) { findings.push(`${path}: outside source allowlist`); continue; }
    files.push(path);
    const content = await readFile(full, 'utf8');
    const rules = [
      /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
      /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}/,
      /\bBearer\s+[A-Za-z0-9_.-]{20,}/i,
      /\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}/
    ];
    if (rules.some(rule => rule.test(content))) findings.push(`${path}: possible credential`);
  }
}
await walk(root);
if (findings.length) {
  console.error('Source audit failed (values omitted):\n' + findings.join('\n'));
  process.exitCode = 1;
} else if (process.argv.includes('--list')) {
  console.log(files.sort().join('\n'));
} else {
  console.log(`Source audit passed: ${files.length} allowlisted files; generated folders excluded.`);
  console.log('This pattern check does not guarantee absence of secrets. Archive only --list files.');
}
