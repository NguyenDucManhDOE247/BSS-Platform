#!/usr/bin/env bash
# Deletes the "bss" kind cluster entirely (nodes are just Docker containers — this removes them
# and every volume kind created for them, including the Postgres PVC's backing directory).
# There is no "stop, keep data" mode for kind the way docker-compose has `down` vs `down -v` —
# deleting the cluster always wipes it. Re-run scripts/kind-up.sh to get a fresh one.
set -euo pipefail
kind delete cluster --name bss
