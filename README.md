# prism_llama_kvmem_v100 - Prism x KVMem 生产融合说明

[![Release](https://img.shields.io/github/v/release/Pcx6/prism_llama_kvmem_v100)](https://github.com/Pcx6/prism_llama_kvmem_v100/releases)

## 快速安装（一键启动）

```bash
curl -fL https://github.com/Pcx6/prism_llama_kvmem_v100/releases/download/v0.1.0/quickstart.sh | bash
```

脚本会先让选择模型（也可直接传参）：

| 选项 | 模型 | 说明 |
|---|---|---|
| `1`（默认） | Qwen3.8-27B GSQ IQ3_XXS | MTP + 视觉，短文本 decode 约 61 tok/s |
| `2` | Ternary Bonsai 2 27B PTQ1_0 | 旧模型 + 视觉，decode 约 33-35 tok/s |

非交互选择：`curl ... | bash -s -- 2`，或 `MODEL_CHOICE=2 ./quickstart.sh`。GSQ 档可加 `KV_PROFILE=fast`（约 52 tok/s）或 `KV_PROFILE=256k`（256K 精确档）。

要求：Linux x86_64、NVIDIA **sm_70（V100）** 或兼容驱动、Python 3、至少 20 GB 磁盘。
脚本会下载二进制包（约 56 MiB）与所选模型/视觉塔（GSQ 约 10.7 GB，Bonsai 约 6.2 GB），生成随机 API key，并在 `14803` 启动服务。
自定义：`PORT=14803 API_KEY=my-key MODELS=/data/models curl ... | bash`。
手动构建见第 3 节，Release 说明见 [v0.1.0](https://github.com/Pcx6/prism_llama_kvmem_v100/releases/tag/v0.1.0)。
如需在执行前审查脚本内容，请查看 [quickstart.sh](https://raw.githubusercontent.com/Pcx6/prism_llama_kvmem_v100/main/deploy/quickstart.sh) 源码。
Release 资产 `prism_kvmem-v0.1.0-linux-sm70.tar.gz` 的 SHA256：`e2a2e815c09f9e45a69047eade49fa7935177bf6419d60671390ddeb6fac208c`（下载后可用 `sha256sum` 校验）。


本仓库是 Prism（qwen35 架构 27B 三值量化模型）的 llama.cpp 分支，把 KVMem 主机侧 KV 换页适配器编译进 Prism，并在此基础上完成：
请求级检索 span 注入、短上下文短路、前缀复用、多模态视觉、以及生产部署 14803 的运维脚本。

生产入口：`14803`（llama-server，KVMem + Vision，API 名 `Qwen3.8-27B-GSQ-RCO-IQ3_XXS`）→ `14802`（trim_proxy.mjs，裁剪 tool 结果并转发）。

> 2026-11-15：API 模型名已从 `Bonsai-2-27B` 改为 `Qwen3.8-27B-GSQ-RCO-IQ3_XXS`（对应 GSQ IQ3_XXS-mtp 权重）。旧名不再作为别名返回，请更新客户端。


## 0. 仓库说明与获取权重

- 本仓库是 **llama.cpp（MIT）的生产分支**，在此基础上完成 KVMem 适配、短上下文短路、检索、前缀复用、多模态与 TTL，技术细节见后续章节。
- **模型权重不随仓库分发**（`.gitignore` 排除 `*.gguf`），用 `deploy/download-models.sh` 从 Hugging Face 拉取：
  - 语言模型：`prism-ml/Ternary-Bonsai-2-27B-gguf` 中的 `Ternary-Bonsai-2-27B-PTQ1_0.gguf`
  - 视觉塔：同仓库 `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf`
- **KVMem adapter 不在本仓库**：`-DLLAMA_KVMEM=ON` 需要把 `KVMEM_ROOT` 指向 kvmem-root 源码树；不使用 KVMem 时去掉这两个编译选项即可。
- 许可证：MIT（见 `LICENSE`）；上游贡献规范见 `CONTRIBUTING.md`。

### 0.1 仓库结构

| 目录 | 用途 |
|---|---|
| `src/` `common/` `tools/` | llama.cpp 主体及本分支修改 |
| `deploy/` | 启动脚本、代理、模型下载脚本（本分支新增） |
| `docs/kvmem-prism/` | 本分支说明与基准/复现脚本 |
| `README.md` | 本文档（上游 Prism 说明见 `docs/README_PRISM_LLAMA.md`） |
| `LICENSE` / `AUTHORS` / `CONTRIBUTING.md` | MIT 许可证与上游贡献文档 |
| `.github/` | issue / PR 模板 |
| `.env.example` | 环境变量模板 |

### 0.2 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `REPO` | 仓库根 | 脚本根目录 |
| `MODEL` | 必需 | PTQ1_0 gguf 路径 |
| `MMPROJ` | 必需 | 视觉塔 Q8_0 gguf 路径 |
| `API_KEY` | 必需 | 客户端 Bearer token（放在仓库外） |
| `API_KEY_FILE` | - | 存放 API_KEY 的文件路径（示例） |
| `KVMEM_ROOT` | - | kvmem-root 源码路径（仅构建 KVMem 时） |
| `PORT` / `CTX` | 14803 / 262144 | 监听端口 / 上下文 |
| `KV_BUDGET` / `KV_GEN_RESERVE` | 6144 / 34816 | KVMem GPU 池（全注意力默认） |
| `KV_PROFILE` | default | `fast` / `256k` / `default` |
| `CPUSET` | 0-11,24-35 | llama-server 的 CPU 绑定 |
| `KV_TTL` | 86400 | 空闲 KV 清理秒数，0 禁用 |
| `PROMPT_FILE` | 各脚本默认 | 基准脚本的长文本文件 |
| `IMAGE_FILE` | - | 多模态复现脚本的图片路径 |
| `IMAGE_DIR` | - | 示例图片目录 |
| `ARTIFACT_DIR` | - | 本地测试结果归档目录 |

### 0.3 Dependencies & Licenses

| 组件 | 许可证 | 说明 |
|---|---|---|
| `prism_kvmem`（本仓库新增部分） | MIT（`LICENSE`） | 服务器集成、部署脚本、文档 |
| `llama.cpp`（上游） | MIT | 版权见 `AUTHORS`；`LICENSE` 同一份 MIT 文本 |
| PrismML Prism 分支（上游基线） | MIT | 本仓库基于该分支构建 |
| `KVMem adapter` | 未随仓库声明许可证 | `llama-kvmem-hooks.h`、`src/adapter/*` 为独立组件，来源方未提供 LICENSE；启用 `-DLLAMA_KVMEM=ON` 前请与提供方确认许可，本项目不为其再分发授权 |
| 模型权重（Ternary Bonsai 2 27B） | 依 Hugging Face 仓库许可 | 不在本仓库分发，由 `deploy/download-models.sh` 下载 |
| 视觉塔（mmproj Q8_0） | 依上游模型许可 | 同上 |
| Release 二进制 | 含 KVMem `libkvmem` | 仅为个人测试构建；KVMem adapter 许可未明，禁止未经授权再分发或商用 |
| 第三方组件（Yukon tokenizer 等） | 随上游模型 | 见模型仓库的 LICENSE/NOTICE |

若你是 KVMem adapter 的版权方并希望补充具体许可证文本，欢迎提 PR 或在 issue 中说明。

### 0.4 首次准备

推荐直接用 Release 的一键脚本（见文首）。源码方式：

```bash
git clone https://github.com/Pcx6/prism_llama_kvmem_v100.git && cd prism_kvmem
cp .env.example .env          # 填入 MODEL/MMPROJ/API_KEY（.env 已被 .gitignore）
./deploy/download-models.sh   # 默认下载到 models/
set -a; . ./.env; set +a
```


## 1. 生产现状速览

| 项目 | 值 |
|---|---|
| 模型 | `/srv/models/Qwen3.8-27B-GSQ-RCO-IQ3_XXS-mtp.gguf`（10.4 GB，qwen35 hybrid GDN + MTP head，262144 ctx） |
| 视觉塔 | `/srv/models/mmproj-Qwen3.8-27B-BF16.gguf`（931 MB，GPU offload） |
| API 名称 | `Qwen3.8-27B-GSQ-RCO-IQ3_XXS`（启动参数 `-a`；旧别名 `Bonsai-2-27B` 已停用） |
| KVMem | `--kvmem --kvmem-budget 6144 --kvmem-gen-reserve 34816`（GPU 池 40960 token，约 2.5 GiB） |
| 短路阈值 | `0.95 x pool = 38912` token（启用投机解码时不走短路，见 17.4） |
| 显存 | 启动约 13.5 GiB；长输出峰值 14.8 GiB / 16 GB |
| 长文 | 117K 约 549 t/s，226K 约 488 t/s（256K 上下文已验证，换页开启） |
| 短请求 | 代码 700 token decode 61.1 t/s；8 轮 Agent 27.5 s（TTFT 17.9 s） |
| 视觉 | OCR 正常（14802），TTFT 3.9 s，decode 65.2 t/s |
| KV 空闲回收 | `--kvmem-idle-ttl 86400`（1 天）；到期释放 host KV，日志 `KVMEM_IDLE_EVICT` |
| 回滚 | `$REPO/deploy/start-llama-prism.sh`（原生 prism，无 KVMem/视觉） |


## 2. 架构

### 2.1 内存分层

- `llama_memory_kvmem_hybrid`：attention 层用 KVMem 的 slot 池，recurrent（GDN）层保持原生。
- GPU 只保留 `budget + gen_reserve` 个 token 的 KV（槽池），冷块换到主机内存；检索时按 query 打分把需要的块取回。
- 池大小 = `budget + gen_reserve`；高水位 0.95（超过触发换页），低水位收缩回 `budget`。
- 换页/检索打分需要请求级 query span（见 2.2）。

### 2.2 请求级 span 注入与检索

1. `/v1/chat/completions` 取最后一条 user 消息，在渲染后的 prompt 里定位它的 token 区间。
2. 区间截到最近 512 token（与参考驱动 `--kvmem-query-max-tokens` 默认一致）；模板改写导致定位失败时回退到 prompt 末尾 512 token。
3. 在 `launch_slot_with_task` 里调 `llama_kvmem_set_request_span(qbegin, qend, force)`，日志 `KVMEM_REQUEST_SPAN begin=... end=...`。
4. prefill 结束后调 `end_prefill_capture / apply_retrieval / pin_working_set / attention_begin`，把冷块拉回 GPU 再进入生成。
5. 打分用 CUDA 版 page softmax（`KVMEM_PAGE_SOFTMAX_CUDA`）；CPU 版在 256K 上会跑 >10 分钟。

注意：span 只对 `/v1/chat/completions` 注入；`/completion`、`/v1/completions`、infill、`/v1/responses` 等走 prompt 末尾 512 token 回退。定位失败时日志为 `KVMEM_REQUEST_SPAN unavailable`，不会静默。

### 2.3 短上下文短路

- 当请求 token 数 < 池高水位（33075）时，请求完全驻留 GPU，不需要主机镜像：
  - 不注入 span；`begin_cached_turn / truncate_cached` 后立即 `end_prefill_capture`，prefill 不再 capture/harvest K/Q；
  - prefill 结束跳过 `apply_retrieval / pin_working_set / attention_begin`；
  - 日志 `KVMEM_SHORT_BYPASS tokens=...`。
- 跨过阈值（例如 8K 轮次之后接 40K）时日志出现 `KVMEM_BYPASS_EXIT`，强制整体重算一次，保证主机镜像完整。
- 该短路把 8 轮 Agent 从 34.0 s 降到 23-24 s。

### 2.4 前缀复用

- server 用 token 公共前缀算 `n_past`，随后 `llama_kvmem_truncate_cached(n_past)` 对齐 KVMem store，再 `seq_rm` 清原生 KV。
- KVMem 的 `seq_pos_min` 返回的是原生行位置而非逻辑 0，会触发 Prism 的 “无 checkpoint 就整体重算” 分支；已对 KVMem 加守卫，保留前缀复用。
- `--cache-reuse` 对 KVMem 自动禁用（`cache_reuse is not supported by this context`），属设计取舍；多轮收益来自 prompt 前缀复用。

### 2.5 多模态行号（关键修复）

- qwen3vl 的 M-RoPE 下，图像 chunk 的 token 数与位置数不一致：实测 `n_tokens=330, n_pos=22`。
- KVMem 的缓存行按 token 追加，位置只用于 RoPE/掩码；两者必须分开：
  - server 每个 batch 显式携带 `logical_pos`（prompt 行号 = `prompt.n_tokens()`，生成行号连续）；
  - 图像 embedding batch 通过 `mtmd_helper_decode_image_chunk_rows(..., row_0, ...)` 指定起始行；
  - 文本行紧接图像行，RoPE 位置仍按 M-RoPE 推进。
- 该修复消除 “completion leaves a hole or exceeds reservation”（详见第 8 节）。


## 3. 构建

环境：V100 16 GB，CUDA 12.8，sm_70，24 线程。

```bash
cd $REPO
cmake -B build-sm70 \
  -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=70 \
  -DLLAMA_KVMEM=ON \
  -DLLAMA_KVMEM_ROOT=$KVMEM_ROOT \
  -DLLAMA_BUILD_SERVER=ON -DGGML_NATIVE=ON
cmake --build build-sm70 -j 12 --target llama-server
```

产物：`build-sm70/bin/llama-server` 与同目录动态库（`libllama`、`libggml`、`libmtmd`、`libkvmem`）。运行需设置 `LD_LIBRARY_PATH=build-sm70/bin`。

> KVMem adapter 不在本仓库：`KVMEM_ROOT` 指向 kvmem-root 源码树。不启用 KVMem 时去掉 `-DLLAMA_KVMEM=ON` 和 `-DLLAMA_KVMEM_ROOT=...`，其余功能（视觉、OpenAI API）照常构建。


## 4. 运行

### 4.0 快速上手（5 步）

```bash
# 1. 构建（首次或改代码后）
cd $REPO
cmake -B build-sm70 -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=70 \
  -DLLAMA_KVMEM=ON -DLLAMA_KVMEM_ROOT=$KVMEM_ROOT \
  -DLLAMA_BUILD_SERVER=ON -DGGML_NATIVE=ON
cmake --build build-sm70 -j 12 --target llama-server

# 2. 启动推理服务（14803，KVMem + 视觉 + TTL 1 天）
export MODEL=$PWD/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf
export MMPROJ=$PWD/models/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
export API_KEY=$(cat $API_KEY_FILE)
nohup setsid $REPO/deploy/start-llama.sh > fused_prod.log 2>&1 &

# 3. 启动代理（14802，公网入口）
cd $REPO/deploy
TRIM_API_KEY=$API_KEY UPSTREAM=http://127.0.0.1:14803 \
  LISTEN_HOST=0.0.0.0 LISTEN_PORT=14802 nohup setsid node trim_proxy.mjs \
  > trim_14802.log 2>&1 &

# 4. 健康检查
KEY=$API_KEY
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:14803/health   # 200
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:14802/health   # 200

# 5. 发请求
curl -s http://127.0.0.1:14802/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3.8-27B-GSQ-RCO-IQ3_XXS","messages":[{"role":"user","content":"你好"}],"max_tokens":64}'
```

停止服务：`pgrep -a -x llama-server` 找到 pid 后 `kill -9`；代理同理按 LISTEN_PORT=14802 精确杀。
空闲 KV 清理：默认 1 天（`--kvmem-idle-ttl 86400`），会释放 host 内存；不等 TTL 时可用 `POST /slots/0?action=erase` 立即清空（见 4.6）。

### 4.1 生产启动

`$REPO/deploy/start-llama.sh`：

环境变量（必需）：`MODEL`、`MMPROJ`、`API_KEY`；可选：`PORT`（14803）、`CTX`（262144）、`KV_BUDGET`（6144）、`KV_GEN_RESERVE`（34816）、`KV_TTL`（86400）、`THREADS`（24）、`LLAMA_BIN`。

```bash
export MODEL=/path/to/Ternary-Bonsai-2-27B-PTQ1_0.gguf
export MMPROJ=/path/to/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
export API_KEY=$(cat $API_KEY_FILE)
$REPO/deploy/start-llama.sh
```

### 4.2 代理

14802 由 `$REPO/deploy/trim_proxy.mjs` 提供，只裁剪 `role=tool` 的超长内容，不处理图片：

```bash
cd $REPO/deploy
TRIM_API_KEY=$API_KEY UPSTREAM=http://127.0.0.1:14803 \
LISTEN_HOST=0.0.0.0 LISTEN_PORT=14802 \
node trim_proxy.mjs
```

### 4.3 调用示例

```bash
KEY=$API_KEY

# 文本
curl http://127.0.0.1:14802/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3.8-27B-GSQ-RCO-IQ3_XXS","messages":[{"role":"user","content":"你好"}],"max_tokens":64}'

# 视觉（base64 data URL）
python3 docs/kvmem-prism/scripts/test_vision.py --port 14802 --key "$KEY" \
  --image $IMAGE_DIR/微信图片_20261003195102_3_8.png \
  --prompt '逐字提取图片中的全部文字。' --max-tokens 800
```

### 4.4 启停与健康检查

```bash
pgrep -a -x llama-server                 # 生产进程
kill -9 <pid>                            # SIGTERM 有处理器；卡住时用 -9
nohup setsid $REPO/deploy/start-llama.sh \
  > fused_prod.log 2>&1 &

curl -H "Authorization: Bearer $API_KEY" \
  http://127.0.0.1:14803/health      # 期望 200
curl -H "Authorization: Bearer $API_KEY" \
  http://127.0.0.1:14802/health      # 期望 200
nvidia-smi --query-gpu=memory.used --format=csv,noheader   # 期望 9-10 GB
```

### 4.5 回滚

| 目标 | 脚本 |
|---|---|
| 原生 prism（无 KVMem、无视觉，131072 ctx） | `$REPO/deploy/start-llama-prism.sh` |
| 有 KVMem、无视觉 | `（旧部署备份）` |
| 测试实例（14805，融合版） | `PORT=14805 $REPO/deploy/start-llama.sh` |

### 4.6 KV 空闲 TTL 与手动清理

```bash
# 默认 1 天；测试可用 10 秒；0 关闭
--kvmem-idle-ttl 86400     # 生产
--kvmem-idle-ttl 10        # 验证
--kvmem-idle-ttl 0         # 禁用

# 立即清空 slot 0 的 KV（行/块）；host RSS 由 TTL 路径归还
curl -X POST -H "Authorization: Bearer $KEY" \
  "http://127.0.0.1:14803/slots/0?action=erase"
```

- 扫描周期约 1 秒（队列空闲 tick），只处理 `state == IDLE` 的 slot。
- 超时后 `prompt_clear()`（KVMem full reset）+ `malloc_trim(0)`，日志 `KVMEM_IDLE_EVICT reason=idle_ttl idle_ms=... n_tokens=...`。
- 实测释放：64K 会话 RSS 5.63 GB -> 1.27 GB（TTL=5 s）；250K 会话 17.96 GB -> 1.33 GB（TTL=10 s）。
- OOM 兜底：`MemAvailable < 1.5 GB` 或 GPU free < 1 GB 时强制清理 IDLE slot（`reason=oom_guard`）；decode 分配失败时清理并重试一次（`reason=oom_retry`）。
- 说明：GPU KV 池是启动时固定分配（约 2.1-2.2 GB），TTL 释放的是池内行和主机内存，不会把池显存归还驱动。


## 5. 参数选型

> 下表的「默认」是生产脚本 `deploy/start-llama.sh` 的取值；程序内置默认见 `--help`（例如 `--kvmem-budget` 程序默认 32768，生产用 12288）。

### 5.1 budget 扫描（128K 请求，16 GB 卡）

| budget | 启动显存 | 128K 峰值 | 128K prefill / decode | 短路实测 |
|---|---|---|---|---|
| 12288 | 7647 MiB | ~7.9 GB | 741.8 / 53.9 | 819.8 t/s @14.3K |
| 16384 | 7487 | 7901 | 681.5 / 51.3 | 819.8 @14.3K |
| 24576 | 8015 | 8527 | 598.9 / 48.0 | 754.8 @22.5K |
| 32768 | 8543 | 8959 | 541.5 / 45.2 | 30.7K 走短路 |
| 40960 | 9071 | 9503 | 497.7 / 27.3 | 648.9 @38.9K |
| 49152 | 9599 | 10033 | 463.0 / 25.8 | 604.9 @47.1K |

结论：显存在 16 GB 内不是瓶颈，**池越大长文 prefill 越慢**（换页收缩后的注意力窗口 = 池大小）。

### 5.2 14 GB 池实验（按每 GB 收益 5% 规则否决）

| 池大小 | 启动 | 峰值 | 128K prefill/decode | 256K prefill/decode |
|---|---|---|---|---|
| 34816 | 8543 | 8929 | 573.2 / 52.5 | 542.8 / 47.5 |
| 106496 | 13163 | 13605 | 390.8 / 52.6 | - |
| 131072（适配器上限） | 14623 | 15019 | 387.6 / 23.6 | - |
| 114688（上限 - 1 GB） | 13691 | 14379 | ~390 | 315.9 / 48.6 |

9.3 GB -> 14.4 GB 显存增加 5.1 GB，长文 prefill 反而下降 32-42%，负相关，按规则放弃。

### 5.3 最终配置

`--kvmem-budget 12288 --kvmem-gen-reserve 22528`（池 34816，短路阈值 33075）：
32K 以内全走原生快速路径，128K/256K 保留 KVMem 换页，显存 9.3-9.9 GB，留 6 GB 余量。

跨阈值场景（8K -> 40K -> 8K）：8.9 s -> 63.1 s（`KVMEM_BYPASS_EXIT` 整体重算）-> 9.3 s，行为正常。


### 5.4 KVMem 参数（程序默认 vs 生产脚本）

| 参数 | 程序默认 | 生产值 | 说明 |
|---|---|---|---|
| `--kvmem` | off | on | 启用适配器 |
| `--kvmem-budget` | 32768 | 12288 | GPU 工作集 |
| `--kvmem-gen-reserve` | 1024 | 22528 | 生成预留 |
| `--kvmem-block-tokens` | 32 | 32 | 块大小 |
| `--kvmem-sink-tokens` | 0 | 0 | 固定保留前缀 |
| `--kvmem-recent-tokens` | 64 | 64 | 固定保留后缀 |
| `--kvmem-method` | retrieval | retrieval | retrieval/recency |
| `--kvmem-host-mib` | 0 | 0 | host KV 配额，0 不限 |
| `--kvmem-cpu-gb` | 0 | 0 | CPU spill，0 关 |
| `--kvmem-gpu-ratio` | 0 | 0 | 占空闲显存比例，0 由适配器取 0.50 |
| `--kvmem-query-max-tokens` | 512 | 512 | 检索 query 上限 |
| `--kvmem-idle-ttl` | 86400 | 86400 | 空闲清理秒数，0 禁用 |

`harvest_v` 与 `mtp_state` 仍只在 adapter 内部使用，没有 CLI；MTP/投机解码与 KVMem 同时启用会在启动时被拒绝。

## 6. 极限上下文实测（收口）

测试时间 2026-11-06，生产 14803（KVMem 池 34816 + 视觉 + API 名 Bonsai-2-27B），全部经 14802 代理，V100 16 GB。

### 6.1 测试方法

- 每个尺寸独立冷请求：`cache_prompt: false`、`max_tokens: 32`、`temperature: 0`，避免前缀缓存互相影响。
- 指标：prompt_n（实际 prefill token 数）、prefill t/s、TTFT（服务端 prompt_ms）、decode t/s、wall、显存峰值（1.5 s 采样）。
- 热缓存测试：先冷跑一次长 prompt，再在同一 prompt 尾部追加一句短问题（`cache_prompt: true`），只计算新增 token。

### 6.2 冷上下文渐进（8K 到 250K）

| 目标 | prompt_n | prefill t/s | TTFT | decode t/s | wall | 显存峰值 |
|---|---|---|---|---|---|---|
| 8K | 8,244 | 825.2 | 9.99 s | 57.8 | 10.6 s | 10733 MiB |
| 16K | 16,436 | 795.4 | 20.66 s | 53.9 | 21.4 s | 10693 MiB |
| 24K | 24,628 | 742.8 | 33.16 s | 50.3 | 34.0 s | 10733 MiB |
| 32K | 32,820 | 679.9 | 48.28 s | 47.0 | 49.3 s | 10693 MiB |
| 40K | 41,012 | 648.8 | 63.22 s | 54.0 | 64.2 s | 10733 MiB |
| 48K | 49,204 | 621.7 | 79.14 s | 54.0 | 80.2 s | 10733 MiB |
| 64K | 65,588 | 602.0 | 108.95 s | 53.9 | 110.2 s | 10741 MiB |
| 96K | 98,356 | 578.9 | 169.91 s | 53.8 | 171.5 s | 10781 MiB |
| 128K | 131,124 | 564.1 | 232.44 s | 54.3 | 234.4 s | 10703 MiB |
| 192K | 196,660 | 553.1 | 355.57 s | 53.4 | 358.3 s | 10781 MiB |
| **250K** | **250,053** | **546.0** | **457.93 s** | 52.7 | 461.2 s | 10781 MiB |

曲线特征：

- TTFT 近似线性：8K 为 1.21 ms/token，250K 为 1.83 ms/token；250K 冷启动约 7.6 分钟。
- prefill 从 825 t/s 降到 546 t/s（-34%）；32K 及以下走短路（680-825 t/s），33K 以上进入 KVMem 换页（546-649 t/s），**没有断崖**。
- decode 全程 47-58 t/s，与上下文长度基本无关。
- 显存峰值 10.7-10.8 GB，不随长度增长；250K（接近 262144 上限）无 OOM、无 hole。
- 250K 冷启动复测 548.6 t/s / TTFT 455.8 s，与上表一致。

### 6.3 热缓存长上下文 TTFT（同一长对话第二轮）

| 上下文 | cache_n | 新增 token | TTFT | wall |
|---|---|---|---|---|
| 128K | 131,117 | 13 | **1.79 s** | 3.89 s |
| 192K | 196,653 | 13 | **2.56 s** | 5.36 s |
| 250K | 250,046 | 13 | **3.19 s** | 6.58 s |

第二轮只计算 13 个新 token，TTFT 1.8-3.2 s（含 KVMem 截断/检索固定开销），相比冷启动的 231-456 s，这是长对话可用的关键指标。

### 6.4 Agent 8 轮（短请求 + 上下文增长）

| 场景 | 结果 |
|---|---|
| 原生产 14803（原生 prism） | 24.6 s / TTFT 16.3 s |
| 融合 + 短路（当前生产） | 23.1-24.4 s / TTFT 13.6-14.1 s |
| 单轮 prompt 约 1.5K | prefill 750-900 t/s，TTFT 1.1-2.0 s |

### 6.5 视觉

| 图片 | prompt | TTFT | wall | 结果 |
|---|---|---|---|---|
| 简谱 PNG | 1,986 | 3.65 s | 28.6 s | 歌词/标题/调号基本逐字正确 |
| 简谱 JPG | 344 | 0.69 s | 12.1 s | 歌词整段正确 |
| 风景照片 | 2,059 | 3.55 s | 30.9 s | 描述详实，无幻觉 |

未观察到 V100 典型的整行乱码；视觉默认走 GPU（`--no-mmproj-offload` 可切 CPU，慢约 2 倍，作降级方案）。

### 6.6 中断取消

生成 2 秒后断开：服务端在 `n_tokens=185-251` 处停止（max_tokens=5000），GPU 利用率 98% 在 0.4 秒内回落到 0%，下一次请求正常；连续 3 次中断无 hole。

### 6.7 KV 留存、TTL 与内存回收（2026-11-07 新增）

- 参数：`--kvmem-idle-ttl SECONDS`（默认 86400，0 = 永不清理；env `LLAMA_ARG_KVMEM_IDLE_TTL`），生产脚本已加 `--kvmem-idle-ttl 86400`。
- 实现：队列空闲 tick 每约 1 秒触发一次扫描（不依赖 prompt cache）；只清理 `state == IDLE` 的 slot；执行 `prompt_clear()`（KVMem full reset，释放 host raw/块）+ `malloc_trim(0)` 归还内存。
- 日志：`KVMEM_IDLE_EVICT reason=idle_ttl idle_ms=... n_tokens=...`
- 实测（14805 独立实例）：

| 场景 | 请求后 RSS | TTL 清理后 RSS | 释放 | 触发 |
|---|---|---|---|---|
| 64K，TTL=5 s | 5.63 GB | 1.27 GB | 4.36 GB | idle_ms=5001 |
| 250K，TTL=10 s | 17.96 GB | 1.33 GB | 16.6 GB | idle_ms=10002 |
| 小请求（84 token） | - | - | - | idle_ms=5001 |
| TTL=0（禁用） | 不变 | 不变 | 0 | 8 s 内 0 次 evict |
| TTL=86400 + 8 轮 Agent | - | - | 0 | 23.2 s，前缀复用正常 |

说明：GPU KV 池是启动时固定分配（约 2.1-2.2 GB），清理释放的是池内行和主机内存，不会把这块显存归还给驱动；显存占用仍稳定在 9.4-10.8 GB。

OOM 兜底（同一提交）：
- 空闲 tick 检查 `MemAvailable < 1.5 GB` 或 GPU free < 1 GB 时，强制清理所有 IDLE slot 的 KV（`reason=oom_guard`）。
- decode 抛分配异常时，清理 IDLE KV 并重试同一 batch 一次（`reason=oom_retry`），仍失败才报错。

### 6.8 长文检索质量

100K 文档（开头埋 `ORANGE-FALCON-42`）：检索版正确命中；`--kvmem-method recency` 或去掉 `apply_retrieval` 都答错，证明 span+检索生效。


## 7. 已知限制

- GPU 只有一个实例：16 GB 放不下 14803 + 14805 同时运行，灰度/对比需要停生产窗口。
- `--cache-reuse` 对 KVMem 自动禁用；多轮收益依赖 prompt 前缀复用。
- 短路阈值以上（>33075）的请求走 KVMem 换页，8 轮 Agent 若单轮上下文超过 33K 会退回非短路路径，每轮多约 1.2 s。
- M-RoPE 图像批次仍会打印 `find_slot: non-consecutive token position ...`（2D 位置本身非连续，属上游行为），不影响正确性。
- 256K 在池 >34816 时会明显变慢；需要长文速度时保持当前配置。
- server 注册了 SIGTERM 处理器；若进程卡在 decode，仍需 `kill -9`。
- KV 空闲 TTL 默认 1 天，只清理 IDLE slot；GPU KV 池是固定分配，清理不回退池显存，只释放行与主机内存。
- RAM prompt cache / 原生 checkpoint 在 KVMem 下被禁用（避免 store 与原生 KV 不一致），跨请求只有 slot 前缀复用。


## 8. 故障档案

### 8.1 `decode() failed: completion leaves a hole or exceeds reservation`

- 现象：生产 14803 偶发，文本请求命中前缀缓存后被拒绝（`kv_content.cpp:59`）。
- 根因：M-RoPE 图像 chunk 的 `n_tokens` 与 `n_pos` 不一致（330 vs 22）。早期修复用位置基址填图像行，文本批次又不带行号，导致图像行与文本行重叠/错位；KVMem 完成围栏按行号校验，触发 hole。
- 修复（`6b17bfb`）：
  - server 所有 batch 显式携带 `logical_pos`（prompt 行号 + 生成行号连续）；
  - mtmd 新增 `mtmd_helper_decode_image_chunk_rows`，图像行从 `row_0` 起算；
  - 文本行紧接图像行，位置与行号解耦。
- 验证：视觉、图像后文本复用、22K->16.9K 前缀复用、128K、8 轮 Agent 全部无 hole。

### 8.2 KVMem + 多模态直接失败

早期加 `--mmproj` 后图片请求报 `failed to decode mtmd chunk, idx=..., res=1`，日志 `init_batch: failed to prepare KVMem attention ubatches`。
原因：mtmd embedding batch 带 4 维 M-RoPE 位置且首维重复，KVMem 行分配要求一维连续。修复见 8.1（`52318f4` + `6b17bfb`）。

### 8.3 256K 打分卡死

CPU page softmax 在 25 万 token 上跑 >10 分钟。启用 `KVMEM_PAGE_SOFTMAX_CUDA`（编译 `page_softmax.cu`）后打分 <3 s。

### 8.4 前缀复用失效

KVMem 的 `seq_pos_min` 返回原生行位置，触发 Prism 的 checkpoint 回退分支把 `n_past` 清 0。已对 KVMem 加守卫并补 `begin_cached_turn/truncate_cached`，`cache_n` 恢复正常。

### 8.5 纯文本请求报 Context size exceeded / leaves a hole

- 现象：短文本请求偶发 `Context size exceeded`，随后同一会话连续 `completion leaves a hole`；重启后恢复。
- 根因：server 自带的 RAM prompt cache（`--cache-ram`，默认 8192 MiB）和原生 context checkpoint 会保存/恢复**原生 KV 状态**；KVMem 的 store 不在其中，恢复后 token 数、行号和 store 行数分叉（实测恢复后 prompt 16411 token，store 只有 15879 行），KVMem 准备 batch 失败 → 重试到 1 token → Context exceeded → 完成围栏报 hole。
- 修复（`e996c36`）：
  - KVMem 启用时强制关闭 RAM prompt cache 与原生 checkpoint（server 内守卫），启动脚本加 `--cache-ram 0 -ctxcp 0`；
  - 前缀截断在位置删除之后追加 `llama_kvmem_remove_logical` 行级清除，避免媒体行残留。
- 复现：8K 文本 + 图片 + 8K 文本，随后多次更短前缀复用，3 轮即触发；修复后 12/12 请求通过。

### 8.6 客户端点"停止"后 GPU 继续计算

- 现象：Harness 点停止后前端流停止，但 14803 仍全速解码 5000 token，GPU 占用不回落。
- 根因：
  - `trim_proxy.mjs` 未监听客户端断连，客户端走了它仍保持上游连接；
  - llama-server 生成循环从不轮询连接状态，HTTP 层虽然提供了 `req.should_stop`（`is_connection_closed`），但没有传入任务。
- 修复（`b9620c5`，代理同步修改）：
  - 代理：`req.aborted` / `res.close`（未正常结束）时 `upstreamReq.destroy()`，日志 `[abort] #N client closed connection`；
  - server：`server_task` 携带 `should_stop`，`pre_decode()` 发现连接已断立即 `slot.release()`，日志 `client disconnected, releasing slot (n_tokens = ...)`。
- 验证：生成 2 秒后断开，服务端在 n_tokens=185/251 处停止（不是 5000）；GPU 利用率 98% -> 0% 在 0.4 秒内；连续 3 次中断后普通请求与 SSE 均 200，无 hole、无 Context exceeded。

### 8.7 其他

- 服务器有 SIGTERM 处理器；若 decode 阻塞导致无法退出，用 `kill -9`。
- 用 `pkill -f 'trim_proxy.mjs'` 会匹配到执行命令本身，建议按端口/进程号精确杀。


## 9. 代码地图

| 路径 | 作用 |
|---|---|
| `src/CMakeLists.txt` | 编译 KVMem adapter + attention 源 + CUDA page softmax |
| `tools/server/server-context.cpp` | span 注入、短路、前缀复用、行号、KVMem 钩子 |
| `tools/server/server-task.h` | 请求级 span 字段 |
| `tools/server/CMakeLists.txt` | server 侧 KVMEM 头路径与宏 |
| `src/llama-graph.cpp` | 捕获 K/Q、attention 采样入口 |
| `src/llama-batch.{h,cpp}` | `logical_pos` 批量传递 |
| `src/llama-kv-cache.cpp` | 每 cell 的 logical_pos |
| `tools/mtmd/mtmd-helper{,-common.h}` | 图像 batch 的 `logical_pos` 与 row_0 接口 |
| `common/common.cpp` | `--kvmem` 参数与默认值 |
| `common/arg.cpp`, `common/common.h` | `--kvmem-*` 与 `--kvmem-idle-ttl` 参数注册和默认值 |
| `tools/server/server-queue.{h,cpp}` | 队列空闲 tick（驱动 TTL 扫描） |
| `tools/server/server-task.h` | 任务级 `should_stop`（客户端断连） |
| `src/llama-kvmem-hooks.h`（adapter） | `remove_logical` / `truncate_cached` / `store_*` 等钩子 |

主要提交（由旧到新）：

```
035b2dc llama : add name_tag to llama_kv_cache ctor
3551c9b llama : add the PLE conv plane to llama_memory_recurrent
0c460a6 ggml : give ggml_backend_cuda_gdn_fold model-defined head counts
17e3d08 llama : write logical_pos for every applied KV cell
73d0bcb qwen35 : capture pre-RoPE Q and K for KVMem
92d5bbf common : add --kvmem options and set KVMem params before context init
90e5c5d build : compile the KVMem attention sources
2a662fa build : shim the ggml precision setter for the KVMem adapter
089a945 common : find kvmem headers and match the KVMem defaults
0af8e64 graph : capture attention operands for KVMem sampling
b8382e6 server : restore prism oaicompat chat parse (KVMem duplicate broke its return)
6510309 server : inject the KVMem question span before decoding a request
1173aac server : inject the KVMem question span, apply retrieval after prefill, keep prefix reuse
6adcc56 build : enable the CUDA page-softmax retrieval scorer
0873445 server : bypass KVMem capture and staging while the request fits the GPU pool
ada0cbd server : bound the short-context bypass by the pool high watermark
52318f4 mtmd : give image embedding batches monotonic cache rows
12eb9d2 server : skip KVMem prefill hooks when the memory is disabled
6b17bfb fix: resolve completion hole error caused by KVMem logical_pos discontinuity
e996c36 fix: disable native prompt cache and checkpoints under KVMem
b9620c5 server : stop generation when the client disconnects
846ca6b docs : add the KVMem x prism production README and repro scripts
008840f docs : document the prompt cache / checkpoint incompatibility
061ee6d docs : document client disconnect cancellation
5f1bafa docs : add final context-size, TTFT and warm-cache benchmarks
9d2bbc7 server : add KVMem idle TTL eviction and memory pressure guard
```


## 10. 基准与复现脚本

都在 `docs/kvmem-prism/scripts/`：

| 脚本 | 用途 |
|---|---|
| `make_prompts.py` | 生成确定性长文本夹具（128K/250K/100K，无需外网） |
| `bench_128k.py` | 128K prefill/decode（`--port/--key`，默认 14802，冷启动 cache_prompt=false） |
| `bench_256k.py` | 256K prefill/decode |
| `bench_agent_8turn.py` | 8 轮 Agent 轨迹，输出逐轮 TTFT 与总耗时 |
| `bench_quality_100k.py` | 100K 文档开头事实检索（`ORANGE-FALCON-42`） |
| `bench_bypass_cold.py` | 指定 token 数的冷启动短路测试 |
| `test_vision.py` | 图片 OCR/描述，输出 TTFT 与文本 |
| `repro_prefix_reuse.py` | 长请求后短前缀复用（hole 回归；位置参数 port key [ngen]） |
| `repro_multimodal_reuse.py` | 图像请求后文本前缀复用（hole 回归；位置参数 port key，图片用 IMAGE_FILE） |
| `deploy/start-llama.sh` | 通用启动（env：MODEL/MMPROJ/API_KEY） |
| `deploy/start-llama-14803.sh` | 1/2 模型切换 + KV_PROFILE + taskset |
| `deploy/quickstart.sh` | 一键安装/下载/启动（Release 资产） |
| `deploy/start-llama-prism.sh` | 回滚：无 KVMem/视觉，131072 ctx |
| `deploy/trim_proxy.mjs` | 14802 代理（断连中止、tool 裁剪、灰度预留） |
| `deploy/download-models.sh` | 从 Hugging Face 下载模型与视觉塔 |

用法示例：

```bash
python3 docs/kvmem-prism/scripts/bench_agent_8turn.py /tmp/traj.json --port 14802 --key "$KEY"
python3 docs/kvmem-prism/scripts/test_vision.py --port 14802 --key "$KEY" \
  --image $IMAGE_DIR/R-C.jpg --prompt "描述这张图片。" --max-tokens 600
```


## 11. 关键日志速查

| 日志 | 含义 |
|---|---|
| `KVMEM_REQUEST_SPAN begin=... end=...` | 长请求注入了检索 span |
| `KVMEM_SHORT_BYPASS tokens=...` | 走短路（原生快速路径） |
| `KVMEM_BYPASS_EXIT full prefill` | 跨阈值，整体重算 |
| `KVMEM_MTMD n_tokens=... n_pos=...` | 图像 chunk 的 token/位置数 |
| `cache_reuse is not supported by this context` | KVMem 禁用了 cache-reuse（预期） |
| `failed to prepare KVMem attention ubatches` | 行号/位置不一致（8.1/8.2 已修） |
| `completion leaves a hole or exceeds reservation` | 完成围栏拒绝（8.1 已修） |
| `KVMEM_IDLE_EVICT reason=idle_ttl ...` | TTL 到期清理空闲 slot 的 KV |
| `KVMEM_IDLE_EVICT reason=oom_guard/oom_retry ...` | 内存不足兜底清理 |
| `client disconnected, releasing slot` | 客户端断连，服务端停止生成 |
| `[abort] #N client closed connection` | 代理检测到客户端断开并销毁上游请求 |


## 12. 后续建议

1. 若需要 32K 以上的短路，可评估把换页选择窗口与池大小解耦（当前高水位绑定池，窗口会随池增大）。
2. 多模态长对话（超过 33K）目前会退回 KVMem 换页，可观察图像后持续的文本轮次质量。
3. 16 GB 单卡无法双实例，灰度验证建议准备第二块 GPU 或安排维护窗口做全量切换。
4. 视觉若遇到 V100 精度问题，启动加 `--no-mmproj-offload`，并对比同一图片的 OCR 结果。


## 13. 验收结论（2026-11-07 收口）

| 目标 | 结果 |
|---|---|
| KVMem + Prism 融合 | 生产 14803 单实例运行，启动 9395 MiB（含视觉） |
| 超长 250K | prefill 546-549 t/s，TTFT 456-458 s，无 OOM / 无 hole |
| 128K | prefill 564-568 t/s，TTFT 231-232 s |
| 常用 16K / 32K / 64K | 795 / 680 / 602 t/s，TTFT 20.7 / 48.3 / 109.0 s |
| 热缓存长上下文 | 128K/192K/250K 第二轮 TTFT 1.79 / 2.56 / 3.19 s |
| 8 轮 Agent | 23.1-24.4 s，总 TTFT 13.6-14.1 s |
| 多模态 | OCR 与图片描述正确，TTFT 0.93-3.65 s |
| 中断取消 | 2 s 断开后 0.4 s 内 GPU 98% -> 0%，slot 立即释放 |
| 稳定性 | 修复后 0 `hole`、0 `Context size exceeded`、0 `prepare_reject` |
| 长期运行 | 单卡 16 GB，显存峰值 10.8 GB，余量 5 GB+ |
| KV 空闲回收 | TTL 到期后 250K 会话 RSS 17.96 GB -> 1.33 GB（释放 16.6 GB）；TTL=0 可禁用 |


## 14. 上传 GitHub 前检查

本仓库已做以下准备：

- **秘密**：仓库内不含 API key；`API_KEY` 通过环境变量或仓库外的 `api_key.txt` 提供，`.gitignore` 已排除 `api_key.txt`、`*.key`、`.env`（`.env.example` 保留）。
- **权重**：`*.gguf` 默认忽略；`git ls-files '*.gguf'` 只应列出上游词表夹具 `models/ggml-vocab-*.gguf`。
- **构建产物**：`build-sm70/` 已从索引移除；`.gitignore` 覆盖 `/build*/`、`*.so`、`*.o`、日志与运行状态。
- **许可证**：MIT（`LICENSE`），上游 `AUTHORS` / `CONTRIBUTING.md` 保留。
- **当前体积**：跟踪文件约 160.5 MB（主要来自 `models/` 词表夹具与 `docs/ops/`）；`.git` 约 35 MB（2026-11-07 已用 filter-repo 清理 `build-sm70` 历史）。

上传前建议自查：

```bash
git grep -n -E 'api_key|Bearer [A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{16,}' -- .
git ls-files '*.gguf' | head
git ls-files -z | xargs -0 du -h | sort -rh | head -10
```

历史已在 2026-11-07 清理（`git filter-repo --path build-sm70 --invert-paths`）；旧 commit hash 已失效。如需再次清理，先做完整备份。

或只推送一个干净的 squash 分支：

```bash
git checkout --orphan clean-main
git add -A && git commit -m "Import KVMem x Prism production fork"
git push -u origin clean-main     # 分支名按需修改
```

## 15. 双后端路由（14803 Prism / 14806 1Cat-vLLM）

14802 代理支持按请求选择后端。**默认 `prism_only`，1Cat 不接生产流量。**

### 15.1 配置

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `ROUTING_MODE` | `prism_only` | `prism_only` 全走 14803；`auto` 启用自动规则 |
| `VLLM_UPSTREAM` | `http://127.0.0.1:14806` | 1Cat-vLLM 地址 |
| `VLLM_MAX_LEN` | `8192` | auto 模式下超过该 token 估算值走 Prism |

### 15.2 路由规则

| 条件 | 后端 | 说明 |
|---|---|---|
| Header `x-backend: 1cat` / `vllm` | 14806 | 强制测试 1Cat |
| Header `x-backend: prism` | 14803 | 强制 Prism |
| `model` = `1cat-vllm` / `qwen3.8-27b` | 14806 | 仅 `auto` |
| Header `x-mtp: 1` 或 body `mtp: true` | 14806 | 仅 `auto`，MTP 请求 |
| 包含图片/音频/视频内容 | 14803 | 仅 `auto`；多模态归 Prism |
| 估算 token > `VLLM_MAX_LEN` | 14803 | 仅 `auto`；长上下文归 Prism |
| `stream: true` 且短请求 | 14806 | 仅 `auto` |
| 其它 | 14803 | 默认 |

响应头带 `x-backend: prism|vllm`，便于调试。SSE 流式原样透传。

### 15.3 当前状态（2026-11-14）

- 1Cat-vLLM **未部署**：GitHub release 资产下载被限速（285 MB wheel 约 160 KB/s），且 wheel 要求 Python 3.12 + Torch 2.10（本机仅 3.13）；GGUF 支持需 1Cat 开发版源码构建。
- 模型已就绪：`/srv/models/Qwen3.8-27B-GSQ-RCO-IQ3_XXS.gguf`（10,094,357,632 字节，经 HF 镜像下载）。
- 单卡 16 GB 无法双驻留：Prism 启动约 9.4 GB + IQ3_XXS 权重 10.1 GB = **19.5 GB**，超过红线 15.5 GB；1Cat 另需 KV/激活显存。
- 因此 `ROUTING_MODE=prism_only`，`x-backend: 1cat` 在 14806 未启动时返回 502（符合预期）。

### 15.4 启用条件

1. 安装 1Cat-vLLM（CPython 3.12 + Torch 2.10 + CUDA 12.8），启动 `--port 14806 --api-key <same-key>`。
2. 显存方案：第二块 GPU，或单独运行（停止 Prism）后把 `ROUTING_MODE=auto` 或使用 `x-backend: 1cat` 测试。
3. 切换前先做短文本并发、长文本、多模态回归；确认后再改 `ROUTING_MODE`。

## 16. 生产模型切换：Qwen3.8-27B IQ3_XXS（2026-11-14，历史记录）

> 本节记录当时的切换过程；当前生产配置见第 17 节与第 25 节（MTP draft window、全注意力池 6144/34816）。

### 16.1 最终配置

- 模型：`/srv/models/Qwen3.8-27B-GSQ-RCO-IQ3_XXS.gguf`（10.1 GB，文本，无 mmproj）
- API 别名：`Qwen3.8-27B-GSQ-RCO-IQ3_XXS`（旧 `Bonsai-2-27B` 已停用，客户端需改 model 字段）
- `-c 262144 -ngl 99 -t 24 -np 1 --reasoning on -ub 1024 -b 4096 -fa on --cache-reuse 256`
- `--cache-ram 0 -ctxcp 0`
- `--kvmem --kvmem-budget 8192 --kvmem-gen-reserve 12288 --kvmem-idle-ttl 86400`（池 20480 token，64 KiB/token ≈ 1.25 GiB，短路阈值 19456）
- `--host 0.0.0.0 --port 14803 --api-key "$KEY"`
- 回滚：`cp /srv/llama_agent/start-llama-14803.sh.bak-bonsai /srv/llama_agent/start-llama-14803.sh`

### 16.2 实测

| 场景 | 结果 |
|---|---|
| 短文本 chat | 200，Qwen 正常回答 |
| 8 轮 Agent | 30.0 s，总 TTFT 16.4 s，prompt 约 635-669 t/s，生成约 31-32 t/s |
| 128K | prompt_n=106254，prefill 601.1 t/s，wall 179.4 s，峰值 12341 MiB |
| 226K（256K 夹具） | prompt_n=226362，prefill 588.9 t/s，wall 388.9 s，峰值 12977 MiB |
| 100K 检索 | 90K prompt，603.8 t/s，正确返回 ORANGE-FALCON-42 |
| 断连取消 | 2 s 断开，GPU 立即 0%，slot 释放，后续请求 200 |

### 16.3 注意事项

- 代理原有 120 s 请求超时会打断 128K/256K prefill；已改为 `req.setTimeout(0)` 且 `server.requestTimeout=0`。
- 基准脚本必须显式 `cache_prompt=false`；否则会复用上一个 226K 请求前缀，导致 `Context size has been exceeded`。`bench_quality_100k.py` 已修正。
- 池 20480 表示 32K 请求走 KVMem 换页（阈值 19456），不再有 33K 原生短路；如需更大短路池，可在峰值余量内提高预算并重新压测。
- 14802 保持 `ROUTING_MODE=prism_only`，双后端路由保留备用。

## 17. MTP 投机解码 + 视觉（2026-11-15）

### 17.1 最终配置

- 模型：`Qwen3.8-27B-GSQ-RCO-IQ3_XXS-mtp.gguf`（含 nextn MTP head）+ `mmproj-Qwen3.8-27B-BF16.gguf`
- `--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-window 4096`；`--cache-type-k q8_0 --cache-type-v q8_0`
- `--kvmem --kvmem-budget 6144 --kvmem-gen-reserve 34816`（池 40960，短路阈值 38912）
- 启动：`deploy/start-llama-14803.sh 1`（或 `KV_PROFILE=fast|256k`）
- `--reasoning on` 全程保留；`-c 262144 -fa on -ub 1024 -b 4096`
- 回滚：`cp /srv/llama_agent/start-llama-14803.sh.bak-qwen38 /srv/llama_agent/start-llama-14803.sh`

### 17.2 关键结果

| 场景 | 结果 |
|---|---|
| 700 token 代码（含思维链） | **61.1 tok/s**，draft 接受率 73.3% |
| 8 轮 Agent（14802） | 27.5 s，TTFT 17.9 s，后段 49-50 tok/s |
| OCR（14802） | 文字正确，TTFT 3.9 s，65.2 tok/s |
| 117K ORANGE 检索 | prefill 548.6 tok/s，decode 61.7 tok/s，正确返回 |
| 226K | prefill 487.8 tok/s，峰值 14951 MiB，draft 在深上下文空闲 |
| 断连 | GPU 立即 0%，slot 释放，后续 200 |

### 17.3 参数矩阵（700 token，T=0）

| n-max | KV | pool | tok/s | 接受率 | 峰值 MiB |
|---|---|---|---|---|---|
| off | f16 | 20480 | 33-35 | - | 12977 |
| 1 | f16 | 20480 | 55.9 | 79.7% | 13841 |
| 2 | f16 | 20480 | 59.1 | 67.5% | 13993 |
| 3 | f16 | 20480 | 56.8 | 56.8% | 14145 |
| 2 | q8_0 | 20480 | 61.0 | 73.3% | 13375 |
| 2 | q8_0 | 18432 | **61.2** | 73.3% | 13291 |

结论：n-max 2 + q8_0 + 池 18432 最优；视觉同时开启不影响短文本速度。

完整数据：`/srv/llama_agent/logs/final_bench.md`。

## 18. 一键切换模型（2026-11-15）

### 18.1 生产 14803

仓库内：`deploy/start-llama-14803.sh [1|2]`

| 参数 | 模型 | 默认 KVMem 池 | 特性 |
|---|---|---|---|
| 1（默认） | Qwen3.8-27B GSQ IQ3_XXS-mtp + mmproj BF16 | 6144 + 34816 | MTP n-max 2 + draft window 4096、q8_0 KV、视觉、reasoning |
| 2 | Ternary Bonsai 2 27B PTQ1_0 + mmproj Q8_0 | 12288 + 22528 | 无投机、视觉、reasoning |

GSQ 档支持 `KV_PROFILE`：

| KV_PROFILE | KVMem 池 | Decode | 用途 |
|---|---|---|---|
| `default` | 6144 + 34816 | 34-57 tok/s | 全注意力、23K+ 长输出 |
| `fast` | 4096 + 12288 | 约 52 tok/s | window 2048，日常对话 |
| `256k` | 8192 + 4096 | 约 34 tok/s | 256K 精确档，输出上限约 4K |

用法：

```bash
API_KEY_FILE=/srv/llama_agent/api_key.txt ./deploy/start-llama-14803.sh 1
MODEL_CHOICE=2 API_KEY=... ./deploy/start-llama-14803.sh
KV_PROFILE=fast API_KEY_FILE=... ./deploy/start-llama-14803.sh 1
DRY_RUN=1 API_KEY=x ./deploy/start-llama-14803.sh 1
```

- `API_KEY` 或 `API_KEY_FILE` 二选一；脚本不内置 key
- `MODEL_DIR` 默认 `/srv/models`，可用 `GSQ_MODEL` / `BONSAI_MODEL` / `MMPROJ` 覆盖
- `CPUSET` 默认 `0-11,24-35`，`PORT` 默认 14803
- 生产机仍可用 `/srv/llama_agent/start-llama-14803.sh` 包装同一组参数；备份 `.bak-qwen38` / `.bak-bonsai`

### 18.2 公开一键脚本

`deploy/quickstart.sh`（Release 资产同名）支持 1/2 选择、交互菜单、`bash -s -- N` 与 `MODEL_CHOICE`；GSQ 档支持 `KV_PROFILE=fast|256k|default`，默认 `--spec-draft-window 4096`、池 6144/34816、q8_0 KV；可用 `CPUSET` 绑定 CPU。模型缺失时从 Hugging Face 下载，`/srv/models` 已有文件时直接复用。

### 17.4 长输出中断修复（2026-11-15）

- 现象：网页端输出到约 10K/3K token 停止，报 `Stream resume produced no new bytes`；服务端日志为 `Context size has been exceeded` / `failed to find a memory slot`，总 token 约 16-17K。
- 原因：KVMem 池 18432（阈值 17510）；WebUI 默认 `max_tokens=-1`，旧短路判据只看 prompt，prompt < 17.5K 即走原生短路（无 host mirror）；prompt+生成超过池上限后无法继续分配 slot，流结束且 UI 续传拿到空。
- 修复（2026-11-15 二次）：根因是 **MTP 投机解码 + 原生短路径** 的 batch 索引异常（`speculative batch index 1 is not inside the current sub-batch [0, 1)`），随后 KVMem 报 `block 448 has no GPU slot`、`Context size has been exceeded`。现在只要启用投机解码，就禁用原生短路，强制走 KVMem 分页路径；同时 `n_predict <= 0` 时按 `gen_reserve` 预留生成空间。
- 验证：强制生成 12000 token（`ignore_eos`）成功，55.1 t/s，无 speculative/context 错误；8 轮 Agent 38.6 s（TTFT 29.0 s，decode 46.8 t/s）；短请求不再走短路（`KVMEM_SHORT_BYPASS` = 0）。
- 追加（2026-11-15）：`gen_reserve` 从 12288 提高到 **18432**（池 24576），解决生成阶段 slot 容量不足；经 14802 实测 12000 token 输出成功（54.8 t/s），16K 测试也通过（54.1 t/s），无 `no GPU slot` / `Context size exceeded`。
- 再次追加：18000 token 级 prompt + 12000 token 输出仍会撞到 22.5K 级 slot 上限；`gen_reserve` 进一步提升到 **26624**（池 32768）。经 14802 实测 16202 prompt + 12000 输出 = 28202 token 成功（33.4 t/s），无 slot/context 错误；256K prompt 仍可正常预填（487.8 t/s）。
- 2026-11-15 最终：22000 token 级输出仍会撞 22K slot 上限；`gen_reserve` 提升到 **34816**（池 40960，约 2.5 GiB）。实测 25000 token 输出成功（55.3 t/s），视觉 GPU 正常（OCR 6.8 s），峰值 14785 MiB。

## 19. 128K Decode 调优（双路 Xeon 6146 / DDR4-2133 / V100，2026-11-15）

测试方法：128K prompt（106254 token），生成 128 token，取 `predicted_per_second`；所有配置均重跑 prefill+decode。

| 配置 | Decode tok/s | Prefill tok/s | 峰值 MiB |
|---|---|---|---|
| 基线（现有生产） | 34.48 | 446.6 | 14873 |
| taskset node0 CPU | 34.51 | 446.8 | 14873 |
| + `--no-mmap` | 34.61 | 447.8 | 14875 |
| + 视觉塔 CPU | 34.61 | 448.0 | 13735 |
| 池 57344 + 视觉 CPU | 33.93 | 368.9 | 14453 |
| 池 65536 + 视觉 CPU | 34.07 | 360.2 | 14727 |
| 关闭 MTP | 34.52 | 386.8 | 13313 |
| MTP n-max 1 | 34.34 | 361.6 | 14577 |

结论：

- 128K Decode 稳定在 **34.3-34.6 tok/s**，瓶颈是 V100 上 27B 模型的长上下文 attention/带宽，不是 NUMA、池大小或 MTP；扩大池只降低 prefill（hash/换页开销）。
- **Docker 内无法使用 NUMA 策略**：`numactl --cpunodebind/--membind` 返回 `This system does not support NUMA policy`；只能 `taskset` 绑定 node0 CPU（0-11,24-35），对 GPU decode 无可见收益（prefill +0.2 t/s）。
- `--no-mmap` 在本 fork 已标记 deprecated，收益在噪声范围内，最终生产未启用。
- `--kv-evict-sink/window`（PR #27583）在本 fork 中不存在，未移植；如需要需单独打补丁。
- 最终生产保留视觉塔 GPU（OCR 6.8 s），池 40960，MTP n-max 2；启动脚本加 `taskset -c 0-11,24-35`。

## 20. KVMem 窗口驱逐与 128K Decode（2026-11-15）

### 20.1 1Cat-vLLM 源码审计

克隆 `1CatAI/1Cat-vLLM`（204 MB，depth 1）检查后确认：

- 没有通用的 `--kv-evict-sink/window` / StreamingLLM 实现；`vllm/config/sm70_sparse.py` 是 QSA/indexer 等**模型原生稀疏注意力**策略，只对支持该结构的模型生效。
- 其 V100 长文加速主要来自 SM70 attention kernel、XQA/page4、split-K 等，移植成本高，且不适用于 Qwen3.8 的 dense/GDN 结构。
- 因此改在现有 KVMem 上做窗口驱逐，不引入 1Cat 的滑动注意力。

### 20.2 KVMem 原生窗口

新增 CLI 别名（映射到 KVMem sink/recent 策略）：

- `--kv-window N` = `--kvmem-recent-tokens N`：保留最近 N token
- `--kv-sink N` = `--kvmem-sink-tokens N`：保留开头 N 个 attention sink
- 配合 `--kvmem-method recency` 与池 16384（budget 4096 + gen 12288）

### 20.3 128K Decode 结果（106254 prompt，生成 128）

| 配置 | Decode tok/s | Prefill tok/s | 备注 |
|---|---|---|---|
| 旧全注意力 + 池 40960 | 34.5 | 446 | MTP 深上下文空闲 |
| 池 16384 retrieval（偶发 draft 错误） | 54.4 | 566 | 不稳定，draft_impl 报错 |
| recency + window 8192 / sink 1024 | 46.5 | 598 | 稳定，质量通过 |
| recency + window 4096 | 46.4 | 599 | 稳定 |
| recency + window 2048 / sink 512 | **52.2**（生产 14802） | 584 | 稳定，质量通过 |
| recency n-max 3 | 45.1 | 598 | 更慢 |

质量验证（100K 文档）：开头 sink `ORANGE-FALCON-42` 与结尾 window `BLUE-MONKEY-99` 均正确回答；96K prompt 下 decode 55.1 t/s，无 `draft_impl` / slot 错误。 生产回归：OCR 7.9 s 正确；8 轮 Agent 31.2 s（TTFT 21.2 s，decode 47.3 t/s）；显存 12.9 GiB。

### 20.4 取舍

- 窗口模式 gen_reserve=12288，单次输出约 12K token 上限；需要 20K+ 长输出时用 `KV_PROFILE=long /srv/llama_agent/start-llama-14803.sh 1`（池 40960，decode 34.5）。
- 窗口模式下游标超出 sink/window 的信息不可见，这是 StreamingLLM 的理论代价。
- 视觉塔仍 GPU（OCR 正常），短文本/Agent 未退化。

## 21. Window/Sink 扫描（三针基准，2026-11-15）

语料：约 84827 token 纯文本，三个唯一暗号分别为 `SINK-PINEAPPLE-77`（开头）、`MIDDLE-DRAGON-88`（约 42K token）、`WINDOW-BANANA-99`（结尾）。固定 Sink=512、池 16384、MTP n-max 2、`--kvmem-method recency`，逐个重启 14805 测试。

| 组 | Window | Prefill tok/s | Decode tok/s | 暗号数 | 显存峰值 MiB |
|---|---|---|---|---|---|
| A | 2048 | 571.3 / 574.5 / 573.4 | 55.01 / 55.07 / 54.93 | **3 / 3 / 3** | 13189 |
| B | 4096 | 591.9 | 55.57 | 2 | 13189 |
| C | 8192 | 591.7 | 55.56 | 2 | 13189 |
| D | 16384 | 592.2 | 55.58 | 2 | 13189 |
| E | 32768 | 593.2 | 55.56 | 2 | 13189 |

结论：

- 在 16K 池 + MTP 下，Window 从 2048 到 32768 **Decode 都在 55 t/s 左右**，窗口大小不再是速度变量；速度收益来自小池 + recency + MTP。
- 质量呈非单调：2048 三次均准确列出三个暗号（含中间 42K），4096-32768 反而只列出 Sink 与 Window 两个。该现象与 KVMem 的 block 选择/驻留有关，已按实测数据选择 **Window 2048 + Sink 512**。
- Sink 红线满足：所有组 `SINK-PINEAPPLE-77` 均命中。
- 生产配置已是 A 组，无需改脚本；峰值 13.2 GiB。

## 22. 256K 全注意力与混合精度 KV（2026-11-16）

### 22.1 兼容性（14805，短请求）

| K/V 类型 | HTTP | 异常 |
|---|---|---|
| f16/f16 | 200 | 无 |
| q8_0/f16 | 200 | 无 |
| q8_0/q8_0 | 200 | 无 |
| q4_0/q8_0 | 200 | 无 |

KVMem 换页在四种精度下均无 hole/段错误。

### 22.2 250K 全注意力（261503 token，池 12288，MTP n-max 2）

| K/V | Prefill tok/s | Decode tok/s | 暗号 | 显存峰值 MiB |
|---|---|---|---|---|
| f16/f16 | 606.4 | 34.54 | 3/3 | 14581 |
| q8_0/f16 | 624.5 | 33.75 | 3/3 | 14375 |
| **q8_0/q8_0** | 591.1 | **33.98** | **3/3** | **14197** |
| q4_0/q8_0 | 629.3 | 32.53 | 3/3 | 14133 |

暗号：`START-ULTRA-256`、`MIDDLE-ULTRA-256`（约 125K）、`END-ULTRA-256`。四种精度全部命中三个，说明 256K 全注意力链路可用。

量化没有提速：q8_0/q8_0 与 f16 基本持平（33.98 vs 34.54），q4_0 反而最慢（32.53），V100 的反量化开销抵消了带宽收益。

### 22.3 16K 窗口 + q8_0（250K）

- 池 32768、recency、window 16384、sink 512
- Prefill 477.2 tok/s，Decode **41.7 tok/s**
- 暗号 **2/3**（START + END，MIDDLE 丢失）

### 22.4 结论与生产

- 绝对准确：`q8_0/q8_0` 全注意力，256K Decode 约 34 tok/s，3/3 暗号，显存 14.2 GiB。
- 高吞吐：16K 窗口 41.7 tok/s，但丢中间记忆；2K 窗口 52 tok/s，仅适合短记忆任务。
- 生产默认已恢复为**原版全注意力**：`--kvmem-budget 6144 --kvmem-gen-reserve 34816`（池 40960）、q8_0/q8_0、无窗口，兼顾 256K 上下文与 23K+ 长输出。
- 256K 精确档可用 `KV_PROFILE=256k`（池 12288，gen 上限 4K）；高速档 `KV_PROFILE=fast`（window 2048，约 52 t/s）。
- 保留 `KV_PROFILE=fast`（window 2048，52 t/s）与 `KV_PROFILE=long`（池 40960，长输出）。

## 23. FP8 KV 支持尝试（2026-11-17，未上线）

目标：KV Cache 用 FP8 E4M3 存储（1 byte/element），attention 时反量化到 FP16，走 V100 原生 FP16 tensor core。

已实现的原型（已回滚，未进入 main）：

- `GGML_TYPE_FP8_E4M3 = 145`，block=1，type_size=1；CPU `quantize_row_fp8_e4m3_ref` / `dequantize_row_fp8_e4m3`（含 E4M3 编码/解码与饱和）。
- type traits、`ggml_quantize_chunk`、CPU `type_traits_cpu.from_float`、`--cache-type-k/v fp8_e4m3` 解析。
- CUDA：`f32<->fp8` copy kernel、`fp8->f16/f32` dequant dispatch、`SET_ROWS` 量化写入、`ggml_cuda` SET_ROWS supports_op。
- 模型可完成加载阶段，但首次 decode 崩溃。

阻塞点（gdb 回溯）：

```
SIGSEGV at 0x0
#1 ggml_compute_forward_flash_attn_ext (libggml-cpu.so)
#2 ggml_graph_compute_thread
```

1. CUDA 侧 FlashAttention 没有 FP8 的 K/V 模板实例（`fattn-mma-f16` 只有 F16/Q4_0/Q8_0 的 `type_KV`），scheduler 因此把 attention 回退到 CPU。
2. CPU FlashAttention 需要 FP8 的 `vec_dot`/类型支持，当前为空函数指针，直接段错误。
3. 要补齐需新增 FP8 的 FA tile loader（32 字节/块反量化到 half）以及整套 `fattn-mma-f16-instance-fp8_0-*` 模板实例，属于多小时的 kernel 工程。

性能判断：V100 sm70 无 FP8 硬件，所有路径都要软件反量化；此前 q4_0 KV 已因反量化比 q8_0 慢（32.5 vs 34.0 t/s），FP8 预计同样不会提速，只会增加复杂度。

结论：**不部署 FP8**；生产保持 `q8_0/q8_0` 全注意力 256K（约 34.2 t/s，三暗号 3/3）。如后续确需 FP8，先补 CUDA FA FP8 实例并做 dequant 开销评估。

## 24. 根因剖析：计算、HBM 还是主机内存（2026-11-17）

测试条件：Qwen3.8-27B IQ3_XXS + MTP，V100 16GB，q8_0/q8_0 KV，全注意力，池 40960（除注明），生成 256 token，nvidia-smi 每 0.5 s 采样，取 decode 窗口平均。

| 场景 | Decode tok/s | Draft | GPU util | HBM util | 功耗 W |
|---|---|---|---|---|---|
| 2K 上下文，关闭 MTP | 36.7 | 0 | 98.1% | 53.3% | 272 |
| 2K 上下文，MTP | 51.4 | 134/241 | 78.3% | 39.0% | 229 |
| 16K，MTP | 35.3 | 0 | 92.3% | 51.9% | 266 |
| 64K，MTP | 35.3 | 0 | 93.2% | 52.0% | 275 |
| 106K，MTP | 35.1 | 0 | 93.0% | 51.7% | 270 |
| 106K，池 16384，MTP | 54.9 | 145/218 | 82.0% | 40.7% | 244 |
| 250K，q8/q8 全注意力 | 34.2 | 0 | — | — | — |
| 250K，f16/f16 全注意力 | 34.5 | 0 | — | — | — |
| 250K，q4_0/q8 | 32.5 | 0 | — | — | — |

模型 9.8 GB；35 tok/s 时权重读取约 343 GB/s，加 40K resident KV（约 2.5 GiB）约 94 GB/s，合计约 437 GB/s ≈ V100 HBM 峰值（900 GB/s）的 48%，与 `utilization.memory` 52% 吻合。MTP 55 tok/s 时每个 target step 摊到约 1.6 个输出 token，权重+KV 总带宽仍在 430-450 GB/s 量级。

结论：

1. **不是 VRAM 带宽打满**：HBM 利用率仅约 52%，且 KV 从 q8_0 换成 f16（KV 字节翻倍）decode 几乎不变（34.0 vs 34.5），q4_0 反而更慢（32.5）。说明 decode 不靠 KV 字节带宽，KV 量化不会提速。
2. **不是主机 DDR4 带宽**：KVMem 的 offload/retrieval 只发生在 prefill 和 prefill 结束，decode 期间 resident 集合已 pin 在 GPU，没有主机内存读写。DDR4-2133 只影响 prefill/TTFT。
3. **主因是单 token GEMV 的指令/功耗受限**：非 MTP decode 时 SM util 93-98%、功耗 270-275 W（V100 300 W 上限），HBM 只有 52%。batch=1 的 GEMV 无法喂满 tensor core，算力/调度而非流带宽是瓶颈。2K 与 256K 的非 MTP 速度几乎相同（36.7 vs 34.2），也证明上下文 KV 不是主变量。
4. **MTP 是最大杠杆**：MTP 让一次权重读取产出约 1.6 个 token，SM util 降到 78-82%、功耗 229-244 W，decode 提升到 51-55 tok/s。长期停在 34-35 的真正原因是 MTP 在长上下文/大 resident 集合下没有生效（draft_n=0 或 draft 报错），不是带宽。

## 24.1 KVMem 卸载机制与时机

代码路径（`tools/server/server-context.cpp`、`src/kvmem-root/src/adapter/llama-memory-kvmem.cpp`）：

- **Prefill 追加**：每个 ubatch 的新 token 写入 host KV store；当 `resident_tokens > 0.95 * pool` 或空闲 slot 不足时，`register_append` 触发 `KVMEM_PRESSURE phase=prefill`，用 retrieval 分数（或 recency + sink/recent 固定块）选出保留块，其余 GPU→host 卸载并释放 slot。
- **Prefill 结束**：server 在 `SLOT_STATE_DONE_PROMPT` 调用 `llama_kvmem_end_prefill_capture` → `llama_kvmem_apply_retrieval`（用最后一个问题对全部 host 块打分）→ `llama_kvmem_pin_working_set`，把选中的块 host→GPU stage in，然后才开始生成。这一段计入 TTFT，不计入 decode。
- **Decode 期间**：每个新 token 追加到 store，但使用 `gen_reserve` 预留的 slot；只要生成长度 < `gen_reserve` 且没有碎片，**不发生卸载/换入**。一旦超过预留（此前的 22K 输出问题），会在 decode 中触发 `KVMEM_PRESSURE phase=decode`，产生主机/PCIe 流量并可能 slot 耗尽。
- **传输量**：q8_0 KV 约 64 KiB/token（K+V 全部层）。prefill 卸载量约 `(prompt - pool) * 64 KiB`，retrieval 约 `pool * 64 KiB`；例如 106K prompt、40K 池约 4.1 GiB 写出 + 2.5 GiB 读回，PCIe 上合计约 0.5 s，相对 3-4 min prefill 很小。

因此：主机内存/DDR4 带宽和 PCIe 主要影响 **prefill 与首 token 延迟**；持续 decode 的 34-35 tok/s 是 GPU 单 token 执行效率问题，靠 NUMA/DDR 优化不会有明显收益。

## 25. MTP 长上下文修复：保留 draft 尾部窗口（2026-11-17）

### 根因

不是模型在长上下文主动关闭 MTP，而是 KVMem 检索后的驻留集合缺少 draft 需要的目标 slot：

- MTP follower 的 `fill_from_target()` 用 `target_->slot_for_orig_pos(pos)` 把草稿 KV 列映射到 target 的 GPU slot。
- prefill 结束时 `apply_retrieval` 只保留问题相关块和 `recent_tokens`；默认 `recent_tokens=64`。
- draft 的 catch-up 行包含约 3.8K token 之前的位置；这些位置已被换出，`no target slot for pos 102400`，`llama_decode[0]` 返回 1，draft 被放弃，`draft_n=0`，速度回落到 34-35 t/s。

### 修复

新增 `--spec-draft-window N`（默认 4096，0 = 关闭）：启用 MTP 时强制 KVMem `recent_tokens >= N`，保证 draft 需要的尾部窗口留在 GPU。

- 2048 不够：位置 102400/102401 距结尾约 3.8K，仍会 no target slot。
- 4096 足够：128K/256K 均不再报错。

### 实测

| 场景 | Decode tok/s | Draft | 质量 |
|---|---|---|---|
| 128K 全注意力，修复前 | 34.5 | 0 | 3/3 |
| 128K 全注意力，`--spec-draft-window 4096` | **57.8** | 204/152 | 3/3 |
| 250K 全注意力，window 4096 | **57.0** | 144/108 | 3/3（含 MIDDLE-ULTRA-256） |
| 16K 全注意力，默认 window | 50.8 | 51/36 | - |
| 128K，window 2048 | 35.0 | 0 | - |

主模型仍验证全量上下文，生成质量不降；draft 只是用尾部窗口做 catch-up。

### 生产

`start-llama-14803.sh` 已加入 `--spec-draft-window 4096`，保持原版全注意力（池 40960）。14803/14802 均 200，显存约 14.0 GiB。
