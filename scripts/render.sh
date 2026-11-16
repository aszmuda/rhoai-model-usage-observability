#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "$BASH_SOURCE")/.." && pwd)
TARGET_DIR=""
APPLY=false

usage() {
  cat <<'HELP'
Usage: ./scripts/render.sh [TARGET_DIR] [--apply]

Render a retained project Kustomization. The default target is
external-metering/simulator.

Arguments:
  TARGET_DIR   Kustomize directory; relative paths are checked from the current
               directory, then the repository root.
  --apply      Apply the rendered manifests with oc apply -f -
  -h, --help   Show this help.

Use oc or standalone kustomize to render. Applying requires oc.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0 ;;
    --apply)
      APPLY=true
      shift ;;
    -*)
      printf "Error: Unknown option '%s'. Use --help for usage.\n" "$1" >&2
      exit 1 ;;
    *)
      if [[ -n "$TARGET_DIR" ]]; then
        echo "Error: Specify only one TARGET_DIR." >&2
        exit 1
      fi
      TARGET_DIR=$1
      shift ;;
  esac
done

if [[ -z "$TARGET_DIR" ]]; then
  TARGET_DIR="$ROOT_DIR/external-metering/simulator"
fi
if [[ ! -d "$TARGET_DIR" && -d "$ROOT_DIR/$TARGET_DIR" ]]; then
  TARGET_DIR="$ROOT_DIR/$TARGET_DIR"
fi
if [[ ! -d "$TARGET_DIR" ]]; then
  printf "Error: Target directory '%s' not found.\n" "$TARGET_DIR" >&2
  exit 1
fi
TARGET_DIR=$(cd -- "$TARGET_DIR" && pwd)

if command -v oc >/dev/null 2>&1; then
  RAW_MANIFESTS=$(oc kustomize "$TARGET_DIR")
elif command -v kustomize >/dev/null 2>&1; then
  RAW_MANIFESTS=$(kustomize build "$TARGET_DIR")
else
  echo "Error: Neither oc nor kustomize command found in PATH." >&2
  exit 1
fi

if [[ "$APPLY" == true ]]; then
  if ! command -v oc >/dev/null 2>&1; then
    echo "Error: oc is required for --apply." >&2
    exit 1
  fi
  printf '%s\n' "$RAW_MANIFESTS" | oc apply -f -
else
  printf '%s\n' "$RAW_MANIFESTS"
fi
