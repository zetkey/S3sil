#!/bin/bash
# Start Docker containers for S3Sil protocol smoke tests.
# Prerequisites: Docker must be running.
# Cleanup: run scripts/smoke-docker-stop.sh when done.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

# Test data — pre-seeded with hello.txt, nested-file.txt, subdir/deeper.txt, toplevel.dat
DATA_DIR="/tmp/s3sil-smoke-data"
mkdir -p "$DATA_DIR"
if [ ! -f "$DATA_DIR/hello.txt" ]; then
    echo "hello from s3sil smoke - webdav" > "$DATA_DIR/hello.txt"
    echo "nested file content" > "$DATA_DIR/nested-file.txt"
    mkdir -p "$DATA_DIR/subdir"
    echo "deeper file" > "$DATA_DIR/subdir/deeper.txt"
    echo "another top-level file" > "$DATA_DIR/toplevel.dat"
    echo "Seeded test data in $DATA_DIR"
fi

echo "=== Cleaning up old containers ==="
docker rm -f s3sil-webdav s3sil-ftp s3sil-sftp 2>/dev/null || true

echo "=== Starting WebDAV (port 8080) ==="
docker run -d --name s3sil-webdav \
    -p 8080:80 \
    -e USERNAME=testuser \
    -e PASSWORD=testpass \
    -v "$DATA_DIR:/var/lib/dav/data" \
    bytemark/webdav

echo "=== Starting FTP (port 2121) ==="
docker run -d --name s3sil-ftp \
    -p 2121:21 \
    -p 21100-21110:21100-21110 \
    -e USERS="testuser|testpass|/ftp/testuser" \
    -e ADDRESS=127.0.0.1 \
    -e MIN_PORT=21100 \
    -e MAX_PORT=21110 \
    -v "$DATA_DIR:/ftp/testuser" \
    delfer/alpine-ftp-server

echo "=== Starting SFTP (port 2222) ==="
# Generate SSH key if needed
KEY_DIR="/tmp/s3sil-sftp-ssh"
mkdir -p "$KEY_DIR"
if [ ! -f /tmp/s3sil-sftp-key ]; then
    ssh-keygen -t ed25519 -f /tmp/s3sil-sftp-key -N "" -C "s3sil-smoke" -q
    echo "Generated SFTP key"
fi
cp /tmp/s3sil-sftp-key.pub "$KEY_DIR/authorized_keys"
chmod 600 "$KEY_DIR/authorized_keys"

docker run -d --name s3sil-sftp \
    -p 2222:22 \
    -v "$DATA_DIR:/home/testuser/data" \
    -v "$KEY_DIR:/home/testuser/.ssh:ro" \
    atmoz/sftp "testuser:testpass:::data"

# Wait for containers to be healthy
echo "=== Waiting for containers ==="
sleep 3

echo "=== Status ==="
docker ps --filter name=s3sil- --format '{{.Names}} {{.Status}} {{.Ports}}'

echo ""
echo "Containers ready. Run smoke tests:"
echo "  swift run S3SilSmoke --webdav"
echo "  swift run S3SilSmoke --ftp"
echo "  swift run S3SilSmoke --sftp"