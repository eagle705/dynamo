#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Run AIPerf inside the Kubernetes cluster, then copy artifacts back locally.
#
# Why this exists:
# - High-concurrency streaming benchmarks over `kubectl port-forward` can reset
#   long-lived connections.
# - AIPerf artifacts must be copied back to the workstation after the run.
#
# Usage:
#   export NAMESPACE=dynamo-demo
#   ./run-aiperf-in-cluster.sh
#
# Common overrides:
#   CONCURRENCIES="8 16 32 48 64" ./run-aiperf-in-cluster.sh
#   PRECISION=bf16 ./run-aiperf-in-cluster.sh
#   MTP_MODE=mtp RUN_LABEL=my-mtp-run SERVICE_NAME=my-mtp-frontend ./run-aiperf-in-cluster.sh
#   BACKEND=sglang TOPOLOGY=agg VARIANT=tp4x2-kv SERVICE_NAME=my-frontend ./run-aiperf-in-cluster.sh
#   HARDWARE=b200 BACKEND=sglang TOPOLOGY=disagg SERVICE_NAME=k-exaone-236b-a23b-disagg-fp8-frontend ./run-aiperf-in-cluster.sh
#   HARDWARE=h200 BACKEND=sglang TOPOLOGY=agg ./run-aiperf-in-cluster.sh
#   RUN_LABEL=my-custom-run SERVICE_NAME=my-frontend ./run-aiperf-in-cluster.sh
#   LOCAL_ARTIFACT_ROOT="$HOME/artifacts" ./run-aiperf-in-cluster.sh
#   TRANSFORMERS_SPEC="transformers>=5.1.0" ./run-aiperf-in-cluster.sh
#   STREAM_LOGS=1 ./run-aiperf-in-cluster.sh
#   COPY_RAW_PROFILE_EXPORT=0 ./run-aiperf-in-cluster.sh

set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-dynamo-demo}"
IMAGE="${IMAGE:-python:3.12-slim}"

ISL="${ISL:-2000}"
OSL="${OSL:-14000}"
HARDWARE="${HARDWARE:-h200}"
BACKEND="${BACKEND:-sglang}"
TOPOLOGY="${TOPOLOGY:-disagg}"
VARIANT="${VARIANT:-}"
PRECISION="${PRECISION:-fp8}"
MTP_MODE="${MTP_MODE:-no-mtp}"
HARDWARE="$(printf '%s' "${HARDWARE}" | tr '[:upper:]' '[:lower:]')"
BACKEND="$(printf '%s' "${BACKEND}" | tr '[:upper:]' '[:lower:]')"
TOPOLOGY="$(printf '%s' "${TOPOLOGY}" | tr '[:upper:]' '[:lower:]')"
VARIANT="$(printf '%s' "${VARIANT}" | tr '[:upper:]' '[:lower:]')"
PRECISION="$(printf '%s' "${PRECISION}" | tr '[:upper:]' '[:lower:]')"
MTP_MODE="$(printf '%s' "${MTP_MODE}" | tr '[:upper:]' '[:lower:]')"

case "${MTP_MODE}" in
  no-mtp|mtp) ;;
  *)
    echo "Unsupported MTP_MODE='${MTP_MODE}'. Use no-mtp or mtp." >&2
    exit 1
    ;;
esac

if [ -z "${MODEL+x}" ]; then
  case "${PRECISION}" in
    fp8)
      MODEL="LGAI-EXAONE/K-EXAONE-236B-A23B-FP8"
      ;;
    bf16)
      MODEL="LGAI-EXAONE/K-EXAONE-236B-A23B"
      ;;
    *)
      echo "Unsupported PRECISION='${PRECISION}'. Use fp8 or bf16, or set MODEL explicitly." >&2
      exit 1
      ;;
  esac
fi
TOKENIZER="${TOKENIZER:-${MODEL}}"

if [ -z "${VARIANT}" ]; then
  case "${TOPOLOGY}" in
    agg) VARIANT="tp4" ;;
    disagg) VARIANT="tp4tp4" ;;
    *) VARIANT="default" ;;
  esac
fi

precision_label="$(printf '%s' "${PRECISION}" | tr '[:lower:]' '[:upper:]')"
# RUN_LABEL is used only for artifact names. Keep it filesystem-friendly.
RUN_LABEL="${RUN_LABEL:-${HARDWARE}-K-EXAONE-${precision_label}-ISL-${ISL}-OSL-${OSL}-${BACKEND}-${TOPOLOGY}-${VARIANT}-${MTP_MODE}}"

