#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

# Multi-turn K-EXAONE benchmark runner for comparing aggregated RR vs KV routing.
#
# Default matrix compares vLLM TP4x2 round-robin and event-driven KV routing
# using the realistic session-reuse scenario.
#
# AIPerf multi-turn controls follow:
# https://github.com/ai-dynamo/aiperf/blob/main/docs/tutorials/multi-turn.md#fixed-length-conversations
#
# Common overrides:
#   TRIAL_COUNT=3 ./run-multiturn-perf.sh
#   SCENARIOS="session-reuse" ./run-multiturn-perf.sh
#   CONCURRENCIES="4 8 16 32" CONVERSATION_TURN_MEAN=5 ./run-multiturn-perf.sh
#   APPLY_DGD=0 BACKEND=vllm VARIANT=tp4x2-kv SERVICE_NAME=<frontend> ./run-multiturn-perf.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

NAMESPACE="${NAMESPACE:-dynamo-demo}"
HARDWARE="${HARDWARE:-h200}"
TOPOLOGY="agg"
PRECISION="${PRECISION:-fp8}"
MTP_MODE="${MTP_MODE:-no-mtp}"

# Multi-turn defaults are prefill-heavy to make RR-vs-KV routing differences
# visible in TTFT and request latency. The small output keeps decode work from
# masking prefix-cache reuse.
ISL="${ISL:-8000}"
OSL="${OSL:-512}"
CONCURRENCIES="${CONCURRENCIES:-4 8 16 32 64}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-64}"
CONVERSATION_MULTIPLIER="${CONVERSATION_MULTIPLIER:-2}"
CONVERSATION_TURN_MEAN="${CONVERSATION_TURN_MEAN:-6}"
CONVERSATION_TURN_STDDEV="${CONVERSATION_TURN_STDDEV:-0}"
CONVERSATION_TURN_DELAY_MEAN="${CONVERSATION_TURN_DELAY_MEAN:-0}"
CONVERSATION_TURN_DELAY_STDDEV="${CONVERSATION_TURN_DELAY_STDDEV:-0}"
WARMUP_REQUEST_COUNT="${WARMUP_REQUEST_COUNT:-16}"
SCENARIOS="${SCENARIOS:-session-reuse}"
SESSION_REUSE_DATASET_ENTRIES="${SESSION_REUSE_DATASET_ENTRIES:-64}"
SHARED_PREFIX_DATASET_ENTRIES="${SHARED_PREFIX_DATASET_ENTRIES:-1}"
NUM_DATASET_ENTRIES_OVERRIDE="${NUM_DATASET_ENTRIES:-}"
BASE_RANDOM_SEED="${RANDOM_SEED:-42}"
TRIAL_COUNT="${TRIAL_COUNT:-1}"

APPLY_DGD="${APPLY_DGD:-1}"
TEARDOWN_AFTER_CASE="${TEARDOWN_AFTER_CASE:-1}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-7200s}"
DEPLOY_FILE_OVERRIDE="${DEPLOY_FILE:-}"
DGD_NAME_OVERRIDE="${DGD_NAME:-}"
SERVICE_NAME_OVERRIDE="${SERVICE_NAME:-}"
if [ -z "${CASES+x}" ]; then
  if [ -n "${BACKEND:-}" ] || [ -n "${VARIANT:-}" ]; then
    CASES="${BACKEND:-vllm}:${VARIANT:-tp4x2-kv}"
  else
    CASES="vllm:tp4x2-rr vllm:tp4x2-kv"
  fi
fi

HARDWARE="$(printf '%s' "${HARDWARE}" | tr '[:upper:]' '[:lower:]')"
PRECISION="$(printf '%s' "${PRECISION}" | tr '[:upper:]' '[:lower:]')"
MTP_MODE="$(printf '%s' "${MTP_MODE}" | tr '[:upper:]' '[:lower:]')"

filter_concurrencies() {
  local filtered=""
  local c

  for c in ${CONCURRENCIES}; do
    if [ "${c}" -le "${MAX_CONCURRENCY}" ]; then
      filtered="${filtered} ${c}"
    else
      echo "Skipping concurrency ${c}; MAX_CONCURRENCY=${MAX_CONCURRENCY}"
    fi
  done

  CONCURRENCIES="${filtered# }"
  if [ -z "${CONCURRENCIES}" ]; then
    echo "No concurrencies remain after applying MAX_CONCURRENCY=${MAX_CONCURRENCY}." >&2
    exit 1
  fi
}

