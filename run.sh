#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

xcodebuild -project TheTranscriptor.xcodeproj -scheme TheTranscriptor -configuration Debug build

APP_PATH=$(xcodebuild -project TheTranscriptor.xcodeproj -scheme TheTranscriptor -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/TheTranscriptor.app

if [ ! -d "$APP_PATH" ]; then
  echo "No se encontró la app compilada en: $APP_PATH" >&2
  exit 1
fi

echo "Lanzando $APP_PATH"
open "$APP_PATH"
