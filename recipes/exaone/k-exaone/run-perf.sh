#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

# End-to-end K-EXAONE benchmark runner:
#   1. Select a DGD manifest from ablation variables.
#   2. Apply the DGD.
#   3. Wait for serving readiness.
#   4. Run AIPerf inside the cluster and copy artifacts locally.
#
# Ablation examples:
#   BACKEND=sglang TOPOLOGY=agg VARIANT=tp4 ./run-perf.sh
#   BACKEND=sglang TOPOLOGY=agg VARIANT=tp4x2-kv ./run-perf.sh
#   BACKEND=sglang TOPOLOGY=agg VARIANT=tp4x2-rr ./run-perf.sh
#   BACKEND=sglang TOPOLOGY=agg VARIANT=tp8x2-rr ./run-perf.sh
#   BACKEND=sglang TOPOLOGY=disagg ./run-perf.sh
#   BACKEND=vllm TOPOLOGY=agg VARIANT=tp4 ./run-perf.sh
#   BACKEND=vllm TOPOLOGY=agg VARIANT=tp4x2-kv ./run-perf.sh
#   BACKEND=vllm TOPOLOGY=agg VARIANT=tp4x2-rr ./run-perf.sh
#   BACKEND=vllm TOPOLOGY=agg VARIANT=tp8x2-rr ./run-perf.sh
#   BACKEND=vllm TOPOLOGY=disagg ./run-perf.sh
#   PRECISION=bf16 BACKEND=sglang TOPOLOGY=agg VARIANT=tp4 SERVICE_NAME=<bf16-frontend> ./run-perf.sh
#   MTP_MODE=mtp RUN_LABEL=<mtp-run-label> SERVICE_NAME=<mtp-frontend> ./run-perf.sh
#
# Override knobs:
#   BENCHMARK_MODE=multi-turn  Run the dedicated RR-vs-KV multi-turn matrix.
#   APPLY_DGD=0         Skip kubectl apply/wait; only run AIPerf.
#   TEARDOWN_AFTER=1    Delete runner pod and DGD after benchmark.
#   DEPLOY_FILE=<path>  Use an explicit manifest.
#   DGD_NAME=<name>     Use an explicit DGD name.
#   SERVICE_NAME=<name> Use an explicit frontend service name.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

BENCHMARK_MODE="${BENCHMARK_MODE:-single-turn}"
case "${BENCHMARK_MODE}" in
  single-turn) ;;
  multi-turn)
    exec ./run-multiturn-perf.sh
    ;;
  *)
    echo "Unsupported BENCHMARK_MODE='${BENCHMARK_MODE}'. Use single-turn or multi-turn." >&2
    exit 1
    ;;
esac

NAMESPACE="${NAMESPACE:-dynamo-demo}"
HARDWARE="${HARDWARE:-h200}"
BACKEND="${BACKEND:-sglang}"
TOPOLOGY="${TOPOLOGY:-agg}"
VARIANT="${VARIANT:-}"
PRECISION="${PRECISION:-fp8}"
MTP_MODE="${MTP_MODE:-no-mtp}"
CONCURRENCIES="${CONCURRENCIES:-1 8 16 32 64 128 256}"
APPLY_DGD="${APPLY_DGD:-1}"
TEARDOWN_AFTER="${TEARDOWN_AFTER:-0}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-7200s}"

HARDWARE="$(printf '%s' "${HARDWARE}" | tr '[:upper:]' '[:lower:]')"
BACKEND="$(printf '%s' "${BACKEND}" | tr '[:upper:]' '[:lower:]')"
TOPOLOGY="$(printf '%s' "${TOPOLOGY}" | tr '[:upper:]' '[:lower:]')"
VARIANT="$(printf '%s' "${VARIANT}" | tr '[:upper:]' '[:lower:]')"
PRECISION="$(printf '%s' "${PRECISION}" | tr '[:upper:]' '[:lower:]')"
MTP_MODE="$(printf '%s' "${MTP_MODE}" | tr '[:upper:]' '[:lower:]')"

if [ -z "${VARIANT}" ]; then
  case "${TOPOLOGY}" in
    agg) VARIANT="tp4" ;;
    disagg)
      if [ "${HARDWARE}" = "b200" ]; then
        VARIANT="tp8tp8"
      else
        VARIANT="tp4tp4"
      fi
      ;;
    *) VARIANT="default" ;;
  esac
fi

