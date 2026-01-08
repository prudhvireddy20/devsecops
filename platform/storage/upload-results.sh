#!/bin/bash
set -euo pipefail

# Upload scan results to object storage
# Supports S3-compatible storage (AWS S3, MinIO, etc.)

RESULTS_DIR="${1:-/tmp/scanner-results}"
SCAN_ID="${2:-$(date +%s)}"
STORAGE_TYPE="${STORAGE_TYPE:-s3}"
BUCKET_NAME="${BUCKET_NAME:-security-scan-results}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Upload to S3-compatible storage
upload_to_s3() {
    local endpoint="${S3_ENDPOINT:-}"
    local access_key="${AWS_ACCESS_KEY_ID:-}"
    local secret_key="${AWS_SECRET_ACCESS_KEY:-}"
    local region="${AWS_REGION:-us-east-1}"
    
    if [ -z "$access_key" ] || [ -z "$secret_key" ]; then
        log "S3 credentials not configured, skipping upload"
        return 0
    fi
    
    log "Uploading results to S3 bucket: $BUCKET_NAME"
    
    # Use AWS CLI if available, otherwise use MinIO client
    if command -v aws &> /dev/null; then
        if [ -n "$endpoint" ]; then
            aws s3 sync "$RESULTS_DIR" "s3://$BUCKET_NAME/scans/$SCAN_ID/" \
                --endpoint-url "$endpoint" \
                --region "$region" || true
        else
            aws s3 sync "$RESULTS_DIR" "s3://$BUCKET_NAME/scans/$SCAN_ID/" \
                --region "$region" || true
        fi
    elif command -v mc &> /dev/null; then
        mc alias set storage "$endpoint" "$access_key" "$secret_key" || true
        mc mirror "$RESULTS_DIR" "storage/$BUCKET_NAME/scans/$SCAN_ID/" || true
    else
        log "No S3 client available (aws or mc), skipping upload"
    fi
}

# Upload to local filesystem (for development)
upload_to_local() {
    local storage_path="${LOCAL_STORAGE_PATH:-/tmp/scan-storage}"
    mkdir -p "$storage_path/scans/$SCAN_ID"
    cp -r "$RESULTS_DIR"/* "$storage_path/scans/$SCAN_ID/" || true
    log "Results copied to local storage: $storage_path/scans/$SCAN_ID"
}

case "$STORAGE_TYPE" in
    "s3")
        upload_to_s3
        ;;
    "local")
        upload_to_local
        ;;
    *)
        log "Unknown storage type: $STORAGE_TYPE, using local"
        upload_to_local
        ;;
esac

log "Upload completed"
