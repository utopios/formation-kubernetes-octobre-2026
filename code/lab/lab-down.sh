#!/usr/bin/env bash
# Supprime le cluster de lab.
set -euo pipefail
if [ "${LAB_PROVIDER:-docker}" = "podman" ]; then export KIND_EXPERIMENTAL_PROVIDER=podman; fi
kind delete cluster --name k8s-formation
