#!/bin/bash
set -e

# Always operate in the directory this script lives in
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
echo "Working directory: $SCRIPT_DIR"

echo "[1/3] Checking data and logs directories..."

# Create required directories
for dir in \
  data \
  logs \
  data/nnUNet_raw \
  data/nnUNet_preprocessed \
  data/nnUNet_results
do
  if [ -d "$dir" ]; then
    echo "  $dir/ already present."
  else
    mkdir -p "$dir"
    echo "  $dir/ created."
  fi
done

echo "[2/3] Setting nnU-Net environment variables..."

# nnU-Net paths
export nnUNet_raw="$SCRIPT_DIR/data/nnUNet_raw"
export nnUNet_preprocessed="$SCRIPT_DIR/data/nnUNet_preprocessed"
export nnUNet_results="$SCRIPT_DIR/data/nnUNet_results"

echo "  nnUNet_raw=$nnUNet_raw"
echo "  nnUNet_preprocessed=$nnUNet_preprocessed"
echo "  nnUNet_results=$nnUNet_results"

echo "[3/3] Running alembic upgrade head..."
alembic upgrade head

echo "Done."

