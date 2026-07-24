#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="${1:-Release}"
ARCH="${2:-arm64}"
ENV_QT_PATH="${ENV_QT_PATH:-/opt/homebrew/opt/qt}"

echo
echo "---------------------------------------------------------------"
echo "QuickDesk macOS full package"
echo "---------------------------------------------------------------"
echo "[*] root: $ROOT_DIR"
echo "[*] mode: $MODE"
echo "[*] arch: $ARCH"
echo "[*] ENV_QT_PATH: $ENV_QT_PATH"

cd "$ROOT_DIR"

ENV_QT_PATH="$ENV_QT_PATH" bash scripts/build_qd_mac.sh "$MODE" "$ARCH"
ENV_QT_PATH="$ENV_QT_PATH" bash scripts/publish_qd_mac.sh "$MODE" "$ARCH"
bash scripts/package_qd_mac.sh "$MODE"

echo
echo "---------------------------------------------------------------"
echo "[*] full package finished"
echo "---------------------------------------------------------------"
echo "[*] output: $ROOT_DIR/publish/$MODE/QuickDesk.dmg"
