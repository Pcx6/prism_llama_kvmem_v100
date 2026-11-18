# prism_llama_kvmem_v100 - Prism x KVMem 生产融合说明

[![Release](https://img.shields.io/github/v/release/Pcx6/prism_llama_kvmem_v100)](https://github.com/Pcx6/prism_llama_kvmem_v100/releases)

## 源码安装

> 二进制 Release 已撤回：KVMem adapter 未提供再分发许可，仓库只发布源码。需要用户自备 `KVMEM_ROOT` 编译。 许可与再分发限制见 0.3；本脚本只构建源码，不下载预编译二进制。

```bash
git clone https://github.com/Pcx6/prism_llama_kvmem_v100.git
cd prism_llama_kvmem_v100
KVMEM_ROOT=/path/to/kvmem-root ./deploy/quickstart.sh 1
```

脚本会先让选择模型（也可直接传参）：

| 选项 | 模型 | 说明 |
|---|---|---|
| `1`（默认） | Qwen3.8-27B GSQ IQ3_XXS | MTP + 视觉，2K 上下文 decode 约 61 tok/s |
| `2` | Ternary Bonsai 2 27B PTQ1_0 | 旧模型 + 视觉，128K decode 约 34-35 tok/s（无 MTP） |

非交互选择：`./deploy/quickstart.sh 2`，或 `MODEL_CHOICE=2 ./quickstart.sh`。GSQ 档可加 `KV_PROFILE=fast`（约 52 tok/s）或 `KV_PROFILE=256k`（256K 精确档）。

要求：Linux x86_64、NVIDIA **sm_70（V100）**、CUDA 12.8/12.9、gcc 14、CMake 3.31、Python 3、至少 30 GB 磁盘。
脚本会编译源码（需要 `KVMEM_ROOT`）并下载所选模型/视觉塔（GSQ 约 10.7 GB，Bonsai 约 6.2 GB），生成随机 API key，并在 `14803` 启动服务。
自定义：`PORT=14803 API_KEY=my-key MODELS=/data/models KVMEM_ROOT=... ./deploy/quickstart.sh`。
手动构建见第 3 节；构建环境见 `ci/README.md`。
不提供预编译二进制，避免在 adapter 许可未明时再分发 `libkvmem`。




本仓库是 Prism（qwen35 架构 27B 三值量化模型）的 llama.cpp 分支，把 KVMem 主机侧 KV 换页适配器编译进 Prism，并在此基础上完成：
请求级检索 span 注入、短上下文短路、前缀复用、多模态视觉、以及生产部署 14803 的运维脚本。

生产入口：`14803`（llama-server，KVMem + Vision，API 名 `Qwen3.8-27B-GSQ-RCO-IQ3_XXS`）→ `14802`（trim_proxy.mjs，裁剪 tool 结果并转发）。

> 2026-11-15：API 模型名已从 `Bonsai-2-27B` 改为 `Qwen3.8-27B-GSQ-RCO-IQ3_XXS`（对应 GSQ IQ3_XXS-mtp 权重）。旧名不再作为别名返回，请更新客户端。


> 当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

## 0. 仓库说明与获取权重

- 本仓库是 **llama.cpp（MIT）的生产分支**，在此基础上完成 KVMem 适配、短上下文短路、检索、前缀复用、多模态与 TTL，技术细节见后续章节。
- **模型权重不随仓库分发**（`.gitignore` 排除 `*.gguf`），用 `deploy/download-models.sh [1|2]` 从 Hugging Face 拉取：
  - 1（默认）：`ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF` 的 `Qwen3.8-27B-GSQ-RCO-IQ3_XXS-mtp.gguf` + `mmproj-Qwen3.8-27B-BF16.gguf`
  - 2（legacy）：`prism-ml/Ternary-Bonsai-2-27B-gguf` 的 `Ternary-Bonsai-2-27B-PTQ1_0.gguf` + `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf`
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
| `MODEL` | 必需 | GSQ IQ3_XXS-mtp gguf 路径（Bonsai 用 `BONSAI_MODEL`） |
| `MMPROJ` | 必需 | 视觉塔路径（GSQ 用 BF16，Bonsai 用 Q8_0） |
| `ALIAS` | 由脚本设置 | API model 名；GSQ `Qwen3.8-27B-GSQ-RCO-IQ3_XXS`，Bonsai `Bonsai-2-27B`。`start-llama.sh` 读环境，14803/quickstart 按 1/2 自设 |
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
| 模型权重（Qwen3.8-27B GSQ） | 依 Hugging Face 仓库许可 | 默认档；不在本仓库分发，由 `deploy/download-models.sh 1` 下载 |
| 视觉塔（mmproj BF16） | 依上游模型许可 | GSQ 默认档；同上 |
| 模型权重（Ternary Bonsai 2 27B） | 依 Hugging Face 仓库许可 | legacy 档；`deploy/download-models.sh 2` |
| 视觉塔（mmproj Q8_0） | 依上游模型许可 | Bonsai legacy 档 |
| 预编译二进制 | 已撤回 | 因 KVMem adapter 许可未明，Release 不再分发含 `libkvmem` 的 tar.gz；只提供源码和构建脚本 |
| 第三方组件（Yukon tokenizer 等） | 随上游模型 | 见模型仓库的 LICENSE/NOTICE |

若你是 KVMem adapter 的版权方并希望补充具体许可证文本，欢迎提 PR 或在 issue 中说明。

> TODO(maintainer): 二选一 —— (a) 保持当前 source-only，Release 不含 `libkvmem`；(b) 取得 adapter 授权后再分发二进制并改写本节与 Release 说明。当前仓库状态为 (a)。

### 0.4 首次准备

源码方式：

```bash
git clone https://github.com/Pcx6/prism_llama_kvmem_v100.git && cd prism_llama_kvmem_v100
cp .env.example .env          # 填入 MODEL/MMPROJ/API_KEY；KVMEM_ROOT 仅构建时 export（.env 已被 .gitignore）
./deploy/download-models.sh   # 默认下载到 models/
set -a; . ./.env; set +a
```

KVMem adapter 不随仓库提供；`KVMEM_ROOT` 必须由使用者自备并确认其许可。

注意：`.env.example` 已是 GSQ 默认；Bonsai legacy（PTQ1_0 + Q8_0）在注释块。切到 Bonsai 时先注释上方 GSQ 块，再取消 Bonsai 注释。`start-llama-14803.sh` 和 `quickstart.sh` 由 1/2 选择自设 ALIAS，不读取 `.env`。


## 1. 生产现状速览

当前默认模型是 GSQ IQ3_XXS-mtp；Bonsai 仅作 legacy 保留。两档参数和指标分开列，避免混用。

### 1.1 GSQ IQ3_XXS-mtp（当前默认，2026-11-17 起）

| 项目 | 值 |
|---|---|
| 模型 | `/srv/models/Qwen3.8-27B-GSQ-RCO-IQ3_XXS-mtp.gguf`（约 10.4 GB，qwen35 hybrid GDN + MTP head，262144 ctx） |
| 视觉塔 | `/srv/models/mmproj-Qwen3.8-27B-BF16.gguf`（931 MB，GPU offload） |
| API 名称 | `Qwen3.8-27B-GSQ-RCO-IQ3_XXS`（旧别名 `Bonsai-2-27B` 已停用） |
| KVMem | `--kvmem-budget 6144 --kvmem-gen-reserve 34816`（池 40960 token，约 2.5 GiB） |
| 投机解码 | `--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-window 4096` |
| 短路 | 启用 MTP 时禁用原生短路（见 2.3、25 与 docs/HISTORY.md（17.4 已归档）） |
| 显存 | 启动约 13.5 GiB；长输出峰值约 14.8 GiB / 16 GB |
| 长文（**prefill** tok/s） | 117K 约 549；226K 约 488（不是 decode） |
| 128K decode | 57.8 tok/s（draft window 4096，draft 204/152） |
| 短请求 decode | 2K prompt 1962 约 51.4 tok/s（当前 default；61.1 为历史调优档，见 1.4） |
| 8 轮 Agent | 27.5-31.2 s（TTFT 17.9-21.2 s，后段 47-50 tok/s） |
| 视觉 | OCR 正常（14802），TTFT 约 3.9-7.9 s |
| KV 空闲回收 | `--kvmem-idle-ttl 86400`（1 天）；日志 `KVMEM_IDLE_EVICT` |
| 回滚 | `$REPO/deploy/start-llama-prism.sh`（原生 prism，无 KVMem/视觉） |

### 1.2 Ternary Bonsai 2 27B PTQ1_0（legacy）

| 项目 | 值 |
|---|---|
| 模型 | `/srv/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf`（约 6.2 GB） |
| 视觉塔 | `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf` |
| API 名称 | `Bonsai-2-27B` |
| KVMem | `--kvmem-budget 12288 --kvmem-gen-reserve 22528`（池 34816，约 2.1 GiB） |
| 投机解码 | 无 |
| 短路 | 可用；阈值约 33075 token |
| 显存 | 启动/峰值约 9.3-9.9 GiB |
| 128K decode | 约 34-35 tok/s |
| 启动 | `deploy/start-llama-14803.sh 2` 或 `MODEL_CHOICE=2 ...` |

> 5.1/5.2 历史池扫描已归档到 docs/HISTORY.md，不能和 GSQ profile 混用。

### 1.3 符号定义与 profile

- `KV_BUDGET`：GPU 工作集 token 数，程序内置默认 32768。
- `KV_GEN_RESERVE`：生成预留 token 数。
- 池总量 = `KV_BUDGET + KV_GEN_RESERVE`。
- 原生短路阈值 = `0.95 × 池总量`；**MTP 开启时短路不生效**，该阈值只对 Bonsai/无投机档有意义。
- 显存中的 KV 池 = 池总量 × 64 KiB/token（q8_0，全层 K+V）。

| 参数 | default（GSQ） | fast（GSQ） | 256k（GSQ） | Bonsai legacy |
|---|---|---|---|---|
| `KV_BUDGET` | 6144 | 4096 | 8192 | 12288 |
| `KV_GEN_RESERVE` | 34816 | 12288 | 4096 | 22528 |
| 池总量 | 40960 | 16384 | 12288 | 34816 |
| `0.95 × 池` | 38912 | 15564.8 | 11673.6 | 33075 |
| KV 池显存 | 2.5 GiB | 1.0 GiB | 0.75 GiB | 2.1 GiB |

`32768` 是程序内置的 `--kvmem-budget` 默认，不属于上述四档；`40960` 是 default 的池总量，不是 budget。

`2.1-2.2 GiB`（4.6 节）指 Bonsai 池 34816 × 64 KiB，`2.5 GiB`（1.1 节）指 GSQ 池 40960 × 64 KiB；两者是不同 profile。同理，`9-10 GB` 是 Bonsai 显存，`13.5/14.8 GiB` 是 GSQ 显存。8 轮 Agent 的 `34.0 → 23-24 s` 是 Bonsai/无投机历史，`27.5-31.2 s` 是当前 GSQ MTP 值。

### 1.4 速度数字索引（每条都带条件）

冷 = 新 prompt、`cache_prompt=false`；热 = 复用前缀。除注明外均为非流式 `timings.predicted_per_second`。

| 指标 | 数值 | ctx | profile | 冷/热 |
|---|---|---|---|---|
| decode | 51.4 | 2K（prompt 1962） | GSQ default（MTP） | 冷 |
| decode | 61.1 | 2K 短请求（输出 700，含思维链） | **历史调优档**（池 18432，非当前 default） | 冷 |
| decode | 65.2 | 视觉 OCR（ctx TODO(maintainer)） | GSQ default（MTP） | 热/视觉请求 |
| decode | 约 57 | 106K / 261K | GSQ default（draft window 4096） | 冷 |
| decode | 约 52 | 106K | GSQ fast（window 2048） | 冷 |
| decode | 34-35 | 106K | Bonsai legacy / GSQ MTP 未生效 | 冷 |

128K/256K 的 57 带长上下文条件，且主模型验证全量上下文；详细表见 [BENCHMARK.md](BENCHMARK.md)。

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

### 2.3 短上下文短路（与 MTP 互斥）

- 原生短路的判据是 `prompt + n_predict < 0.95 * pool`；命中时请求完全驻留 GPU，不建立 host mirror，prefill 跳过 capture/retrieval，日志 `KVMEM_SHORT_BYPASS tokens=...`。
- **只要启用投机解码（MTP/DFlash），短路被禁用**：投机 decode 需要 target slot 映射，host mirror 不完整会触发 `no target slot`。代码见 25 与 docs/HISTORY.md（17.4 已归档）。
- 因此两档行为不同：
  - GSQ（MTP 默认开）：不走短路，短请求也走 KVMem 分页/检索路径；Agent 27.5-31.2 s，不是 23-24 s。
  - Bonsai（无投机）：仍走短路，阈值为 Bonsai 池的 `0.95 * 34816 = 33075`；报告里的 23-24 s 是 Bonsai/无投机时代的数字。
- 跨阈值（例如 8K 轮次接 40K）时，非投机 profile 会记录 `KVMEM_BYPASS_EXIT` 并整体重算一次，保证 host mirror 完整。
- 结论：不要用 23-24 s 描述当前 GSQ 生产；当前 MTP 全开时短上下文收益来自 MTP，不来自短路。

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

环境（本机实测）：V100 16 GB，CUDA 12.8.93（`/usr/local/cuda-12.8/bin/nvcc`），gcc 14.2.0，CMake 3.31.6，sm_70，24 线程。CUDA 12.9 是最后一个支持 sm_70 离线编译的 12.x；CUDA 13 不再支持 sm_70。构建环境和提交基线见 `ci/README.md`、`ci/check-env.sh`。 仓库 CI（`.github/workflows/ci.yml`）只做 `GGML_CUDA=OFF` 的 CPU 构建，不代表 V100 已验证；V100 构建需本机/自建 runner 按 `ci/Dockerfile` 复现。构建 commit 由 `git rev-parse HEAD` 记录；产物 sha256 由构建者本地记录（仓库不分发二进制）。

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

# 2. 启动推理服务（14803，GSQ + MTP + 视觉 + TTL 1 天）
export MODEL=$PWD/models/Qwen3.8-27B-GSQ-RCO-IQ3_XXS-mtp.gguf
export MMPROJ=$PWD/models/mmproj-Qwen3.8-27B-BF16.gguf
export API_KEY=$(cat $API_KEY_FILE)
nohup setsid $REPO/deploy/start-llama-14803.sh 1 > fused_prod.log 2>&1 &

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

`$REPO/deploy/start-llama-14803.sh [1|2]`（或通用 `deploy/start-llama.sh`）：

环境变量（必需）：`MODEL`、`MMPROJ`、`API_KEY`；可选：`PORT`（14803）、`CTX`（262144）、`KV_BUDGET`（6144）、`KV_GEN_RESERVE`（34816）、`KV_TTL`（86400）、`THREADS`（24）、`LLAMA_BIN`。

```bash
export MODEL=/path/to/Qwen3.8-27B-GSQ-RCO-IQ3_XXS-mtp.gguf
export MMPROJ=/path/to/mmproj-Qwen3.8-27B-BF16.gguf
export API_KEY=$(cat $API_KEY_FILE)
$REPO/deploy/start-llama-14803.sh 1   # 2 = Bonsai
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
nohup setsid $REPO/deploy/start-llama-14803.sh 1 \
  > fused_prod.log 2>&1 &

curl -H "Authorization: Bearer $API_KEY" \
  http://127.0.0.1:14803/health      # 期望 200
curl -H "Authorization: Bearer $API_KEY" \
  http://127.0.0.1:14802/health      # 期望 200
nvidia-smi --query-gpu=memory.used --format=csv,noheader   # GSQ 约 13-14.5 GiB；Bonsai 约 9-10 GiB
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

> 5.1/5.2 是 Bonsai 时代的历史数据（已归档）；当前 GSQ 分档见 5.3。程序内置默认见 `--help`（例如 `--kvmem-budget` 程序默认 32768）。

### 5.1/5.2 历史池扫描（已归档）

Bonsai 时代的 budget 扫描和 14 GB 池实验已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前 GSQ 分档见 5.3。

### 5.3 当前配置（GSQ / Bonsai 分档）

GSQ（当前生产默认，MTP 开启）：

| profile | KVMem 池 | 用途 | 实测 |
|---|---|---|---|
| `default` | 6144 + 34816 | 全注意力，23K+ 长输出 | 128K decode 57.8；256K decode 57.0 |
| `fast` | 4096 + 12288 | window 2048，日常短对话 | 128K decode 约 52 |
| `256k` | 8192 + 4096 | 256K 精确档 | 约 34 tok/s，输出上限约 4K |

Bonsai（legacy，无投机）：`--kvmem-budget 12288 --kvmem-gen-reserve 22528`（池 34816，短路阈值 33075），decode 约 34-35 tok/s。

跨阈值场景（8K -> 40K -> 8K）只在无投机的 Bonsai 档出现 `KVMEM_BYPASS_EXIT` 整体重算；GSQ 因 MTP 禁用短路，不走该路径。

### 5.4 KVMem 参数（程序默认 vs 生产脚本）

| 参数 | 程序默认 | 生产值 | 说明 |
|---|---|---|---|
| `--kvmem` | off | on | 启用适配器 |
| `--kvmem-budget` | 32768 | 6144（GSQ）/ 12288（Bonsai） | GPU 工作集 |
| `--kvmem-gen-reserve` | 1024 | 34816（GSQ）/ 22528（Bonsai） | 生成预留 |
| `--kvmem-block-tokens` | 32 | 32 | 块大小 |
| `--kvmem-sink-tokens` | 0 | 0 | 固定保留前缀 |
| `--kvmem-recent-tokens` | 64 | 4096（MTP window 生效） | 固定保留后缀；即 `--spec-draft-window` 的 draft 尾部窗口，不是第 4 节 recency 的 `--kv-window` |
| `--kvmem-method` | retrieval | retrieval | retrieval/recency |
| `--kvmem-host-mib` | 0 | 0 | host KV 配额，0 不限 |
| `--kvmem-cpu-gb` | 0 | 0 | CPU spill，0 关 |
| `--kvmem-gpu-ratio` | 0 | 0 | 占空闲显存比例，0 由适配器取 0.50 |
| `--kvmem-query-max-tokens` | 512 | 512 | 检索 query 上限 |
| `--kvmem-idle-ttl` | 86400 | 86400 | 空闲清理秒数，0 禁用 |

`harvest_v` 与 `mtp_state` 仍只在 adapter 内部使用，没有 CLI；MTP 与 KVMem 可同时启用，但必须保留 draft window（`--spec-draft-window 4096`，见第 25 节）。

## 6. 历史实验：极限上下文实测（已归档）

本节原始实测与配置已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

## 7. 已知限制

- GPU 只有一个实例：16 GB 放不下 14803 + 14805 同时运行，灰度/对比需要停生产窗口。
- `--cache-reuse` 对 KVMem 自动禁用；多轮收益依赖 prompt 前缀复用。
- 短路阈值以上（Bonsai >33075；GSQ MTP 启用时不走短路）的请求走 KVMem 换页，8 轮 Agent 若单轮上下文超过阈值会退回非短路路径。
- M-RoPE 图像批次仍会打印 `find_slot: non-consecutive token position ...`（2D 位置本身非连续，属上游行为），不影响正确性。
- 256K 速度取决于 resident 工作集；当前 GSQ default 池 40960 实测 decode 57.0（见 [BENCHMARK.md](BENCHMARK.md)）。历史池实验见 [docs/HISTORY.md](docs/HISTORY.md)。
- server 注册了 SIGTERM 处理器；若进程卡在 decode，仍需 `kill -9`。
- KV 空闲 TTL 默认 1 天，只清理 IDLE slot；GPU KV 池是固定分配，清理不回退池显存，只释放行与主机内存。
- RAM prompt cache / 原生 checkpoint 在 KVMem 下被禁用（避免 store 与原生 KV 不一致），跨请求只有 slot 前缀复用。


## 8. 历史实验：故障档案（已归档）

本节原始实测与配置已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

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

> 以下 hash 是 2026-11-07 `git filter-repo` 清理前的标识，当前仓库可能无法 `git show`；仅用于事件对照，定位以“文件 + 函数名”为准。

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

完整的速度/质量矩阵见 [BENCHMARK.md](BENCHMARK.md)（按 GSQ / Bonsai / KV 精度 / Window 分表，区分 prefill 与 decode）。

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
| `deploy/quickstart.sh` | 源码构建/下载模型/启动（需 KVMEM_ROOT） |
| `deploy/start-llama-prism.sh` | 回滚：无 KVMem/视觉，131072 ctx |
| `deploy/trim_proxy.mjs` | 14802 代理（断连中止、tool 裁剪、灰度预留） |
| `deploy/download-models.sh` | 从 Hugging Face 下载模型与视觉塔 |
| `BENCHMARK.md` | 最新模型/上下文/精度/窗口基准 |

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


## 13. 历史实验：验收结论（已归档）

本节原始实测与配置已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

## 14. 历史实验：上传 GitHub 前检查（已归档）

本节原始实测与配置已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

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

## 16. 历史实验：生产模型切换（Bonsai 时代）（已归档）

本节原始实测与配置已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

## 17. 历史实验：MTP 投机解码 + 视觉（首版）（已归档）

本节原始实测与配置已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

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
| `default` | 6144 + 34816 | 约 57 tok/s（修复后；34-35 为修复前对照） | 全注意力、23K+ 长输出 |
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

`deploy/quickstart.sh` 支持 1/2 选择、交互菜单、`./quickstart.sh N` 与 `MODEL_CHOICE`；GSQ 档支持 `KV_PROFILE=fast|256k|default`，默认 `--spec-draft-window 4096`、池 6144/34816、q8_0 KV；可用 `CPUSET` 绑定 CPU。脚本从源码构建（必须设置 `KVMEM_ROOT`），不再下载预编译二进制；模型缺失时从 Hugging Face 下载，`/srv/models` 已有文件时直接复用。

## 19. 历史实验：128K Decode 调优（已归档）

本节原始实测与配置已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

## 20. 历史实验：KVMem 窗口驱逐（已归档）

本节原始实测与配置已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

## 21. 历史实验：Window/Sink 扫描（已归档）

本节原始实测与配置已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

## 22. 历史实验：256K 全注意力与混合精度 KV（已归档）

本节原始实测与配置已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

## 23. 历史实验：FP8 支持尝试（已归档）

本节原始实测与配置已移入 [docs/HISTORY.md](docs/HISTORY.md)；当前口径以第 1、5.3、18、25、26 节和 [BENCHMARK.md](BENCHMARK.md) 为准；历史实验见 [docs/HISTORY.md](docs/HISTORY.md)。

## 24. 根因剖析：计算、HBM 还是主机内存（修复前，2026-11-17）

> 本节是 draft window 修复前的分析，用来说明 34-35 tok/s 的成因；当前 MTP 已修复，指标以第 25 节和 [BENCHMARK.md](BENCHMARK.md) 为准。

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
| 250K 全注意力，`--spec-draft-window 4096` | **57.0** | 144/108 | 3/3（含 MIDDLE-ULTRA-256） |
| 16K 全注意力，默认 window | 50.8 | 51/36 | - |
| 128K，window 2048 | 35.0 | 0 | - |

主模型仍验证全量上下文，生成质量不降；draft 只是用尾部窗口做 catch-up。

### 生产

`start-llama-14803.sh` 已加入 `--spec-draft-window 4096`，保持原版全注意力（池 40960）。14803/14802 均 200，显存约 14.0 GiB。

## 26. 正确性基线（2026-11-18）

KVMem 稀疏选页、IQ3 量化、MTP 三层都可能改变输出，因此固定跑一组小门禁：

```bash
KEY=$(cat /path/to/api_key.txt)
python3 docs/kvmem-prism/scripts/verify_correctness.py --base http://127.0.0.1:14802 --key "$KEY"
```

| 测试 | 内容 | 结果 |
|---|---|---|
| greedy_repeat | 同一 prompt、temperature=0、cache_prompt=false 连跑两次，比较完整输出 | PASS（逐字相同） |
| arithmetic | 17 红球 / 9 蓝球，问红球数量 | PASS |
| needle | 约 38K prompt，首/中/尾三个暗号 | PASS 3/3（prompt 38057，77.0 s） |

注意：greedy 逐字一致只在同一服务、同一硬件、相同 batch 形状下作为回归信号；GPU 调度变化可能造成非确定性，失败时应先复跑再判断。

