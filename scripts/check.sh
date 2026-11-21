#!/bin/bash
# The search-quality check: indexes evals/corpus.noindex in a scratch folder and runs evals/queries.json against it.
# Exits 1 when any kind of query falls below its bar.   Usage: scripts/check.sh [--words-only]
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$here/app" && swift build -c release 2>&1 | grep -E "error|warning: unre" || true)
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
CEDAR_DATA="$scratch" "$here/app/.build/release/Cedar" --eval "$here/evals/corpus.noindex" "$here/evals/queries.json" "$@" 2>/dev/null
