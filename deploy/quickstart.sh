#!/bin/bash
# One-command launcher with model selection.
#   curl -fL https://github.com/Pcx6/prism_llama_kvmem_v100/releases/download/v0.1.0/quickstart.sh | bash
#   curl -fL .../quickstart.sh | bash -s -- 2
#   MODEL_CHOICE=2 ./quickstart.sh
# Environment: DEST, MODELS, PORT, HOST, API_KEY, HF_ENDPOINT, TAG, REPO
set -euo pipefail

TAG="${TAG:-v0.1.0}"
REPO="${REPO:-Pcx6/prism_llama_kvmem_v100}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
DEST="${DEST:-$HOME/.local/opt/prism_kvmem}"
PORT="${PORT:-14803}"
HOST="${HOST:-127.0.0.1}"
if [ -z "${API_KEY:-}" ]; then
  API_KEY="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

CHOICE="${1:-${MODEL_CHOICE:-}}"
if [ -z "$CHOICE" ]; then
  if [ -t 0 ]; then
    cat <<EOF
Select model:
  1) Qwen3.8-27B GSQ IQ3_XXS + MTP + vision  (recommended, ~61 tok/s decode)
  2) Ternary Bonsai 2 27B PTQ1_0 + vision    (legacy, ~34 tok/s decode)
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
    ALIAS="Qwen3.8-27B"
    KV_BUDGET=6144; KV_GEN=12288
    EXTRA=(--spec-type draft-mtp --spec-draft-n-max 2 --cache-type-k q8_0 --cache-type-v q8_0)
    ;;
  2|bonsai|bonsai-2)
    CHOICE=bonsai
    REPO_ID="prism-ml/Ternary-Bonsai-2-27B-gguf"
    MODEL_FILE="Ternary-Bonsai-2-27B-PTQ1_0.gguf"
    MMPROJ_FILE="Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"
    ALIAS="Bonsai-2-27B"
    KV_BUDGET=12288; KV_GEN=22528
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

if [ ! -x "$DEST/bin/llama-server" ]; then
  echo "[quickstart] installing binaries to $DEST"
  mkdir -p "$DEST"
  curl -fL "$BASE/prism_kvmem-$TAG-linux-sm70.tar.gz" | tar xz -C "$DEST" --strip-components=1
fi

need=0
for f in "$MODEL_FILE" "$MMPROJ_FILE"; do
  [ -f "$MODELS/$f" ] || need=1
done
if [ "$need" = "1" ]; then
  echo "[quickstart] downloading $CHOICE model files to $MODELS"
  command -v huggingface-cli >/dev/null || python3 -m pip install -U "huggingface_hub[cli]"
  mkdir -p "$MODELS"
  hf_endpoint="${HF_ENDPOINT:-}"
  if [ -n "$hf_endpoint" ]; then
    export HF_ENDPOINT
  fi
  huggingface-cli download "$REPO_ID" "$MODEL_FILE" --local-dir "$MODELS"
  huggingface-cli download "$REPO_ID" "$MMPROJ_FILE" --local-dir "$MODELS"
fi

echo "[quickstart] model: $CHOICE"
echo "[quickstart] API key: $API_KEY"
echo "[quickstart] endpoint: http://$HOST:$PORT/v1/chat/completions"
export LD_LIBRARY_PATH="$DEST/bin"
exec "$DEST/bin/llama-server" \
  -m "$MODELS/$MODEL_FILE" --mmproj "$MODELS/$MMPROJ_FILE" \
  "${EXTRA[@]}" \
  -a "$ALIAS" -c 262144 -ngl 99 -t 24 -np 1 --reasoning on \
  -ub 1024 -b 4096 -fa on --cache-reuse 256 --cache-ram 0 -ctxcp 0 \
  --kvmem --kvmem-budget "$KV_BUDGET" --kvmem-gen-reserve "$KV_GEN" --kvmem-idle-ttl 86400 \
  --host "$HOST" --port "$PORT" --api-key "$API_KEY"
