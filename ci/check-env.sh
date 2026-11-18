#!/bin/bash
set -euo pipefail
if [ -z "${CUDACXX:-}" ]; then
  if [ -x /usr/local/cuda-12.8/bin/nvcc ]; then CUDACXX=/usr/local/cuda-12.8/bin/nvcc; else CUDACXX=/usr/local/cuda/bin/nvcc; fi
fi
echo "nvcc: $($CUDACXX --version | grep release)"
echo "gcc:  $(gcc --version | head -1)"
echo "cmake: $(cmake --version | head -1)"
echo "arch: $(uname -m)"
if git rev-parse --short HEAD >/dev/null 2>&1; then echo "commit: $(git rev-parse --short HEAD)"; fi
if ! $CUDACXX --version | grep -q 'release 12\.'; then echo "warning: sm_70 requires CUDA 12.x (12.9 is last)" >&2; fi