# Default service naming matches the H200 recipes. Note that pod names include
# `-0-frontend`, but the Service name does not.
#   k-exaone-h200-disagg-fp8-frontend
#   k-exaone-h200-agg-fp8-frontend
# Override SERVICE_NAME for recipes with older names, for example B200 SGLang:
#   SERVICE_NAME=k-exaone-236b-a23b-disagg-fp8-frontend
SERVICE_NAME="${SERVICE_NAME:-k-exaone-${HARDWARE}-${TOPOLOGY}-${PRECISION}-frontend}"
ENDPOINT="${ENDPOINT:-${SERVICE_NAME}:8000}"
RUNNER_NAME="${RUNNER_NAME:-k-exaone-aiperf-runner}"

CONCURRENCIES="${CONCURRENCIES:-8 16 32 48 64}"
REQUEST_MULTIPLIER="${REQUEST_MULTIPLIER:-2}"
PROFILE_MODE="${PROFILE_MODE:-single-turn}"
CONVERSATION_MULTIPLIER="${CONVERSATION_MULTIPLIER:-2}"
CONVERSATION_TURN_MEAN="${CONVERSATION_TURN_MEAN:-3}"
CONVERSATION_TURN_STDDEV="${CONVERSATION_TURN_STDDEV:-0}"
CONVERSATION_TURN_DELAY_MEAN="${CONVERSATION_TURN_DELAY_MEAN:-0}"
CONVERSATION_TURN_DELAY_STDDEV="${CONVERSATION_TURN_DELAY_STDDEV:-0}"
WARMUP_REQUEST_COUNT="${WARMUP_REQUEST_COUNT:-8}"
WORKERS_MAX="${WORKERS_MAX:-252}"
RECORD_PROCESSORS="${RECORD_PROCESSORS:-32}"
AIPERF_VERSION="${AIPERF_VERSION:-0.7.0}"
TRANSFORMERS_SPEC="${TRANSFORMERS_SPEC:-transformers>=5.1.0}"
TOKENIZERS_SPEC="${TOKENIZERS_SPEC:-tokenizers>=0.22.2}"
NUM_DATASET_ENTRIES="${NUM_DATASET_ENTRIES:-}"
RANDOM_SEED="${RANDOM_SEED:-}"

case "${PROFILE_MODE}" in
  single-turn|multi-turn) ;;
  *)
    echo "Unsupported PROFILE_MODE='${PROFILE_MODE}'. Use single-turn or multi-turn." >&2
    exit 1
    ;;
esac

REMOTE_ARTIFACT_ROOT="${REMOTE_ARTIFACT_ROOT:-/artifacts/${RUN_LABEL}}"
LOCAL_ARTIFACT_ROOT="${LOCAL_ARTIFACT_ROOT:-${HOME}/artifacts}"
LOCAL_OUTPUT_DIR="${LOCAL_OUTPUT_DIR:-${LOCAL_ARTIFACT_ROOT}/${RUN_LABEL}-cluster}"

# Optional comma-separated Prometheus metrics URLs. Example:
#   AIPERF_SERVER_METRICS_URLS="http://k-exaone-h200-disagg-fp8-frontend:8000/metrics"
#   AIPERF_GPU_TELEMETRY_URLS="http://nvidia-dcgm-exporter.gpu-operator.svc.cluster.local:9400/metrics"
AIPERF_SERVER_METRICS_URLS="${AIPERF_SERVER_METRICS_URLS:-}"
AIPERF_GPU_TELEMETRY_URLS="${AIPERF_GPU_TELEMETRY_URLS:-}"

KEEP_RUNNER="${KEEP_RUNNER:-0}"
POD_TTL_SECONDS="${POD_TTL_SECONDS:-7200}"
COPY_POLL_INTERVAL_SECONDS="${COPY_POLL_INTERVAL_SECONDS:-10}"
COPY_WAIT_TIMEOUT_SECONDS="${COPY_WAIT_TIMEOUT_SECONDS:-0}"
COPY_RETRIES="${COPY_RETRIES:-3}"
# Raw per-request exports can be tens or hundreds of MB. Copy them by
# compressing in the pod, splitting into small chunks, then reassembling locally.
COPY_RAW_PROFILE_EXPORT="${COPY_RAW_PROFILE_EXPORT:-1}"
RAW_PROFILE_CHUNK_BYTES="${RAW_PROFILE_CHUNK_BYTES:-4m}"
# AIPerf plot derives the `model` column from input_config.models.items[0].name
# first, then falls back to input_config.endpoint.model_names[0]. Keep tokenizer
# and endpoint model names real, but add this plot-facing model name.
PATCH_PLOT_MODEL_LABEL="${PATCH_PLOT_MODEL_LABEL:-1}"
# Long-lived kubectl log streams can lose the API server HTTP/2 connection.
# Keep this off by default; use tail commands manually when needed.
STREAM_LOGS="${STREAM_LOGS:-0}"

