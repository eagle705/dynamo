<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# K-EXAONE-236B-A23B-FP8 SGLang Disaggregated Prefill/Decode on H200

Serves [LGAI-EXAONE/K-EXAONE-236B-A23B-FP8](https://huggingface.co/LGAI-EXAONE/K-EXAONE-236B-A23B-FP8) with SGLang and Dynamo disaggregated prefill/decode on H200 nodes with InfiniBand RDMA.

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

This Dynamo recipe keeps that H200 TP4 shape for each disaggregated role and adds NIXL for KV transfer between prefill and decode.

## Topology

| Role | Nodes | GPUs per node | Total GPUs | Parallelism |
|------|-------|---------------|------------|-------------|
| Decode | 1 | 4 x H200 | 4 | TP4 |
| Prefill | 1 | 4 x H200 | 4 | TP4 |

Total capacity required: 2 H200 nodes and 8 H200 GPUs.

## Prerequisites

- 2 H200 nodes labeled `nvidia.com/gpu.product=NVIDIA-H200`.
- InfiniBand RDMA exposed through the `rdma/ib` device plugin.
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
k-exaone-h200-disagg-fp8-0-frontend-...
k-exaone-h200-disagg-fp8-0-decode-...
k-exaone-h200-disagg-fp8-0-prefill-...
```

The prefill and decode workers print a prestart GPU guard. If a pod is assigned fewer than four GPUs, it exits before model initialization with `PRESTART_GPU_GUARD_FAIL`.

## Smoke Test

```bash
kubectl port-forward \
  svc/k-exaone-h200-disagg-fp8-frontend \
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

## InfiniBand RDMA Configuration

The recipe uses the same NIXL transport pattern as the B200 SGLang recipe, scaled down to four H200 GPUs per role.

| Setting | Value | Purpose |
|---------|-------|---------|
| `rdma/ib` | `4` | Allocates one RDMA device per GPU. |
| `UCX_TLS` | `rc_x,rc,cuda_copy,cuda_ipc` | Uses accelerated RC and CUDA memory transports. |
| `UCX_NET_DEVICES` | `mlx5_0:1` | Selects one IB device and avoids bonded-device surprises. |
| `UCX_IB_ADDR_TYPE` | `eth` | Uses GID-style addressing for pod-to-pod communication. |
| `UCX_RNDV_SCHEME` | `get_zcopy` | Uses zero-copy RDMA GET for large KV transfers. |
| `IPC_LOCK` + `SYS_RESOURCE` | container capabilities | Allows memory pinning for RDMA. |

If your H200 cluster uses a different IB device name, update `UCX_NET_DEVICES` after checking `ibv_devinfo` inside a debug pod.

## Key Configuration Notes

- **Hopper attention backend.** K-EXAONE requires an explicit SGLang attention backend; this recipe uses `--attention-backend fa3` on H200. The B200 recipe uses `--attention-backend trtllm_mha --page-size 32`.
- **K-EXAONE FP8 weights.** The recipe uses the standard compressed-tensors FP8 path for K-EXAONE.
- **TP4 per worker.** The model card lists 4 x H200 for SGLang, so each prefill/decode worker requests four H200 GPUs and launches with `--tp 4`.
- **`mem-fraction-static=0.80`.** Start conservatively on H200; raise only after a successful smoke test and memory check.
- **EAGLE disabled.** The model card lists speculative decoding as optional. Keep it off for initial disaggregated bring-up.

## Related

- [B200 SGLang Disaggregated Recipe](../disagg-b200/)
- [K-EXAONE FP8 Model Card](https://huggingface.co/LGAI-EXAONE/K-EXAONE-236B-A23B-FP8)
- [Dynamo Disaggregated Communication Guide](https://github.com/ai-dynamo/dynamo/blob/main/docs/kubernetes/disagg-communication-guide.md)
