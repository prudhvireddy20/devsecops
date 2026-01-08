#!/bin/bash
set -euo pipefail

# Generate scan summary from results

RESULTS_DIR="${1:-/tmp/scanner-results}"
SUMMARY_FILE="${2:-/tmp/scan-summary.json}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Count findings from JSON results
count_findings() {
    local file="$1"
    local scanner="$2"
    
    if [ ! -f "$file" ]; then
        echo "0"
        return
    fi
    
    case "$scanner" in
        "semgrep")
            jq '[.results[]?] | length' "$file" 2>/dev/null || echo "0"
            ;;
        "gitleaks")
            jq '[.[]?] | length' "$file" 2>/dev/null || echo "0"
            ;;
        "osv-scanner")
            jq '[.results[]?.packages[]?.vulnerabilities[]?] | length' "$file" 2>/dev/null || echo "0"
            ;;
        "trivy")
            jq '[.Results[]?.Vulnerabilities[]?] | length' "$file" 2>/dev/null || echo "0"
            ;;
        "codeql")
            jq '[.runs[0].results[]?] | length' "$file" 2>/dev/null || echo "0"
            ;;
        *)
            echo "0"
            ;;
    esac
}

# Generate summary JSON
generate_summary() {
    local summary="{}"
    
    log "Generating scan summary..."
    
    # Process each scanner result
    for result_file in "$RESULTS_DIR"/*.json "$RESULTS_DIR"/*.sarif; do
        if [ ! -f "$result_file" ]; then
            continue
        fi
        
        local basename=$(basename "$result_file")
        local scanner="unknown"
        
        if [[ "$basename" == semgrep-* ]]; then
            scanner="semgrep"
        elif [[ "$basename" == gitleaks-* ]]; then
            scanner="gitleaks"
        elif [[ "$basename" == osv-scanner-* ]]; then
            scanner="osv_scanner"
        elif [[ "$basename" == trivy-* ]]; then
            scanner="trivy"
        elif [[ "$basename" == codeql-* ]]; then
            scanner="codeql"
        elif [[ "$basename" == syft-* ]]; then
            scanner="syft"
        elif [[ "$basename" == noir-* ]]; then
            scanner="noir"
        fi
        
        local findings=$(count_findings "$result_file" "$scanner")
        local file_size=$(stat -f%z "$result_file" 2>/dev/null || stat -c%s "$result_file" 2>/dev/null || echo "0")
        
        summary=$(echo "$summary" | jq --arg scanner "$scanner" \
            --arg file "$basename" \
            --argjson findings "$findings" \
            --argjson size "$file_size" \
            '. + {($scanner): {file: $file, findings: $findings, size_bytes: $size}}')
    done
    
    # Add metadata
    summary=$(echo "$summary" | jq --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg scan_id "${SCAN_ID:-$(date +%s)}" \
        '. + {metadata: {timestamp: $timestamp, scan_id: $scan_id}}')
    
    echo "$summary"
}

generate_summary | jq '.' > "$SUMMARY_FILE"
cat "$SUMMARY_FILE"
