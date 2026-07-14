<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# K-EXAONE Recipe

Recipes for **K-EXAONE-236B-A23B-FP8** on Dynamo across **vLLM** and **SGLang**. The manifests use the Hugging Face checkpoint `LGAI-EXAONE/K-EXAONE-236B-A23B-FP8` by default and read weights from a shared model-cache PVC.

## Variants

| Variant | Backend | Hardware | Manifest | Topology |
|---|---|---|---|---|
| `sglang-agg-h200-tp4` | SGLang | 1 x H200 node, 4 GPUs | [`sglang/agg-h200/deploy.yaml`](sglang/agg-h200/deploy.yaml) | Aggregated TP4 |
| `sglang-agg-h200-tp4x2-kv` | SGLang | 2 x H200 nodes, 4 GPUs each | [`sglang/agg-h200/deploy-tp4x2-kv.yaml`](sglang/agg-h200/deploy-tp4x2-kv.yaml) | Two TP4 workers, approximate KV routing |
| `sglang-agg-h200-tp4x2-rr` | SGLang | 2 x H200 nodes, 4 GPUs each | [`sglang/agg-h200/deploy-tp4x2-rr.yaml`](sglang/agg-h200/deploy-tp4x2-rr.yaml) | Two TP4 workers, round-robin routing |
| `sglang-agg-h200-tp8x2-rr` | SGLang | 2 x H200 nodes, 8 GPUs each | [`sglang/agg-h200/deploy-tp8x2-rr.yaml`](sglang/agg-h200/deploy-tp8x2-rr.yaml) | Two TP8 workers, round-robin routing |
| `sglang-disagg-h200` | SGLang | 2 x H200 nodes, 4 GPUs each | [`sglang/disagg-h200/deploy.yaml`](sglang/disagg-h200/deploy.yaml) | Prefill TP4 + decode TP4 |
| `sglang-disagg-b200-tp8tp8` | SGLang | 2 x B200 nodes, 8 GPUs each | [`sglang/disagg-b200/deploy-tp8tp8.yaml`](sglang/disagg-b200/deploy-tp8tp8.yaml) | Prefill TP8 + decode TP8 |
| `vllm-agg-h200-tp4` | vLLM | 1 x H200 node, 4 GPUs | [`vllm/agg/h200/deploy.yaml`](vllm/agg/h200/deploy.yaml) | Aggregated TP4 |
| `vllm-agg-h200-tp4x2-kv` | vLLM | 2 x H200 nodes, 4 GPUs each | [`vllm/agg/h200/deploy-tp4x2-kv.yaml`](vllm/agg/h200/deploy-tp4x2-kv.yaml) | Two TP4 workers, approximate KV routing |
| `vllm-agg-h200-tp4x2-rr` | vLLM | 2 x H200 nodes, 4 GPUs each | [`vllm/agg/h200/deploy-tp4x2-rr.yaml`](vllm/agg/h200/deploy-tp4x2-rr.yaml) | Two TP4 workers, round-robin routing |
| `vllm-agg-h200-tp8x2-rr` | vLLM | 2 x H200 nodes, 8 GPUs each | [`vllm/agg/h200/deploy-tp8x2-rr.yaml`](vllm/agg/h200/deploy-tp8x2-rr.yaml) | Two TP8 workers, round-robin routing |
| `vllm-disagg-h200` | vLLM | 2 x H200 nodes, 4 GPUs each | [`vllm/disagg/h200/deploy.yaml`](vllm/disagg/h200/deploy.yaml) | Prefill TP4 + decode TP4 |
| `vllm-disagg-b200-tp8tp8` | vLLM | 2 x B200 nodes, 8 GPUs each | [`vllm/disagg/b200/deploy-tp8tp8.yaml`](vllm/disagg/b200/deploy-tp8tp8.yaml) | Prefill TP8 + decode TP8 |

## Prerequisites

1. Dynamo Platform installed.
2. GPU nodes labeled `nvidia.com/gpu.product=NVIDIA-H200` or `nvidia.com/gpu.product=NVIDIA-B200`.
3. An RWX storage class for `shared-model-cache`.
4. Hugging Face access to `LGAI-EXAONE/K-EXAONE-236B-A23B-FP8`.