select_recipe() {
  case "${BACKEND}:${TOPOLOGY}:${VARIANT}" in
    sglang:agg:tp4)
      DEPLOY_FILE="${DEPLOY_FILE:-sglang/agg-h200/deploy.yaml}"
      DGD_NAME="${DGD_NAME:-k-exaone-h200-agg-fp8-tp4}"
      SERVICE_NAME="${SERVICE_NAME:-k-exaone-h200-agg-fp8-tp4-frontend}"
      ;;
    sglang:agg:tp4x2-kv)
      DEPLOY_FILE="${DEPLOY_FILE:-sglang/agg-h200/deploy-tp4x2-kv.yaml}"
      DGD_NAME="${DGD_NAME:-k-exaone-h200-agg-fp8-tp4x2-kv}"
      SERVICE_NAME="${SERVICE_NAME:-k-exaone-h200-agg-fp8-tp4x2-kv-frontend}"
      ;;
    sglang:agg:tp4x2-rr)
      DEPLOY_FILE="${DEPLOY_FILE:-sglang/agg-h200/deploy-tp4x2-rr.yaml}"
      DGD_NAME="${DGD_NAME:-k-exaone-h200-agg-fp8-tp4x2-rr}"
      SERVICE_NAME="${SERVICE_NAME:-k-exaone-h200-agg-fp8-tp4x2-rr-frontend}"
      ;;
    sglang:agg:tp8x2-rr)
      DEPLOY_FILE="${DEPLOY_FILE:-sglang/agg-h200/deploy-tp8x2-rr.yaml}"
      DGD_NAME="${DGD_NAME:-k-exaone-h200-agg-fp8-tp8x2-rr}"
      SERVICE_NAME="${SERVICE_NAME:-k-exaone-h200-agg-fp8-tp8x2-rr-frontend}"
      ;;
    sglang:disagg:*)
      if [ "${HARDWARE}" = "b200" ] && [ "${VARIANT}" = "tp8tp8" ]; then
        DEPLOY_FILE="${DEPLOY_FILE:-sglang/disagg-b200/deploy-tp8tp8.yaml}"
        DGD_NAME="${DGD_NAME:-k-exaone-b200-disagg-fp8-tp8tp8}"
        SERVICE_NAME="${SERVICE_NAME:-k-exaone-b200-disagg-fp8-tp8tp8-frontend}"
      else
        DEPLOY_FILE="${DEPLOY_FILE:-sglang/disagg-h200/deploy.yaml}"
        DGD_NAME="${DGD_NAME:-k-exaone-h200-disagg-fp8-tp4tp4}"
        SERVICE_NAME="${SERVICE_NAME:-k-exaone-h200-disagg-fp8-tp4tp4-frontend}"
      fi
      ;;
    vllm:agg:tp4)
      DEPLOY_FILE="${DEPLOY_FILE:-vllm/agg/h200/deploy.yaml}"
      DGD_NAME="${DGD_NAME:-k-exaone-h200-vllm-agg-fp8-tp4}"
      SERVICE_NAME="${SERVICE_NAME:-k-exaone-h200-vllm-agg-fp8-tp4-frontend}"
      ;;
    vllm:agg:tp4x2-kv)
      DEPLOY_FILE="${DEPLOY_FILE:-vllm/agg/h200/deploy-tp4x2-kv.yaml}"
      DGD_NAME="${DGD_NAME:-k-exaone-h200-vllm-agg-fp8-tp4x2-kv}"
      SERVICE_NAME="${SERVICE_NAME:-k-exaone-h200-vllm-agg-fp8-tp4x2-kv-frontend}"
      ;;
    vllm:agg:tp4x2-rr)
      DEPLOY_FILE="${DEPLOY_FILE:-vllm/agg/h200/deploy-tp4x2-rr.yaml}"
      DGD_NAME="${DGD_NAME:-k-exaone-h200-vllm-agg-fp8-tp4x2-rr}"
      SERVICE_NAME="${SERVICE_NAME:-k-exaone-h200-vllm-agg-fp8-tp4x2-rr-frontend}"
      ;;
    vllm:agg:tp8x2-rr)
      DEPLOY_FILE="${DEPLOY_FILE:-vllm/agg/h200/deploy-tp8x2-rr.yaml}"
      DGD_NAME="${DGD_NAME:-k-exaone-h200-vllm-agg-fp8-tp8x2-rr}"
      SERVICE_NAME="${SERVICE_NAME:-k-exaone-h200-vllm-agg-fp8-tp8x2-rr-frontend}"
      ;;
    vllm:disagg:*)
      if [ "${HARDWARE}" = "b200" ] && [ "${VARIANT}" = "tp8tp8" ]; then
        DEPLOY_FILE="${DEPLOY_FILE:-vllm/disagg/b200/deploy-tp8tp8.yaml}"
        DGD_NAME="${DGD_NAME:-k-exaone-b200-vllm-disagg-fp8-tp8tp8}"
        SERVICE_NAME="${SERVICE_NAME:-k-exaone-b200-vllm-disagg-fp8-tp8tp8-frontend}"
      else
        DEPLOY_FILE="${DEPLOY_FILE:-vllm/disagg/h200/deploy.yaml}"
        DGD_NAME="${DGD_NAME:-k-exaone-h200-vllm-disagg-fp8}"
        SERVICE_NAME="${SERVICE_NAME:-k-exaone-h200-vllm-disagg-fp8-frontend}"
      fi
      ;;
    *)
      echo "Unsupported combination: BACKEND=${BACKEND}, TOPOLOGY=${TOPOLOGY}, VARIANT=${VARIANT}" >&2
      exit 1
      ;;
  esac
}

