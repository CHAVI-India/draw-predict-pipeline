#!/bin/bash
set -e

# Always operate in the directory this script lives in
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
echo "Working directory: $SCRIPT_DIR"

echo "[1/2] Checking data and logs directories..."
for dir in data logs; do
  if [ -d "$dir" ]; then
    echo "  $dir/ already present."
  else
    mkdir -p "$dir"
    echo "  $dir/ created."
  fi
done

echo "[2/2] Running alembic upgrade head..."
alembic upgrade head

echo "Done."
