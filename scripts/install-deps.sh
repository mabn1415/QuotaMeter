#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v node >/dev/null || { echo 'Node.js 20+ をインストールしてください'; exit 1; }
command -v npm >/dev/null || { echo 'npm が見つかりません'; exit 1; }
node -e 'if (Number(process.versions.node.split(".")[0]) < 20) process.exit(1)' || {
  echo 'Node.js 20以降が必要です。' >&2; exit 1;
}
cd "$ROOT/collector"
# Respect reviewed versions in the lockfile. Use the installed Google Chrome.
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci
npm test
echo '準備完了（別途Google Chromeが必要です）'
