#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."
requested_arch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      if [[ $# -lt 2 ]]; then
        echo "Error: --arch requires arm64, x64, or universal." >&2
        exit 1
      fi
      requested_arch="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--arch arm64|x64|universal]"
      exit 0
      ;;
    *) echo "Error: unknown argument $1" >&2; exit 1 ;;
  esac
done
if [[ -z "$requested_arch" ]]; then
  case "${ARCHS:-$(uname -m)}" in
    *arm64*x86_64*|*x86_64*arm64*) requested_arch=universal ;;
    *arm64*|aarch64) requested_arch=arm64 ;;
    *) requested_arch=x64 ;;
  esac
fi
case "$requested_arch" in
  amd64|x86_64) requested_arch=x64 ;;
esac
exec dart run flutter_native_build native build --platform macos \
  --linkage dynamic --macos-arch "$requested_arch"