echo "Namespace:          ${NAMESPACE}"
echo "Runner pod:         ${RUNNER_NAME}"
echo "Endpoint:           http://${ENDPOINT}"
echo "Model:              ${MODEL}"
echo "Hardware:           ${HARDWARE}"
echo "Backend:            ${BACKEND}"
echo "Topology:           ${TOPOLOGY}"
echo "Variant:            ${VARIANT}"
echo "Precision:          ${PRECISION}"
echo "MTP mode:           ${MTP_MODE}"
echo "Run label:          ${RUN_LABEL}"
echo "Concurrencies:      ${CONCURRENCIES}"
echo "Profile mode:       ${PROFILE_MODE}"
if [ "${PROFILE_MODE}" = "multi-turn" ]; then
  echo "Conversation mult:  ${CONVERSATION_MULTIPLIER}"
  echo "Turn mean/stddev:   ${CONVERSATION_TURN_MEAN}/${CONVERSATION_TURN_STDDEV}"
  echo "Turn delay mean/sd: ${CONVERSATION_TURN_DELAY_MEAN}/${CONVERSATION_TURN_DELAY_STDDEV} ms"
fi
echo "Transformers spec:  ${TRANSFORMERS_SPEC}"
if [ -n "${NUM_DATASET_ENTRIES}" ]; then
  echo "Dataset entries:    ${NUM_DATASET_ENTRIES}"
fi
if [ -n "${RANDOM_SEED}" ]; then
  echo "Random seed:        ${RANDOM_SEED}"
fi
echo "Remote artifacts:   ${REMOTE_ARTIFACT_ROOT}"
echo "Local output dir:   ${LOCAL_OUTPUT_DIR}"
echo "Stream logs:        ${STREAM_LOGS}"
echo "Copy raw JSONL:     ${COPY_RAW_PROFILE_EXPORT}"
echo "Raw chunk size:     ${RAW_PROFILE_CHUNK_BYTES}"
echo "Patch plot label:   ${PATCH_PLOT_MODEL_LABEL}"

kubectl get namespace "${NAMESPACE}" >/dev/null
kubectl get svc "${SERVICE_NAME}" -n "${NAMESPACE}" >/dev/null

if kubectl get pod "${RUNNER_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Deleting existing runner pod ${RUNNER_NAME}..."
  kubectl delete pod "${RUNNER_NAME}" -n "${NAMESPACE}" --wait=true
fi

TMP_MANIFEST="$(mktemp)"
cleanup_tmp() {
  rm -f "${TMP_MANIFEST}"
}
trap cleanup_tmp EXIT

