# 历史实验归档

本文件保存已归档的历史实验记录（2026-11-06 至 2026-11-17）。这些数字和配置属于当时 profile，不得作为当前生产值；当前口径见 README 第 1、5.3、18、25、26 节与 BENCHMARK.md。

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
- `--kvmem --kvmem-budget 6144 --kvmem-gen-reserve 34816`（池 40960；0.95 高水位 38912，但 MTP 启用时不走短路）
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
| recency + `--kv-window 4096` | 46.4 | 599 | 稳定 |
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

### 5.1 budget 扫描（128K 请求，16 GB 卡；Bonsai 时代历史数据）

| budget | 启动显存 | 128K 峰值 | 128K prefill / decode | 短路实测 |
|---|---|---|---|---|
| 12288 | 7647 MiB | ~7.9 GB | 741.8 / 53.9 | 819.8 t/s @14.3K |
| 16384 | 7487 | 7901 | 681.5 / 51.3 | 819.8 @14.3K |
| 24576 | 8015 | 8527 | 598.9 / 48.0 | 754.8 @22.5K |
| 32768 | 8543 | 8959 | 541.5 / 45.2 | 30.7K 走短路 |
| 40960 | 9071 | 9503 | 497.7 / 27.3 | 648.9 @38.9K |
| 49152 | 9599 | 10033 | 463.0 / 25.8 | 604.9 @47.1K |

结论：显存在 16 GB 内不是瓶颈，**池越大长文 prefill 越慢**（换页收缩后的注意力窗口 = 池大小）。

表中的「短路实测」是当时 budget 与其 gen_reserve 组合下的 `0.95 × 池总量`，随档变化；`30.7K`/`38.9K` 不是固定全局阈值。

### 5.2 14 GB 池实验（Bonsai 时代历史数据，按每 GB 收益 5% 规则否决）

| 池大小 | 启动 | 峰值 | 128K prefill/decode | 256K prefill/decode |
|---|---|---|---|---|
| 34816 | 8543 | 8929 | 573.2 / 52.5 | 542.8 / 47.5 |
| 106496 | 13163 | 13605 | 390.8 / 52.6 | - |
| 131072（适配器上限） | 14623 | 15019 | 387.6 / 23.6 | - |
| 114688（上限 - 1 GB） | 13691 | 14379 | ~390 | 315.9 / 48.6 |

9.3 GB -> 14.4 GB 显存增加 5.1 GB，长文 prefill 反而下降 32-42%，负相关，按规则放弃。

### 17.4 长输出中断修复（2026-11-15）

- 现象：网页端输出到约 10K/3K token 停止，报 `Stream resume produced no new bytes`；服务端日志为 `Context size has been exceeded` / `failed to find a memory slot`，总 token 约 16-17K。
- 原因：KVMem 池 18432（阈值 17510）；WebUI 默认 `max_tokens=-1`，旧短路判据只看 prompt，prompt < 17.5K 即走原生短路（无 host mirror）；prompt+生成超过池上限后无法继续分配 slot，流结束且 UI 续传拿到空。
- 修复（2026-11-15 二次）：根因是 **MTP 投机解码 + 原生短路径** 的 batch 索引异常（`speculative batch index 1 is not inside the current sub-batch [0, 1)`），随后 KVMem 报 `block 448 has no GPU slot`、`Context size has been exceeded`。现在只要启用投机解码，就禁用原生短路，强制走 KVMem 分页路径；同时 `n_predict <= 0` 时按 `gen_reserve` 预留生成空间。
- 验证：强制生成 12000 token（`ignore_eos`）成功，55.1 t/s，无 speculative/context 错误；8 轮 Agent 38.6 s（TTFT 29.0 s，decode 46.8 t/s）；短请求不再走短路（`KVMEM_SHORT_BYPASS` = 0）。
- 追加（2026-11-15）：`gen_reserve` 从 12288 提高到 **18432**（池 24576），解决生成阶段 slot 容量不足；经 14802 实测 12000 token 输出成功（54.8 t/s），16K 测试也通过（54.1 t/s），无 `no GPU slot` / `Context size exceeded`。
- 再次追加：18000 token 级 prompt + 12000 token 输出仍会撞到 22.5K 级 slot 上限；`gen_reserve` 进一步提升到 **26624**（池 32768）。经 14802 实测 16202 prompt + 12000 输出 = 28202 token 成功（33.4 t/s），无 slot/context 错误；256K prompt 仍可正常预填（487.8 t/s）。
- 2026-11-15 最终：22000 token 级输出仍会撞 22K slot 上限；`gen_reserve` 提升到 **34816**（池 40960，约 2.5 GiB）。实测 25000 token 输出成功（55.3 t/s），视觉 GPU 正常（OCR 6.8 s），峰值 14785 MiB。