filter_concurrencies

select_case() {
  local backend="$1"
  local variant="$2"

  DEPLOY_FILE=""
  DGD_NAME=""
  SERVICE_NAME=""

  case "${backend}:${variant}" in
    vllm:tp4x2-rr)
      DEPLOY_FILE="vllm/agg/h200/deploy-tp4x2-rr.yaml"
      DGD_NAME="k-exaone-h200-vllm-agg-fp8-tp4x2-rr"
      SERVICE_NAME="k-exaone-h200-vllm-agg-fp8-tp4x2-rr-frontend"
      ;;
    vllm:tp4x2-kv)
      DEPLOY_FILE="vllm/agg/h200/deploy-tp4x2-kv.yaml"
      DGD_NAME="k-exaone-h200-vllm-agg-fp8-tp4x2-kv"
      SERVICE_NAME="k-exaone-h200-vllm-agg-fp8-tp4x2-kv-frontend"
      ;;
    sglang:tp4x2-rr)
      DEPLOY_FILE="sglang/agg-h200/deploy-tp4x2-rr.yaml"
      DGD_NAME="k-exaone-h200-agg-fp8-tp4x2-rr"
      SERVICE_NAME="k-exaone-h200-agg-fp8-tp4x2-rr-frontend"
      ;;
    sglang:tp4x2-kv)
      DEPLOY_FILE="sglang/agg-h200/deploy-tp4x2-kv.yaml"
      DGD_NAME="k-exaone-h200-agg-fp8-tp4x2-kv"
      SERVICE_NAME="k-exaone-h200-agg-fp8-tp4x2-kv-frontend"
      ;;
    *)
      echo "Unsupported multi-turn case '${backend}:${variant}'. Supported variants are tp4x2-rr and tp4x2-kv for vllm/sglang." >&2
      exit 1
      ;;
  esac

  DEPLOY_FILE="${DEPLOY_FILE_OVERRIDE:-${DEPLOY_FILE}}"
  DGD_NAME="${DGD_NAME_OVERRIDE:-${DGD_NAME}}"
  SERVICE_NAME="${SERVICE_NAME_OVERRIDE:-${SERVICE_NAME}}"
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

  kubectl get svc "${SERVICE_NAME}" -n "${NAMESPACE}" >/dev/null
  kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-graph-deployment-name=${DGD_NAME}" -o wide
}

dataset_entries_for_scenario() {
  local scenario="$1"

  if [ -n "${NUM_DATASET_ENTRIES_OVERRIDE}" ]; then
    printf '%s\n' "${NUM_DATASET_ENTRIES_OVERRIDE}"
    return 0
  fi

  case "${scenario}" in
    session-reuse)
      printf '%s\n' "${SESSION_REUSE_DATASET_ENTRIES}"
      ;;
    shared-prefix-stress)
      printf '%s\n' "${SHARED_PREFIX_DATASET_ENTRIES}"
      ;;
    *)
      echo "Unsupported scenario '${scenario}'. Use session-reuse or shared-prefix-stress." >&2
      return 1
      ;;
  esac
}

reverse_cases() {
  local reversed=""
  local case_spec

  for case_spec in ${CASES}; do
    reversed="${case_spec} ${reversed}"
  done
  printf '%s\n' "${reversed% }"
}