wait_for_serving_ready() {
  echo "Waiting for DGD ${DGD_NAME} to become Ready (${WAIT_TIMEOUT})..."
  if ! kubectl wait "dynamographdeployment/${DGD_NAME}" \
      -n "${NAMESPACE}" \
      --for=condition=Ready \
      --timeout="${WAIT_TIMEOUT}"; then
    echo "DGD did not report Ready. Current status:"
    kubectl get dynamographdeployment "${DGD_NAME}" -n "${NAMESPACE}" -o yaml | sed -n '/status:/,$p' || true
    kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-graph-deployment-name=${DGD_NAME}" || true
    exit 1
  fi

  echo "Checking frontend service ${SERVICE_NAME}..."
  kubectl get svc "${SERVICE_NAME}" -n "${NAMESPACE}" >/dev/null
  kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-graph-deployment-name=${DGD_NAME}" -o wide
}

select_recipe

if [ -z "${RUN_LABEL:-}" ]; then
  precision_label="$(printf '%s' "${PRECISION}" | tr '[:lower:]' '[:upper:]')"
  RUN_LABEL="${HARDWARE}-K-EXAONE-${precision_label}-ISL-${ISL:-2000}-OSL-${OSL:-14000}-${BACKEND}-${TOPOLOGY}-${VARIANT}-${MTP_MODE}"
fi

echo "============================================================"
echo "K-EXAONE performance run"
echo "============================================================"
echo "Namespace:     ${NAMESPACE}"
echo "Deploy file:   ${DEPLOY_FILE}"
echo "DGD name:      ${DGD_NAME}"
echo "Service:       ${SERVICE_NAME}"
echo "Hardware:      ${HARDWARE}"
echo "Backend:       ${BACKEND}"
echo "Topology:      ${TOPOLOGY}"
echo "Variant:       ${VARIANT}"
echo "Precision:     ${PRECISION}"
echo "MTP mode:      ${MTP_MODE}"
echo "Run label:     ${RUN_LABEL}"
echo "Concurrencies: ${CONCURRENCIES}"
echo "============================================================"

if [ "${APPLY_DGD}" = "1" ]; then
  kubectl apply -f "${DEPLOY_FILE}" -n "${NAMESPACE}"
  wait_for_serving_ready
else
  echo "Skipping DGD apply/wait because APPLY_DGD=0"
fi

AIPERF_GPU_TELEMETRY_URLS="${AIPERF_GPU_TELEMETRY_URLS:-http://nvidia-dcgm-exporter.gpu-operator.svc.cluster.local:9400/metrics}" \
NAMESPACE="${NAMESPACE}" \
HARDWARE="${HARDWARE}" \
BACKEND="${BACKEND}" \
TOPOLOGY="${TOPOLOGY}" \
VARIANT="${VARIANT}" \
PRECISION="${PRECISION}" \
MTP_MODE="${MTP_MODE}" \
SERVICE_NAME="${SERVICE_NAME}" \
RUN_LABEL="${RUN_LABEL}" \
CONCURRENCIES="${CONCURRENCIES}" \
./run-aiperf-in-cluster.sh

if [ "${TEARDOWN_AFTER}" = "1" ]; then
  kubectl delete pod k-exaone-aiperf-runner -n "${NAMESPACE}" --ignore-not-found=true
  kubectl delete dynamographdeployment "${DGD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
fi

