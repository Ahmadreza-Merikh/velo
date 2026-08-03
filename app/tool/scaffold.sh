#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

PLATFORMS="${1:-android,macos,windows}"

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter is not on PATH"
  exit 1
fi

BACKUP="$(mktemp -d)"
trap 'rm -rf "$BACKUP"' EXIT

for item in pubspec.yaml analysis_options.yaml lib; do
  if [[ -e "$item" ]]; then
    cp -R "$item" "$BACKUP/"
  fi
done

echo "generating platform projects for: $PLATFORMS"
flutter create --org com.velo --project-name velo --platforms="$PLATFORMS" . >/dev/null

rm -rf lib
for item in pubspec.yaml analysis_options.yaml lib; do
  if [[ -e "$BACKUP/$item" ]]; then
    cp -R "$BACKUP/$item" .
  fi
done

rm -f test/widget_test.dart

python3 tool/apply_platform.py "$PLATFORMS"

flutter pub get >/dev/null

echo "scaffold complete"