run_case() {
  local backend="$1"
  local variant="$2"
  local trial="$3"
  local trial_seed="$4"
  local scenario="$5"
  local precision_label
  local dataset_entries
  local run_label

  select_case "${backend}" "${variant}"
  precision_label="$(printf '%s' "${PRECISION}" | tr '[:lower:]' '[:upper:]')"
  dataset_entries="$(dataset_entries_for_scenario "${scenario}")"
  run_label="${RUN_LABEL_PREFIX:-${HARDWARE}-K-EXAONE-${precision_label}}-MT${CONVERSATION_TURN_MEAN}-ISL-${ISL}-OSL-${OSL}-${backend}-${TOPOLOGY}-${variant}-${scenario}-trial${trial}-${MTP_MODE}"

  echo "============================================================"
  echo "K-EXAONE multi-turn performance run"
  echo "============================================================"
  echo "Namespace:       ${NAMESPACE}"
  echo "Deploy file:     ${DEPLOY_FILE}"
  echo "DGD name:        ${DGD_NAME}"
  echo "Service:         ${SERVICE_NAME}"
  echo "Backend:         ${backend}"
  echo "Variant:         ${variant}"
  echo "Concurrencies:   ${CONCURRENCIES}"
  echo "Turns mean/sd:   ${CONVERSATION_TURN_MEAN}/${CONVERSATION_TURN_STDDEV}"
  echo "Turn delay ms:   ${CONVERSATION_TURN_DELAY_MEAN}/${CONVERSATION_TURN_DELAY_STDDEV}"
  echo "Scenario:        ${scenario}"
  echo "Dataset entries: ${dataset_entries}"
  echo "Trial:           ${trial}/${TRIAL_COUNT}"
  echo "Random seed:     ${trial_seed}"
  echo "Run label:       ${run_label}"
  echo "============================================================"

  if [ "${APPLY_DGD}" = "1" ]; then
    kubectl apply -f "${DEPLOY_FILE}" -n "${NAMESPACE}"
    wait_for_serving_ready
  else
    echo "Skipping DGD apply/wait because APPLY_DGD=0"
  fi

  AIPERF_SERVER_METRICS_URLS="${AIPERF_SERVER_METRICS_URLS:-http://${SERVICE_NAME}:8000/metrics}" \
  AIPERF_GPU_TELEMETRY_URLS="${AIPERF_GPU_TELEMETRY_URLS:-http://nvidia-dcgm-exporter.gpu-operator.svc.cluster.local:9400/metrics}" \
  NAMESPACE="${NAMESPACE}" \
  HARDWARE="${HARDWARE}" \
  BACKEND="${backend}" \
  TOPOLOGY="${TOPOLOGY}" \
  VARIANT="${variant}" \
  PRECISION="${PRECISION}" \
  MTP_MODE="${MTP_MODE}" \
  SERVICE_NAME="${SERVICE_NAME}" \
  RUN_LABEL="${run_label}" \
  CONCURRENCIES="${CONCURRENCIES}" \
  ISL="${ISL}" \
  OSL="${OSL}" \
  PROFILE_MODE="multi-turn" \
  CONVERSATION_MULTIPLIER="${CONVERSATION_MULTIPLIER}" \
  CONVERSATION_TURN_MEAN="${CONVERSATION_TURN_MEAN}" \
  CONVERSATION_TURN_STDDEV="${CONVERSATION_TURN_STDDEV}" \
  CONVERSATION_TURN_DELAY_MEAN="${CONVERSATION_TURN_DELAY_MEAN}" \
  CONVERSATION_TURN_DELAY_STDDEV="${CONVERSATION_TURN_DELAY_STDDEV}" \
  NUM_DATASET_ENTRIES="${dataset_entries}" \
  RANDOM_SEED="${trial_seed}" \
  WARMUP_REQUEST_COUNT="${WARMUP_REQUEST_COUNT}" \
  ./run-aiperf-in-cluster.sh

  if [ "${TEARDOWN_AFTER_CASE}" = "1" ]; then
    kubectl delete pod k-exaone-aiperf-runner -n "${NAMESPACE}" --ignore-not-found=true
    kubectl delete dynamographdeployment "${DGD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
  fi
}

for scenario in ${SCENARIOS}; do
  dataset_entries_for_scenario "${scenario}" >/dev/null
  for trial in $(seq 1 "${TRIAL_COUNT}"); do
    trial_seed=$((BASE_RANDOM_SEED + trial - 1))
    trial_cases="${CASES}"
    if [ $((trial % 2)) -eq 0 ]; then
      trial_cases="$(reverse_cases)"
    fi

    for case_spec in ${trial_cases}; do
      backend="${case_spec%%:*}"
      variant="${case_spec#*:}"
      backend="$(printf '%s' "${backend}" | tr '[:upper:]' '[:lower:]')"
      variant="$(printf '%s' "${variant}" | tr '[:upper:]' '[:lower:]')"
      run_case "${backend}" "${variant}" "${trial}" "${trial_seed}" "${scenario}"
    done
  done
done
