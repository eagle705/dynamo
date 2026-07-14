#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-dynamo-demo}"
DGD_NAME="${DGD_NAME:-k-exaone-h200-agg-fp8-tp4}"

kubectl delete pod k-exaone-aiperf-runner -n "${NAMESPACE}" --ignore-not-found=true
kubectl delete dynamographdeployment "${DGD_NAME}" -n "${NAMESPACE}" --ignore-not-found=true