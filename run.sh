#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PYTHON="${PYTHON:-python3}"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "python3 not found"
  exit 1
fi

if [[ ! -d ".venv" ]]; then
  "$PYTHON" -m venv .venv
fi

source ".venv/bin/activate"

python -m pip install --upgrade pip -q
python -m pip install -r requirements.txt -q

exec python main.py "$@"
