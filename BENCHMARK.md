# Prism KVMem Benchmark (V100 16 GB)

最后更新：2026-11-18。所有数字都是本机实测，单位 tok/s；未注明时均为 **decode**，prefill 会单独标注。

## 1. 测试环境

| 项目 | 值 |
|---|---|
| GPU | V100 16 GB, sm_70 |
| CUDA / gcc / CMake | 12.8.93 / 14.2.0 / 3.31.6 |
| 模型 | Qwen3.8-27B GSQ IQ3_XXS-mtp（默认），Ternary Bonsai 2 27B PTQ1_0（legacy） |
| KV Cache | q8_0 / q8_0（除非注明） |
| 投机解码 | MTP n-max 2，draft window 4096（除非注明） |
| 上下文 | 262144 |
| 测量 | 非流式 /v1/chat/completions，cache_prompt=false，取 timings.predicted_per_second；prefill 取 prompt_per_second |

decode 与 prefill 是不同指标，不能混用。

## 2. GSQ IQ3_XXS-mtp（当前默认，全注意力）

生产配置：

~~~bash
--kvmem --kvmem-budget 6144 --kvmem-gen-reserve 34816
--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-window 4096
--cache-type-k q8_0 --cache-type-v q8_0
-c 262144 -fa on -ub 1024 -b 4096
~~~

| 上下文 | Prompt tokens | Prefill | Decode | Draft | 备注 |
|---|---|---|---|---|---|
| 2K | 1962 | 425.8 | **51.4** | 241/134 | MTP |
| 2K，关闭 MTP | 1962 | 425.8 | 36.7 | - | 对照 |
| 16K | 14711 | 599.7 | **50.8** | 51/36 | draft window 4096 |
| 38K + 2K 输出 | 38064 | 544.4 | **55.3** | 1725/1136 | 长输出，三暗号 3/3 |
| 38K + 2K 输出，默认水位 | 38064 | 524.2 | 53.5 | 1784/1106 | 不启用降级水位 |
| 106K | 106254 | 451.4 | **57.8** | 204/152 | 全注意力，三暗号 3/3 |
| 250K | 261503 | 400.3 | **57.0** | 144/108 | 全注意力，三暗号 3/3 |
| 250K，修复前 | 261503 | 588.9 | 34.2 | 0 | MTP draft 未生效 |

长文 prefill（单独标注，不是 decode）：

| 上下文 | Prefill |
|---|---|
| 117K | 约 549 |
| 226K | 约 488 |
| 250K | 400.3 |

结论：draft window 4096 修复后，128K/256K 全注意力 decode 从 34-35 提升到 57 左右；质量由主模型全量验证，三暗号不丢。

## 3. 其他模型 / 配置

### 3.1 Ternary Bonsai 2 27B PTQ1_0（legacy，无投机）

| 项目 | 值 |
|---|---|
| 模型大小 | 约 6.2 GB |
| KVMem | 12288 + 22528（池 34816） |
| 128K decode | 约 34-35 |
| 显存 | 9.3-9.9 GiB |
| 短路 | 可用，阈值约 33075 |

Bonsai 没有 MTP，decode 落在单 token GEMV 的 34-35 区间；短上下文可走原生短路。

### 3.2 DFlash2 draft（实验，未上线）

| 场景 | Decode | 说明 |
|---|---|---|
| 2K + 700 token | 59.3 | draft 接受率约 75% |
| 128K | 失败 | 长上下文 KVMem + DFlash 不稳定，已放弃 |

### 3.3 KV 精度对比（250K prompt，261503 token）

| K / V | Prefill | Decode | 三暗号 | 峰值显存 |
|---|---|---|---|---|
| f16 / f16 | 606.4 | 34.54 | 3/3 | 14581 MiB |
| q8_0 / f16 | 624.5 | 33.75 | 3/3 | 14375 MiB |
| **q8_0 / q8_0** | 591.1 | **33.98** | **3/3** | **14197 MiB** |
| q4_0 / q8_0 | 629.3 | 32.53 | 3/3 | 14133 MiB |

该组是 MTP 未生效时的 256K 全注意力对照，用于比较 KV 精度；不能和修复后的 57.0 混用。结论：量化不提升 decode，q4_0 反而更慢。

## 4. Window / Sink 扫描（约 85K prompt）

固定 sink=512、池 16384、MTP，暗号为开头/中间/结尾三个。

| Window | Prefill | Decode | 命中暗号 |
|---|---|---|---|
| 2048 | 571.3 | 55.01 | **3/3** |
| 4096 | 591.9 | 55.57 | 2/3 |
| 8192 | 591.7 | 55.56 | 2/3 |
| 16384 | 592.2 | 55.58 | 2/3 |
| 32768 | 593.2 | 55.56 | 2/3 |

2048 三次复跑均为 3/3；4096 以上只找回首尾。该结果依赖当前 KVMem 选页行为，换语料需复测。

## 5. 正确性门禁

~~~bash
KEY=$(cat /path/to/api_key.txt)
python3 docs/kvmem-prism/scripts/verify_correctness.py --base http://127.0.0.1:14802 --key "$KEY"
~~~

2026-11-18 实测：

| 测试 | 结果 |
|---|---|
| greedy_repeat | PASS（逐字一致） |
| arithmetic | PASS |
| needle（约 38K，prompt 38057） | PASS 3/3，77.0 s |

## 6. 复现

~~~bash
python3 docs/kvmem-prism/scripts/bench_128k.py --port 14802 --key "$KEY"
python3 docs/kvmem-prism/scripts/bench_256k.py --port 14802 --key "$KEY"
python3 docs/kvmem-prism/scripts/bench_agent_8turn.py /tmp/agent.json --port 14802 --key "$KEY"
python3 docs/kvmem-prism/scripts/verify_correctness.py --base http://127.0.0.1:14802 --key "$KEY"
~~~

注意：

- 切换 prompt 时显式 cache_prompt=false，避免复用上一个长前缀。
- 长时间生成会改变 resident 工作集，decode 会随生成长度变化；表中长输出项已注明。
- 所有数字受 GPU 功耗墙、时钟和后台负载影响，比较时保持同一环境。