## Quick Start

Create a namespace and Hugging Face token secret:

```bash
export NAMESPACE=dynamo-demo
kubectl create namespace ${NAMESPACE}

kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="your-token-here" \
  -n ${NAMESPACE}
```

Create the shared model cache and download the FP8 checkpoint:

```bash
kubectl apply -f model-cache/model-cache.yaml -n ${NAMESPACE}
kubectl apply -f model-cache/model-download.yaml -n ${NAMESPACE}
kubectl wait --for=condition=Complete job/model-download -n ${NAMESPACE} --timeout=14400s
```

Deploy a variant:

```bash
kubectl apply -f sglang/agg-h200/deploy.yaml -n ${NAMESPACE}
kubectl wait --for=condition=Ready dynamographdeployment/k-exaone-h200-agg-fp8-tp4 -n ${NAMESPACE} --timeout=7200s
```

Run an end-to-end benchmark. The script selects a manifest, applies it, waits for readiness, runs AIPerf in-cluster, and copies artifacts back to `~/artifacts`.

```bash
BACKEND=sglang TOPOLOGY=agg VARIANT=tp4 TEARDOWN_AFTER=1 ./run-perf.sh
BACKEND=vllm TOPOLOGY=disagg TEARDOWN_AFTER=1 ./run-perf.sh
```

## Test the Deployment

Port-forward the frontend service for the variant you deployed:

```bash
kubectl port-forward svc/k-exaone-h200-agg-fp8-tp4-frontend 8000:8000 -n ${NAMESPACE}
```

Send a non-reasoning request:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "LGAI-EXAONE/K-EXAONE-236B-A23B-FP8",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 128,
    "temperature": 1.0,
    "top_p": 0.95,
    "chat_template_kwargs": {"enable_thinking": false}
  }'
```

## Recipe Details

| Flag | Purpose |
|------|---------|
| `--trust-remote-code` | Required for K-EXAONE model code. |
| `--dyn-tool-call-parser hermes` | Parses K-EXAONE tool calls into OpenAI-compatible `tool_calls`. |
| `--dyn-reasoning-parser qwen3` | SGLang reasoning parser for K-EXAONE. |
| `--dyn-reasoning-parser deepseek_r1` | vLLM Dynamo parser used for K-EXAONE's DeepSeek-style thinking format. |
| `--attention-backend fa3` | Required by SGLang for K-EXAONE on H200. |
| `--attention-backend trtllm_mha --page-size 32` | B200 SGLang attention settings. |
| `--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'` | Enables NIXL KV transfer for disaggregated vLLM deployments. |
| `--disaggregation-transfer-backend nixl` | Enables NIXL KV transfer for disaggregated SGLang deployments. |

## Model Details

Sourced from the [`LGAI-EXAONE/K-EXAONE-236B-A23B-FP8` model card](https://huggingface.co/LGAI-EXAONE/K-EXAONE-236B-A23B-FP8):

| | |
|---|---|
| **Model** | `LGAI-EXAONE/K-EXAONE-236B-A23B-FP8` |
| **Parameters** | 236B total / 23B active |
| **Context length** | 262,144 tokens |
| **Precision** | FP8 compressed-tensors |
| **Tool parser** | Hermes-compatible |
| **Reasoning** | Thinking is enabled by default; set `chat_template_kwargs.enable_thinking=false` for latency-sensitive tests. |

## Notes

- **Storage class.** Update `storageClassName` in `model-cache/model-cache.yaml` to a RWX class that can serve the PVC to Frontend and worker pods.
- **Offline model cache.** Workers run with `HF_HUB_OFFLINE=1` so engines read cached weights from the PVC.
- **First launch is slow.** Weight load and CUDA graph capture can take several minutes on first launch.
- **Benchmark artifacts.** `run-aiperf-in-cluster.sh` runs AIPerf inside the cluster and copies summary files plus compressed raw request exports back to the local workstation.
