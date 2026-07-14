<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# K-EXAONE-236B-A23B-FP8 SGLang Aggregated Serving on H200

Serves [LGAI-EXAONE/K-EXAONE-236B-A23B-FP8](https://huggingface.co/LGAI-EXAONE/K-EXAONE-236B-A23B-FP8) with SGLang and Dynamo aggregated serving on a single H200 node.

## Model Notes

| Property | Value |
|----------|-------|
| Architecture | 236B total / 23B active MoE |
| Precision | FP8 weights |
| Context | 256K tokens |
| SGLang reasoning parser | `qwen3` |
| Tool call parser | `hermes` |
| Default thinking | `enable_thinking=True`; set `chat_template_kwargs.enable_thinking=false` for lower latency |

Official SGLang launch shape from the model card:

```bash
python -m sglang.launch_server \
  --model LGAI-EXAONE/K-EXAONE-236B-A23B-FP8 \
  --tp-size 4 \
  --reasoning-parser qwen3
```

This recipe keeps that H200 TP4 shape and runs one Dynamo worker behind the Dynamo frontend.

## Topology

| Role | Nodes | GPUs per node | Total GPUs | Parallelism |
|------|-------|---------------|------------|-------------|
| Decode | 1 | 4 x H200 | 4 | TP4 |

This is the lowest-resource H200 path for basic serving. Use `../disagg-h200/` when you want separate prefill and decode workers.

## Prerequisites

- 1 H200 node labeled `nvidia.com/gpu.product=NVIDIA-H200`.
- Dynamo operator and `dynamo-platform` installed.
- Shared RWX PVC named `shared-model-cache` with the FP8 checkpoint downloaded by `../../model-cache/model-download.yaml`.
- Hugging Face token secret in the target namespace:

```bash
kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN=<your-token> \
  -n <namespace>
```

## Deploy

```bash
export NAMESPACE=<your-namespace>
kubectl apply -f deploy.yaml -n "${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}" -w
```

Expected pods:

```text
k-exaone-h200-agg-fp8-0-frontend-...
k-exaone-h200-agg-fp8-0-decode-...
```

The worker prints a prestart GPU guard. If it sees fewer than four GPUs, it exits before model initialization with `PRESTART_GPU_GUARD_FAIL`.

## Smoke Test

```bash
kubectl port-forward \
  svc/k-exaone-h200-agg-fp8-frontend \
  8000:8000 \
  -n "${NAMESPACE}"
```

In another shell:

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

For reasoning-mode validation, omit `chat_template_kwargs` or set `enable_thinking` to `true`.

## Key Configuration Notes

- **TP4 on H200.** The model card lists 4 x H200 for SGLang, so the worker requests four GPUs and launches with `--tp 4`.
- **Hopper attention backend.** K-EXAONE requires an explicit SGLang attention backend; this recipe uses `--attention-backend fa3` on H200. The B200 recipe uses `--attention-backend trtllm_mha --page-size 32`.
- **No NIXL.** Aggregated serving does not split prefill and decode, so this recipe does not request `rdma/ib` or set UCX/NIXL transport variables.
- **K-EXAONE FP8 weights.** The recipe uses the standard compressed-tensors FP8 path for K-EXAONE.
- **`mem-fraction-static=0.80`.** Start conservatively on H200; raise only after a successful smoke test and memory check.
- **EAGLE disabled.** The model card lists speculative decoding as optional. Keep it off for initial bring-up.

## Related

- [H200 SGLang Disaggregated Recipe](../disagg-h200/)
- [B200 SGLang Disaggregated Recipe](../disagg-b200/)
- [K-EXAONE FP8 Model Card](https://huggingface.co/LGAI-EXAONE/K-EXAONE-236B-A23B-FP8)