cat >"${TMP_MANIFEST}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${RUNNER_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${RUNNER_NAME}
spec:
  restartPolicy: Never
  containers:
    - name: runner
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      workingDir: /workspace
      envFrom:
        - secretRef:
            name: hf-token-secret
            optional: true
      env:
        - name: MODEL
          value: "${MODEL}"
        - name: TOKENIZER
          value: "${TOKENIZER}"
        - name: ENDPOINT
          value: "${ENDPOINT}"
        - name: ISL
          value: "${ISL}"
        - name: OSL
          value: "${OSL}"
        - name: HARDWARE
          value: "${HARDWARE}"
        - name: BACKEND
          value: "${BACKEND}"
        - name: TOPOLOGY
          value: "${TOPOLOGY}"
        - name: PRECISION
          value: "${PRECISION}"
        - name: MTP_MODE
          value: "${MTP_MODE}"
        - name: RUN_LABEL
          value: "${RUN_LABEL}"
        - name: CONCURRENCIES
          value: "${CONCURRENCIES}"
        - name: REQUEST_MULTIPLIER
          value: "${REQUEST_MULTIPLIER}"
        - name: PROFILE_MODE
          value: "${PROFILE_MODE}"
        - name: CONVERSATION_MULTIPLIER
          value: "${CONVERSATION_MULTIPLIER}"
        - name: CONVERSATION_TURN_MEAN
          value: "${CONVERSATION_TURN_MEAN}"
        - name: CONVERSATION_TURN_STDDEV
          value: "${CONVERSATION_TURN_STDDEV}"
        - name: CONVERSATION_TURN_DELAY_MEAN
          value: "${CONVERSATION_TURN_DELAY_MEAN}"
        - name: CONVERSATION_TURN_DELAY_STDDEV
          value: "${CONVERSATION_TURN_DELAY_STDDEV}"
        - name: WARMUP_REQUEST_COUNT
          value: "${WARMUP_REQUEST_COUNT}"
        - name: WORKERS_MAX
          value: "${WORKERS_MAX}"
        - name: RECORD_PROCESSORS
          value: "${RECORD_PROCESSORS}"
        - name: AIPERF_VERSION
          value: "${AIPERF_VERSION}"
        - name: TRANSFORMERS_SPEC
          value: "${TRANSFORMERS_SPEC}"
        - name: TOKENIZERS_SPEC
          value: "${TOKENIZERS_SPEC}"
        - name: NUM_DATASET_ENTRIES
          value: "${NUM_DATASET_ENTRIES}"
        - name: RANDOM_SEED
          value: "${RANDOM_SEED}"
        - name: AIPERF_SERVER_METRICS_URLS
          value: "${AIPERF_SERVER_METRICS_URLS}"
        - name: AIPERF_GPU_TELEMETRY_URLS
          value: "${AIPERF_GPU_TELEMETRY_URLS}"
        - name: REMOTE_ARTIFACT_ROOT
          value: "${REMOTE_ARTIFACT_ROOT}"
        - name: PYTHONUNBUFFERED
          value: "1"
        - name: COLUMNS
          value: "200"
        - name: HOME
          value: /tmp
        - name: PATH
          value: /tmp/.local/bin:/usr/local/bin:/usr/bin:/bin
        - name: AIPERF_HTTP_CONNECTION_LIMIT
          value: "1000"
        - name: AIPERF_HTTP_SO_RCVTIMEO
          value: "120"
        - name: AIPERF_SERVICE_PROFILE_CONFIGURE_TIMEOUT
          value: "3600"
      command:
        - /bin/bash
        - -c
      args:
        - |
          set -Eeuo pipefail
          export PATH="/tmp/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
          mkdir -p "\${REMOTE_ARTIFACT_ROOT}"
          echo "Installing AIPerf..."
          pip install --user -q "aiperf==\${AIPERF_VERSION}" "\${TRANSFORMERS_SPEC}" "\${TOKENIZERS_SPEC}"
          echo "AIPerf version:"
          aiperf --version || true

          wait_for_model_ready() {
            echo "Waiting for model '\${MODEL}' at http://\${ENDPOINT}/v1/models ..."
            python3 - <<'PY'
          import json, os, time, urllib.error, urllib.request
          endpoint = os.environ["ENDPOINT"]
          target = os.environ["MODEL"]
          for attempt in range(1, 721):
              try:
                  with urllib.request.urlopen(f"http://{endpoint}/v1/models", timeout=5) as resp:
                      data = json.load(resp)
                  if any(item.get("id") == target for item in data.get("data", [])):
                      print("Model ready", flush=True)
                      raise SystemExit(0)
              except Exception as exc:
                  if attempt % 12 == 1:
                      print(f"[{time.strftime('%H:%M:%S')}] not ready: {exc}", flush=True)
              time.sleep(5)
          raise SystemExit("model did not become ready in time")
          PY
          }

          check_metrics_urls() {
            local env_name="\$1"
            local label="\$2"
            local urls="\${!env_name:-}"
            if [ -z "\${urls}" ]; then
              echo "\${label}: no URLs configured"
              return 0
            fi

            IFS=',' read -r -a url_array <<< "\${urls}"
            for url in "\${url_array[@]}"; do
              echo "Checking \${label}: \${url}"
              python3 - "\${url}" <<'PY'
          import sys
          import urllib.request

          url = sys.argv[1]
          try:
              with urllib.request.urlopen(url, timeout=10) as resp:
                  body = resp.read(512).decode("utf-8", "replace")
                  print(f"OK {resp.status} {resp.getheader('content-type')}")
                  print(body[:512])
          except Exception as exc:
              print(f"FAILED {type(exc).__name__}: {exc}")
              raise SystemExit(1)
          PY
            done
          }

          run_one() {
            local c="\$1"
            local artifact_dir="\${REMOTE_ARTIFACT_ROOT}/pareto-c\${c}"
            local request_count=\$((c * REQUEST_MULTIPLIER))
            local conversation_num=\$((c * CONVERSATION_MULTIPLIER))
            mkdir -p "\${artifact_dir}"
            echo ""
            echo "============================================================"
            if [ "\${PROFILE_MODE}" = "multi-turn" ]; then
              echo "Running concurrency=\${c}, conversation_num=\${conversation_num}, turns=\${CONVERSATION_TURN_MEAN}+/-\${CONVERSATION_TURN_STDDEV}"
            else
              echo "Running concurrency=\${c}, request_count=\${request_count}"
            fi
            echo "Artifact dir: \${artifact_dir}"
            echo "============================================================"

            SERVER_METRICS_ARGS=()
            if [ -n "\${AIPERF_SERVER_METRICS_URLS:-}" ]; then
              IFS=',' read -r -a server_metrics_urls <<< "\${AIPERF_SERVER_METRICS_URLS}"
              if [ "\${#server_metrics_urls[@]}" -gt 0 ]; then
                SERVER_METRICS_ARGS+=(--server-metrics "\${server_metrics_urls[@]}")
              fi
            fi

            GPU_TELEMETRY_ARGS=()
            if [ -n "\${AIPERF_GPU_TELEMETRY_URLS:-}" ]; then
              IFS=',' read -r -a gpu_telemetry_urls <<< "\${AIPERF_GPU_TELEMETRY_URLS}"
              if [ "\${#gpu_telemetry_urls[@]}" -gt 0 ]; then
                GPU_TELEMETRY_ARGS+=(--gpu-telemetry "\${gpu_telemetry_urls[@]}")
              fi
            fi

            set +e
            DATASET_ARGS=()
            if [ -n "\${NUM_DATASET_ENTRIES:-}" ]; then
              DATASET_ARGS+=(--num-dataset-entries "\${NUM_DATASET_ENTRIES}")
            fi
            if [ -n "\${RANDOM_SEED:-}" ]; then
              DATASET_ARGS+=(--random-seed "\${RANDOM_SEED}")
            fi

            COMMON_ARGS=(
              --model "\${MODEL}"
              --tokenizer "\${TOKENIZER}"
              --tokenizer-trust-remote-code
              --url "http://\${ENDPOINT}"
              --endpoint-type chat
              --endpoint /v1/chat/completions
              --streaming
              --isl "\${ISL}"
              --osl "\${OSL}"
              --extra-inputs "max_tokens:\${OSL}"
              --extra-inputs "min_tokens:\${OSL}"
              --extra-inputs "ignore_eos:true"
              --concurrency "\${c}"
              --warmup-request-count "\${WARMUP_REQUEST_COUNT}"
              --workers-max "\${WORKERS_MAX}"
              --record-processors "\${RECORD_PROCESSORS}"
              --ui simple
              --artifact-dir "\${artifact_dir}"
              "\${DATASET_ARGS[@]}"
            )
            if [ "\${PROFILE_MODE}" = "multi-turn" ]; then
              aiperf profile \
                "\${COMMON_ARGS[@]}" \
                --conversation-num "\${conversation_num}" \
                --conversation-turn-mean "\${CONVERSATION_TURN_MEAN}" \
                --conversation-turn-stddev "\${CONVERSATION_TURN_STDDEV}" \
                --conversation-turn-delay-mean "\${CONVERSATION_TURN_DELAY_MEAN}" \
                --conversation-turn-delay-stddev "\${CONVERSATION_TURN_DELAY_STDDEV}" \
                "\${SERVER_METRICS_ARGS[@]}" \
                "\${GPU_TELEMETRY_ARGS[@]}"
            else
              aiperf profile \
                "\${COMMON_ARGS[@]}" \
                --request-count "\${request_count}" \
                "\${SERVER_METRICS_ARGS[@]}" \
                "\${GPU_TELEMETRY_ARGS[@]}"
            fi
            local rc="\$?"
            set -e
            echo "\${rc}" > "\${artifact_dir}/aiperf_exit_code.txt"
            if [ "\${rc}" -ne 0 ]; then
              echo "AIPerf failed for concurrency \${c} with exit code \${rc}; continuing so artifacts can be copied."
            fi
          }

          wait_for_model_ready
          check_metrics_urls AIPERF_SERVER_METRICS_URLS "server metrics"
          check_metrics_urls AIPERF_GPU_TELEMETRY_URLS "GPU telemetry"
          date -u +"%Y-%m-%dT%H:%M:%SZ" > "\${REMOTE_ARTIFACT_ROOT}/started_at_utc.txt"
          cat > "\${REMOTE_ARTIFACT_ROOT}/run_config.txt" <<CFG
          MODEL=\${MODEL}
          TOKENIZER=\${TOKENIZER}
          ENDPOINT=http://\${ENDPOINT}
          ISL=\${ISL}
          OSL=\${OSL}
          HARDWARE=\${HARDWARE}
          BACKEND=\${BACKEND}
          TOPOLOGY=\${TOPOLOGY}
          PRECISION=\${PRECISION}
          MTP_MODE=\${MTP_MODE}
          RUN_LABEL=\${RUN_LABEL}
          CONCURRENCIES=\${CONCURRENCIES}
          PROFILE_MODE=\${PROFILE_MODE}
          REQUEST_MULTIPLIER=\${REQUEST_MULTIPLIER}
          CONVERSATION_MULTIPLIER=\${CONVERSATION_MULTIPLIER}
          CONVERSATION_TURN_MEAN=\${CONVERSATION_TURN_MEAN}
          CONVERSATION_TURN_STDDEV=\${CONVERSATION_TURN_STDDEV}
          CONVERSATION_TURN_DELAY_MEAN=\${CONVERSATION_TURN_DELAY_MEAN}
          CONVERSATION_TURN_DELAY_STDDEV=\${CONVERSATION_TURN_DELAY_STDDEV}
          NUM_DATASET_ENTRIES=\${NUM_DATASET_ENTRIES}
          RANDOM_SEED=\${RANDOM_SEED}
          AIPERF_VERSION=\${AIPERF_VERSION}
          TRANSFORMERS_SPEC=\${TRANSFORMERS_SPEC}
          TOKENIZERS_SPEC=\${TOKENIZERS_SPEC}
          AIPERF_SERVER_METRICS_URLS=\${AIPERF_SERVER_METRICS_URLS}
          AIPERF_GPU_TELEMETRY_URLS=\${AIPERF_GPU_TELEMETRY_URLS}
          CFG

          for c in \${CONCURRENCIES}; do
            run_one "\${c}"
          done

          date -u +"%Y-%m-%dT%H:%M:%SZ" > "\${REMOTE_ARTIFACT_ROOT}/finished_at_utc.txt"
          echo "All runs finished. Keeping pod alive for kubectl cp."
          echo "READY_FOR_COPY" > /tmp/ready_for_copy
          sleep ${POD_TTL_SECONDS}
