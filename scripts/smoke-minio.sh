#!/bin/bash
# End-to-end smoke test for MinIO or any S3-compatible endpoint.
# Credentials are supplied through the environment and are never written to disk
# or printed. The harness creates a uniquely named bucket, exercises the API,
# and always attempts cleanup.
#
# Usage:
#   MINIO_ENDPOINT=http://127.0.0.1:9000 \
#   MINIO_ACCESS_KEY=... \
#   MINIO_SECRET_KEY=... \
#   ./scripts/smoke-minio.sh
#
# Optional: MINIO_REGION (default us-east-1)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${MINIO_ENDPOINT:-}" || -z "${MINIO_ACCESS_KEY:-}" || -z "${MINIO_SECRET_KEY:-}" ]]; then
    cat >&2 <<'USAGE'
error: MINIO_ENDPOINT, MINIO_ACCESS_KEY, and MINIO_SECRET_KEY are required.

usage:
  MINIO_ENDPOINT=http://127.0.0.1:9000 \
  MINIO_ACCESS_KEY=... \
  MINIO_SECRET_KEY=... \
  ./scripts/smoke-minio.sh
USAGE
    exit 2
fi

swift run -c release S3SilSmoke
