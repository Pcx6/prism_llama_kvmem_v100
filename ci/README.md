# CI / 构建环境基线

sm_70 构建不是任意 CUDA 版本都能复现，需要固定：

- CUDA 12.9 是最后一个支持 sm_70 离线编译的 12.x；CUDA 13 已移除 sm_70 离线目标。
- 官方容器常只带 PTX 或较新 gcc；显式设置 `-DCMAKE_CUDA_ARCHITECTURES=70`。
- nvcc 与 gcc 主版本组合需要固定。
- 本分支的 Volta FATTN 改动随仓库提交；自定义 patch 必须记录 commit。

## 本机实测基线

| 项目 | 值 |
|---|---|
| GPU | V100 16 GB, sm_70 |
| CUDA | 12.8.93 (`/usr/local/cuda-12.8/bin/nvcc`) |
| gcc | 14.2.0 |
| CMake | 3.31.6 |
| 系统 | Linux x86_64 |
| 仓库提交 | `git rev-parse HEAD`（构建日志必须记录） |

运行 `ci/check-env.sh` 打印当前环境；CI 日志应包含该输出和 commit hash。

## 构建

~~~bash
cmake -S . -B build-sm70 \
  -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=70 \
  -DLLAMA_KVMEM=ON -DLLAMA_KVMEM_ROOT="$KVMEM_ROOT" \
  -DLLAMA_BUILD_SERVER=ON -DGGML_NATIVE=ON
cmake --build build-sm70 -j "$(nproc)" --target llama-server
~~~

`KVMEM_ROOT` 不随仓库提供；CI 应只读挂载或作为构建参数，不要提交进仓库。

## Docker

~~~bash
docker build -f ci/Dockerfile -t prism-kvmem:sm70 .
docker run --gpus all -v "$PWD:/src" -v "$KVMEM_ROOT:/kvmem:ro" -w /src \
  prism-kvmem:sm70 bash -lc 'KVMEM_ROOT=/kvmem ./ci/check-env.sh && \
  cmake -S . -B build-sm70 -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=70 \
    -DLLAMA_KVMEM=ON -DLLAMA_KVMEM_ROOT=/kvmem -DLLAMA_BUILD_SERVER=ON -DGGML_NATIVE=ON && \
  cmake --build build-sm70 -j "$(nproc)" --target llama-server'
~~~