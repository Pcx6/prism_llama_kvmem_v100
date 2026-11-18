#!/bin/bash
# Source-build launcher for Prism KVMem on V100 (sm_70).
#   KVMEM_ROOT=/path/to/kvmem-root ./deploy/quickstart.sh 1
#   KVMEM_ROOT=... MODEL_CHOICE=2 ./deploy/quickstart.sh
#   KVMEM_ROOT=... KV_PROFILE=fast ./deploy/quickstart.sh 1
# No prebuilt binary is distributed; KVMem adapter is not part of this repo.
set -euo pipefail

REPO="${REPO:-Pcx6/prism_llama_kvmem_v100}"
TAG="${TAG:-main}"
DEST="${DEST:-$HOME/.local/opt/prism_kvmem}"
PORT="${PORT:-14803}"
HOST="${HOST:-127.0.0.1}"
CPUSET="${CPUSET:-0-11,24-35}"
KV_PROFILE="${KV_PROFILE:-default}"
SRC_DIR="${SRC_DIR:-$DEST/src}"
KVMEM_ROOT="${KVMEM_ROOT:-}"

if [ -z "${API_KEY:-}" ]; then
  API_KEY="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' 
')"
fi
if [ -z "$KVMEM_ROOT" ]; then
  echo "KVMEM_ROOT is required; the KVMem adapter is not distributed with this repo" >&2
  exit 2
fi

CHOICE="${1:-${MODEL_CHOICE:-}}"
if [ -z "$CHOICE" ]; then
  if [ -t 0 ]; then
    cat <<EOF
Select model:
  1) Qwen3.8-27B GSQ IQ3_XXS + MTP + vision  (default)
  2) Ternary Bonsai 2 27B PTQ1_0 + vision    (legacy)
EOF
    printf "Enter 1 or 2: "
    read -r CHOICE
  else
    CHOICE=1
  fi
fi

case "$CHOICE" in
  1|gsq|qwen|qwen3.8)
    CHOICE=gsq
    REPO_ID="ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF"
    MODEL_FILE="Qwen3.8-27B-GSQ-RCO-IQ3_XXS-mtp.gguf"
    MMPROJ_FILE="mmproj-Qwen3.8-27B-BF16.gguf"
    ALIAS="Qwen3.8-27B-GSQ-RCO-IQ3_XXS"
    KV_BUDGET=6144; KV_GEN=34816
    KVPOL=()
    EXTRA=(--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-window 4096 --cache-type-k q8_0 --cache-type-v q8_0)
    case "$KV_PROFILE" in
      fast)  KV_BUDGET=4096; KV_GEN=12288; KVPOL=(--kvmem-method recency --kv-window 2048 --kv-sink 512) ;;
      256k)  KV_BUDGET=8192; KV_GEN=4096; KVPOL=() ;;
      default) ;;
      *) echo "invalid KV_PROFILE '$KV_PROFILE' (fast|256k|default)" >&2; exit 2 ;;
    esac
    ;;
  2|bonsai|bonsai-2)
    CHOICE=bonsai
    REPO_ID="prism-ml/Ternary-Bonsai-2-27B-gguf"
    MODEL_FILE="Ternary-Bonsai-2-27B-PTQ1_0.gguf"
    MMPROJ_FILE="Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"
    ALIAS="Bonsai-2-27B"
    KV_BUDGET=12288; KV_GEN=22528
    KVPOL=()
    EXTRA=()
    ;;
  *)
    echo "invalid choice '$CHOICE' (use 1=GSQ, 2=Bonsai)" >&2
    exit 2
    ;;
esac

# Prefer existing /srv/models files, otherwise the install dir.
MODELS="${MODELS:-}"
if [ -z "$MODELS" ]; then
  if [ -f "/srv/models/$MODEL_FILE" ]; then MODELS="/srv/models"; else MODELS="$DEST/models"; fi
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "[dry-run] model=$CHOICE profile=$KV_PROFILE repo=$REPO_ID"
  echo "[dry-run] src=$SRC_DIR build=$DEST/build-sm70 kvmem_root=$KVMEM_ROOT"
  echo "[dry-run] model_file=$MODELS/$MODEL_FILE mmproj=$MODELS/$MMPROJ_FILE"
  echo "[dry-run] alias=$ALIAS kv_budget=$KV_BUDGET kv_gen=$KV_GEN pol=${KVPOL[*]:-none}"
  exit 0
fi

if [ ! -f "$SRC_DIR/CMakeLists.txt" ]; then
  echo "[quickstart] cloning $REPO ($TAG) to $SRC_DIR"
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone --depth 1 --branch "$TAG" "https://github.com/$REPO.git" "$SRC_DIR"
fi

echo "[quickstart] building sm_70 server (CUDA 12.8/12.9, KVMEM_ROOT=$KVMEM_ROOT)"
cmake -S "$SRC_DIR" -B "$DEST/build-sm70" \
  -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=70 \
  -DLLAMA_KVMEM=ON -DLLAMA_KVMEM_ROOT="$KVMEM_ROOT" \
  -DLLAMA_BUILD_SERVER=ON -DGGML_NATIVE=ON
cmake --build "$DEST/build-sm70" -j "$(nproc)" --target llama-server

need=0
for f in "$MODEL_FILE" "$MMPROJ_FILE"; do
  [ -f "$MODELS/$f" ] || need=1
done
if [ "$need" = "1" ]; then
  echo "[quickstart] downloading $CHOICE model files to $MODELS"
  command -v huggingface-cli >/dev/null || python3 -m pip install -U "huggingface_hub[cli]"
  mkdir -p "$MODELS"
  if [ -n "${HF_ENDPOINT:-}" ]; then export HF_ENDPOINT; fi
  huggingface-cli download "$REPO_ID" "$MODEL_FILE" --local-dir "$MODELS"
  huggingface-cli download "$REPO_ID" "$MMPROJ_FILE" --local-dir "$MODELS"
fi

echo "[quickstart] model: $CHOICE ($KV_PROFILE)"
echo "[quickstart] API key: $API_KEY"
echo "[quickstart] endpoint: http://$HOST:$PORT/v1/chat/completions"
export LD_LIBRARY_PATH="$DEST/build-sm70/bin"
RUN=()
if command -v taskset >/dev/null 2>&1 && [ -n "$CPUSET" ]; then RUN=(taskset -c "$CPUSET"); fi
exec "${RUN[@]}" "$DEST/build-sm70/bin/llama-server" \
  -m "$MODELS/$MODEL_FILE" --mmproj "$MODELS/$MMPROJ_FILE" \
  "${EXTRA[@]}" \
  -a "$ALIAS" -c 262144 -ngl 99 -t 24 -np 1 --reasoning on \
  -ub 1024 -b 4096 -fa on --cache-reuse 256 --cache-ram 0 -ctxcp 0 \
  --kvmem --kvmem-budget "$KV_BUDGET" --kvmem-gen-reserve "$KV_GEN" "${KVPOL[@]}" --kvmem-idle-ttl 86400 \
  --host "$HOST" --port "$PORT" --api-key "$API_KEY"