EOF

kubectl apply -f "${TMP_MANIFEST}"

echo "Waiting for runner pod to start..."
kubectl wait --for=condition=Ready "pod/${RUNNER_NAME}" -n "${NAMESPACE}" --timeout=600s

echo ""
mkdir -p "${LOCAL_OUTPUT_DIR}"
LOG_PID=""
if [ "${STREAM_LOGS}" = "1" ]; then
  echo "Streaming runner logs in the background."
  kubectl logs -f "pod/${RUNNER_NAME}" -n "${NAMESPACE}" --container runner &
  LOG_PID="$!"
else
  echo "Runner logs are not streamed. Check progress with:"
  echo "  kubectl logs ${RUNNER_NAME} -n ${NAMESPACE} --tail=80"
fi

stop_log_stream() {
  if [ -z "${LOG_PID}" ]; then
    return 0
  fi
  if kill -0 "${LOG_PID}" >/dev/null 2>&1; then
    kill "${LOG_PID}" >/dev/null 2>&1 || true
    wait "${LOG_PID}" >/dev/null 2>&1 || true
  fi
}

wait_for_remote_file() {
  local remote_file="$1"
  local label="$2"
  local elapsed=0
  while true; do
    if kubectl exec -n "${NAMESPACE}" "${RUNNER_NAME}" -- test -f "${remote_file}" >/dev/null 2>&1; then
      return 0
    fi

    local pod_check_output
    if ! pod_check_output="$(kubectl get pod "${RUNNER_NAME}" -n "${NAMESPACE}" 2>&1)"; then
      case "${pod_check_output}" in
        *NotFound*|*"not found"*)
          echo "Runner pod disappeared while waiting for ${label}."
          return 1
          ;;
        *)
          echo "Could not verify runner pod while waiting for ${label}; retrying. kubectl said: ${pod_check_output}"
          ;;
      esac
    fi

    if [ "${COPY_WAIT_TIMEOUT_SECONDS}" -gt 0 ] && [ "${elapsed}" -ge "${COPY_WAIT_TIMEOUT_SECONDS}" ]; then
      echo "Timed out waiting for ${label} after ${elapsed}s."
      return 1
    fi

    sleep "${COPY_POLL_INTERVAL_SECONDS}"
    elapsed=$((elapsed + COPY_POLL_INTERVAL_SECONDS))
  done
}

