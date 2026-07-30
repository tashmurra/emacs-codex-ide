#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec emacs -Q --batch \
  -L "$ROOT_DIR" \
  -l "$ROOT_DIR/bin/benchmark-mcp-policy.el"
