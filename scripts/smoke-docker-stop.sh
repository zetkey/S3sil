#!/bin/bash
# Stop and remove S3Sil smoke test Docker containers.

set -euo pipefail

echo "=== Stopping S3Sil smoke containers ==="
docker stop s3sil-webdav s3sil-ftp s3sil-sftp 2>/dev/null || true
docker rm -f s3sil-webdav s3sil-ftp s3sil-sftp 2>/dev/null || true

echo "=== Cleanup ==="
# Remove SFTP key (optional — comment out to keep between runs)
rm -f /tmp/s3sil-sftp-key /tmp/s3sil-sftp-key.pub
rm -rf /tmp/s3sil-sftp-ssh

# Clean known hosts cache
rm -f ~/.s3sil/known_hosts

echo "Smoke containers removed."