copy_remote_file() {
  local remote_file="$1"
  local local_file="$2"
  local label="$3"
  local tmp_file="${local_file}.tmp"
  local attempt

  mkdir -p "$(dirname "${local_file}")"

  for attempt in $(seq 1 "${COPY_RETRIES}"); do
    if kubectl exec -n "${NAMESPACE}" "${RUNNER_NAME}" -- test -f "${remote_file}" >/dev/null 2>&1; then
      if kubectl exec -n "${NAMESPACE}" "${RUNNER_NAME}" -- cat "${remote_file}" > "${tmp_file}"; then
        mv "${tmp_file}" "${local_file}"
        return 0
      fi
    fi

    rm -f "${tmp_file}"
    echo "Retrying copy for ${label} (${attempt}/${COPY_RETRIES})..."
    sleep "$((attempt * 2))"
  done

  echo "WARNING: failed to copy ${label} from ${remote_file}"
  return 1
}

copy_remote_file_if_present() {
  local remote_file="$1"
  local local_file="$2"
  local label="$3"

  if kubectl exec -n "${NAMESPACE}" "${RUNNER_NAME}" -- test -f "${remote_file}" >/dev/null 2>&1; then
    copy_remote_file "${remote_file}" "${local_file}" "${label}"
  fi
}

