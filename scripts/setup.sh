#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/check-environment.sh"
"$ROOT/scripts/install-deps.sh"
"$ROOT/scripts/build-app.sh"
"$ROOT/scripts/install-app.sh"
