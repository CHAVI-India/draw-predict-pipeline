#!/bin/bash
set -euo pipefail

# Simple health check that only verifies the container is running
# and can access required directories

# Check if required directories are writable
for dir in "/home/draw/output" "/home/draw/logs"; do
    if [ ! -w "$dir" ]; then
        echo "Error: Directory $dir is not writable"
        exit 1
    fi
done

echo "Container is healthy"
exit 0