copy_remote_gzip_chunks_if_present() {
  local remote_file="$1"
  local local_file="$2"
  local label="$3"
  local chunk_id
  local remote_gz
  local remote_chunk_dir
  local local_gz
  local local_chunk_dir
  local chunks_file
  local chunk
  local remote_size
  local local_size

  if ! kubectl exec -n "${NAMESPACE}" "${RUNNER_NAME}" -- test -f "${remote_file}" >/dev/null 2>&1; then
    return 0
  fi

  chunk_id="$(printf '%s' "${label}" | tr -c 'A-Za-z0-9._-' '_')"
  remote_gz="/tmp/${chunk_id}.gz"
  remote_chunk_dir="/tmp/${chunk_id}.chunks"
  local_gz="${local_file}.gz"
  local_chunk_dir="${local_file}.chunks"
  chunks_file="${local_file}.chunks.list"

  mkdir -p "$(dirname "${local_file}")"
  rm -rf "${local_chunk_dir}"
  mkdir -p "${local_chunk_dir}"
  rm -f "${local_gz}" "${local_file}" "${chunks_file}"

  echo "Preparing compressed chunks for ${label} ..."
  kubectl exec -n "${NAMESPACE}" "${RUNNER_NAME}" -- sh -lc \
    "rm -rf '${remote_chunk_dir}' '${remote_gz}' && mkdir -p '${remote_chunk_dir}' && gzip -c '${remote_file}' > '${remote_gz}' && split -b '${RAW_PROFILE_CHUNK_BYTES}' '${remote_gz}' '${remote_chunk_dir}/chunk-' && ls -1 '${remote_chunk_dir}'" \
    > "${chunks_file}"

  while IFS= read -r chunk; do
    [ -n "${chunk}" ] || continue
    echo "Copying ${label} chunk ${chunk} ..."
    copy_remote_file "${remote_chunk_dir}/${chunk}" "${local_chunk_dir}/${chunk}" "${label}/${chunk}"
  done < "${chunks_file}"

  cat "${local_chunk_dir}"/chunk-* > "${local_gz}"
  gzip -dc "${local_gz}" > "${local_file}"

  remote_size="$(kubectl exec -n "${NAMESPACE}" "${RUNNER_NAME}" -- wc -c "${remote_file}" | awk '{print $1}')"
  local_size="$(wc -c < "${local_file}")"
  if [ "${remote_size}" != "${local_size}" ]; then
    echo "WARNING: size mismatch for ${label}: remote=${remote_size}, local=${local_size}"
    return 1
  fi

  rm -rf "${local_chunk_dir}" "${chunks_file}"
  echo "Copied ${label}; bytes=${local_size}, compressed=$(wc -c < "${local_gz}")"
}

patch_profile_export_plot_label() {
  local profile_json="$1"
  local label="$2"

  if [ "${PATCH_PLOT_MODEL_LABEL}" != "1" ]; then
    return 0
  fi
  if [ ! -f "${profile_json}" ]; then
    return 0
  fi

  python3 - "${profile_json}" "${label}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
label = sys.argv[2]

data = json.loads(path.read_text())
input_config = data.setdefault("input_config", {})

# AIPerf plot's data loader resolves the model column from
# input_config.models.items[0].name before falling back to
# input_config.endpoint.model_names[0]. Add only the plot-facing field and
# preserve tokenizer.name plus endpoint.model_names as the actual served model.
models = input_config.setdefault("models", {})
items = models.setdefault("items", [{}])
if not isinstance(items, list) or not items:
    items = [{}]
    models["items"] = items
if not isinstance(items[0], dict):
    items[0] = {}
items[0]["name"] = label

path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
}

summarize_turn_metrics() {
  local profile_jsonl="$1"
  local summary_csv="$2"

  if [ ! -f "${profile_jsonl}" ]; then
    return 0
  fi

  python3 - "${profile_jsonl}" "${summary_csv}" <<'PY'
import csv
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
groups = defaultdict(lambda: {"ttft": [], "latency": [], "isl": [], "osl": []})

with source.open() as handle:
    for line in handle:
        if not line.strip():
            continue
        record = json.loads(line)
        metadata = record.get("metadata", {})
        if metadata.get("benchmark_phase") != "profiling":
            continue
        turn = metadata.get("turn_index")
        if turn is None:
            continue
        metrics = record.get("metrics", {})
        values = groups[int(turn)]
        for key, target in (
            ("time_to_first_token", "ttft"),
            ("request_latency", "latency"),
            ("input_sequence_length", "isl"),
            ("output_sequence_length", "osl"),
        ):
            value = metrics.get(key, {}).get("value")
            if isinstance(value, (int, float)):
                values[target].append(float(value))

def percentile(values, q):
    if not values:
        return ""
    ordered = sorted(values)
    position = (len(ordered) - 1) * q
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)

rows = []
for turn, values in sorted(groups.items()):
    rows.append((str(turn), values))

followup = {"ttft": [], "latency": [], "isl": [], "osl": []}
for turn, values in groups.items():
    if turn >= 1:
        for key in followup:
            followup[key].extend(values[key])
if followup["ttft"]:
    rows.append(("followup_turns", followup))

