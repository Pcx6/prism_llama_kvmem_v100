#!/bin/bash
# Model/profile launcher for Prism KVMem on V100.
#   1 = Qwen3.8-27B GSQ IQ3_XXS (MTP + vision), default
#   2 = Ternary Bonsai 2 27B PTQ1_0 (vision)
# Usage:
#   ./start-llama-14803.sh [1|2]
#   KV_PROFILE=fast|256k|default ./start-llama-14803.sh 1
#   API_KEY_FILE=/path/to/key ./start-llama-14803.sh 1
#   DRY_RUN=1 ./start-llama-14803.sh 1
set -u
ulimit -c 0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${LLAMA_SERVER:-$REPO_ROOT/build-sm70/bin/llama-server}"
MODEL_DIR="${MODEL_DIR:-/srv/models}"
PORT="${PORT:-14803}"
CPUSET="${CPUSET:-0-11,24-35}"
CHOICE="${1:-${MODEL_CHOICE:-1}}"

if [ -n "${API_KEY:-}" ]; then
    KEY="$API_KEY"
elif [ -n "${API_KEY_FILE:-}" ]; then
    KEY="$(cat "$API_KEY_FILE")"
else
    echo "set API_KEY or API_KEY_FILE" >&2
    exit 2
fi

export LD_LIBRARY_PATH="$REPO_ROOT/build-sm70/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

case "$CHOICE" in
  1|gsq|qwen)
    MODEL="${GSQ_MODEL:-$MODEL_DIR/Qwen3.8-27B-GSQ-RCO-IQ3_XXS-mtp.gguf}"
    MMPROJ="${MMPROJ:-$MODEL_DIR/mmproj-Qwen3.8-27B-BF16.gguf}"
    ALIAS=Qwen3.8-27B-GSQ-RCO-IQ3_XXS
    SPEC=(--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-window 4096)
    CACHE=(--cache-type-k q8_0 --cache-type-v q8_0)
    if [ "${KV_PROFILE:-default}" = "fast" ]; then
      KV=(--kvmem-budget 4096 --kvmem-gen-reserve 12288)
      KVPOL=(--kvmem-method recency --kv-window 2048 --kv-sink 512)
    elif [ "${KV_PROFILE:-default}" = "256k" ]; then
      KV=(--kvmem-budget 8192 --kvmem-gen-reserve 4096)
      KVPOL=()
    else
      # full attention, 20K resident + 20K output
      KV=(--kvmem-budget 20480 --kvmem-gen-reserve 20480)
      KVPOL=()
    fi
    ;;
  2|bonsai)
    MODEL="${BONSAI_MODEL:-$MODEL_DIR/Ternary-Bonsai-2-27B-PTQ1_0.gguf}"
    MMPROJ="${MMPROJ:-$MODEL_DIR/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf}"
    ALIAS=Bonsai-2-27B
    SPEC=()
    CACHE=()
    KV=(--kvmem-budget 12288 --kvmem-gen-reserve 22528)
    KVPOL=()
    ;;
  *)
    echo "usage: $0 [1|2]  (1=GSQ MTP+vision, 2=Bonsai PTQ1_0)" >&2
    exit 2
    ;;
esac

CMD=("$BIN"
  -m "$MODEL" --mmproj "$MMPROJ"
  ${SPEC[@]+"${SPEC[@]}"} ${CACHE[@]+"${CACHE[@]}"}
  -a "$ALIAS"
  -c 262144 -ngl 99 -t 24 -np 1 --reasoning on
  -ub 1024 -b 4096 -fa on --cache-reuse 256
  --cache-ram 0 -ctxcp 0
  --kvmem ${KV[@]} ${KVPOL[@]+"${KVPOL[@]}"} --kvmem-idle-ttl "${KV_IDLE_TTL:-86400}"
  --host "${HOST:-0.0.0.0}" --port "$PORT" --api-key "$KEY")

if [ "${DRY_RUN:-0}" = "1" ]; then
  printf '%q ' "${CMD[@]}"; echo
  exit 0
fi

if command -v taskset >/dev/null 2>&1 && [ -n "$CPUSET" ]; then
  exec taskset -c "$CPUSET" "${CMD[@]}"
fi
exec "${CMD[@]}"