destination.parent.mkdir(parents=True, exist_ok=True)
with destination.open("w", newline="") as handle:
    writer = csv.writer(handle)
    writer.writerow([
        "turn",
        "count",
        "ttft_p50_ms",
        "ttft_p95_ms",
        "ttft_p99_ms",
        "request_latency_p50_ms",
        "request_latency_p95_ms",
        "request_latency_p99_ms",
        "input_tokens_avg",
        "output_tokens_avg",
    ])
    for label, values in rows:
        writer.writerow([
            label,
            len(values["ttft"]),
            percentile(values["ttft"], 0.50),
            percentile(values["ttft"], 0.95),
            percentile(values["ttft"], 0.99),
            percentile(values["latency"], 0.50),
            percentile(values["latency"], 0.95),
            percentile(values["latency"], 0.99),
            sum(values["isl"]) / len(values["isl"]) if values["isl"] else "",
            sum(values["osl"]) / len(values["osl"]) if values["osl"] else "",
        ])
PY
}

copy_concurrency_artifacts() {
  local c="$1"
  local remote_dir="${REMOTE_ARTIFACT_ROOT}/pareto-c${c}"
  local marker="${remote_dir}/aiperf_exit_code.txt"
  local local_dir="${LOCAL_OUTPUT_DIR}/pareto-c${c}"

  echo ""
  echo "Waiting for concurrency ${c} artifacts..."
  if ! wait_for_remote_file "${marker}" "pareto-c${c} completion marker"; then
    echo "Skipping copy for pareto-c${c}; completion marker not found."
    return 1
  fi

  mkdir -p "${local_dir}"
  echo "Copying pareto-c${c} summary artifacts to ${local_dir} ..."

  copy_remote_file "${marker}" "${local_dir}/aiperf_exit_code.txt" "pareto-c${c}/aiperf_exit_code.txt" || true
  copy_remote_file_if_present "${remote_dir}/profile_export_aiperf.json" "${local_dir}/profile_export_aiperf.json" "pareto-c${c}/profile_export_aiperf.json" || true
  patch_profile_export_plot_label "${local_dir}/profile_export_aiperf.json" "${RUN_LABEL}"
  copy_remote_file_if_present "${remote_dir}/profile_export_aiperf.csv" "${local_dir}/profile_export_aiperf.csv" "pareto-c${c}/profile_export_aiperf.csv" || true
  copy_remote_file_if_present "${remote_dir}/gpu_telemetry_export.jsonl" "${local_dir}/gpu_telemetry_export.jsonl" "pareto-c${c}/gpu_telemetry_export.jsonl" || true
  copy_remote_file_if_present "${remote_dir}/server_metrics_export.json" "${local_dir}/server_metrics_export.json" "pareto-c${c}/server_metrics_export.json" || true
  copy_remote_file_if_present "${remote_dir}/server_metrics_export.csv" "${local_dir}/server_metrics_export.csv" "pareto-c${c}/server_metrics_export.csv" || true
  copy_remote_file_if_present "${remote_dir}/inputs.json" "${local_dir}/inputs.json" "pareto-c${c}/inputs.json" || true
  copy_remote_file_if_present "${remote_dir}/logs/aiperf.log" "${local_dir}/logs/aiperf.log" "pareto-c${c}/logs/aiperf.log" || true

  if [ "${COPY_RAW_PROFILE_EXPORT}" = "1" ]; then
    copy_remote_gzip_chunks_if_present "${remote_dir}/profile_export.jsonl" "${local_dir}/profile_export.jsonl" "pareto-c${c}/profile_export.jsonl" || true
    summarize_turn_metrics "${local_dir}/profile_export.jsonl" "${local_dir}/turn_metrics_summary.csv"
  fi

  local exit_code
  exit_code="$(kubectl exec -n "${NAMESPACE}" "${RUNNER_NAME}" -- sh -lc "cat '${marker}'" 2>/dev/null || echo unknown)"
  echo "Copied pareto-c${c}; aiperf_exit_code=${exit_code}"
}

for c in ${CONCURRENCIES}; do
  copy_concurrency_artifacts "${c}" || true
done

echo ""
echo "Waiting for final artifact sentinel..."
wait_for_remote_file /tmp/ready_for_copy "final READY_FOR_COPY sentinel" || true

echo "Copying root metadata files to ${LOCAL_OUTPUT_DIR} ..."
for metadata_file in run_config.txt started_at_utc.txt finished_at_utc.txt; do
  copy_remote_file_if_present "${REMOTE_ARTIFACT_ROOT}/${metadata_file}" "${LOCAL_OUTPUT_DIR}/${metadata_file}" "${metadata_file}" || true
done

stop_log_stream

echo "Artifacts copied to ${LOCAL_OUTPUT_DIR}"
find "${LOCAL_OUTPUT_DIR}" -maxdepth 2 -type f | sort | sed 's#^#  #'

if [ "${KEEP_RUNNER}" != "1" ]; then
  echo "Deleting runner pod ${RUNNER_NAME} ..."
  kubectl delete pod "${RUNNER_NAME}" -n "${NAMESPACE}" --wait=false >/dev/null || true
else
  echo "Keeping runner pod ${RUNNER_NAME}. Delete it with:"
  echo "  kubectl delete pod ${RUNNER_NAME} -n ${NAMESPACE}"
fi
