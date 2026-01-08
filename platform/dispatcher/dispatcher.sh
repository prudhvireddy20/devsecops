#!/bin/bash
set -uo pipefail  # Don't exit on error, but still catch undefined vars

# Centralized Security Scan Dispatcher
# Dynamically executes scanners based on JSON configuration

CONFIG_FILE="${1:-/tmp/scan-config.json}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/scanner-results}"
SCAN_ID="${SCAN_ID:-$(date +%s)}"
EXIT_CODE=0  # Track if any scanner fails

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Parse JSON config using jq
get_config() {
    jq -r "$1" "$CONFIG_FILE" 2>/dev/null || echo ""
}

# Check if scanner is enabled
is_scanner_enabled() {
    local scanner=$1
    get_config ".scanners.${scanner}.enabled" | grep -q "true" || false
}

# Get scan target
get_scan_target() {
    local target_type=$(get_config ".target.type")
    local target_path=$(get_config ".target.path")
    local scan_scope=$(get_config ".scan_scope.type // \"full\"")
    local single_file=$(get_config ".scan_scope.single_file // empty")
    
    # Handle single file scanning
    if [ "$scan_scope" = "single_file" ] && [ -n "$single_file" ] && [ "$single_file" != "null" ]; then
        echo "$single_file"
        return
    fi
    
    case "$target_type" in
        "file")
            echo "$target_path"
            ;;
        "directory")
            echo "$target_path"
            ;;
        "repository")
            echo "."
            ;;
        *)
            echo "."
            ;;
    esac
}

# Repository inspection for automated scanner selection
inspect_repository() {
    local target=$(get_scan_target)
    local detected_languages=()
    local has_dockerfile=false
    local has_dependencies=false
    
    log "Inspecting repository structure..."
    
    # Detect languages
    if [ -f "$target/Dockerfile" ] || [ -f "$target/docker-compose.yml" ]; then
        has_dockerfile=true
        log "  ✓ Dockerfile detected - enabling Trivy container scan"
    fi
    
    # Detect dependency files
    for dep_file in package.json package-lock.json yarn.lock pnpm-lock.yaml \
                    requirements.txt Pipfile.lock poetry.lock \
                    pom.xml build.gradle gradle.lockfile \
                    go.mod go.sum \
                    Cargo.toml Cargo.lock \
                    Gemfile Gemfile.lock \
                    packages.lock.json *.csproj \
                    composer.lock; do
        if find "$target" -name "$dep_file" -type f | grep -q .; then
            has_dependencies=true
            log "  ✓ Dependency file detected: $dep_file - enabling OSV-Scanner"
            break
        fi
    done
    
    # Detect source code languages
    if find "$target" -name "*.java" -type f | head -1 | grep -q .; then
        detected_languages+=("java")
        log "  ✓ Java source code detected"
    fi
    if find "$target" -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" | head -1 | grep -q .; then
        detected_languages+=("cpp")
        log "  ✓ C/C++ source code detected"
    fi
    if find "$target" -name "*.go" -type f | head -1 | grep -q .; then
        detected_languages+=("go")
        log "  ✓ Go source code detected"
    fi
    if find "$target" -name "*.js" -o -name "*.jsx" -o -name "*.ts" -o -name "*.tsx" | head -1 | grep -q .; then
        detected_languages+=("javascript")
        log "  ✓ JavaScript/TypeScript source code detected"
    fi
    if find "$target" -name "*.py" -type f | head -1 | grep -q .; then
        detected_languages+=("python")
        log "  ✓ Python source code detected"
    fi
    if find "$target" -name "*.cs" -type f | head -1 | grep -q .; then
        detected_languages+=("csharp")
        log "  ✓ C# source code detected"
    fi
    
    # Auto-enable scanners based on detection
    if [ ${#detected_languages[@]} -gt 0 ]; then
        log "  ✓ Source code detected - enabling Semgrep SAST"
    fi
    
    # Always enable secret detection
    log "  ✓ Enabling Gitleaks for secret detection"
    
    echo "${detected_languages[@]}"
}

# Check if Docker is available
check_docker() {
    if ! command -v docker &> /dev/null; then
        warn "Docker not available, skipping containerized scanners"
        return 1
    fi
    if ! docker info &> /dev/null; then
        warn "Docker daemon not running, skipping containerized scanners"
        return 1
    fi
    return 0
}

# Execute Semgrep scan
run_semgrep() {
    if ! check_docker; then
        warn "Docker not available, skipping Semgrep"
        EXIT_CODE=1
        return 1
    fi
    
    local target=$(get_scan_target)
    local output_file="$RESULTS_DIR/semgrep-${SCAN_ID}.json"
    local config_path=$(get_config ".scanners.semgrep.config_path // \"security/semgrep-rules\"")
    local scan_scope=$(get_config ".scan_scope.type // \"full\"")
    
    log "Running Semgrep SAST scan on: $target"
    
    # Resolve absolute path for volume mounting
    local abs_target=$(realpath "$target" 2>/dev/null || echo "$target")
    local abs_pwd=$(pwd)
    
    # For single file, use file path directly
    if [ "$scan_scope" = "single_file" ]; then
        if docker run --rm \
            -v "$abs_pwd:/src" \
            -w /src \
            semgrep/semgrep:latest \
            semgrep scan "$target" \
            --config "$config_path" \
            --config auto \
            --json \
            --output "$output_file" 2>&1; then
            log "Semgrep scan completed successfully"
        else
            warn "Semgrep scan encountered issues (check output)"
            EXIT_CODE=1
        fi
    else
        if docker run --rm \
            -v "$abs_pwd:/src" \
            -w /src \
            semgrep/semgrep:latest \
            semgrep scan "$target" \
            --config "$config_path" \
            --config auto \
            --config p/owasp-top-ten \
            --json \
            --output "$output_file" 2>&1; then
            log "Semgrep scan completed successfully"
        else
            warn "Semgrep scan encountered issues (check output)"
            EXIT_CODE=1
        fi
    fi
    
    if [ -f "$output_file" ]; then
        log "Semgrep results saved to $output_file"
    else
        warn "Semgrep output file not created"
        EXIT_CODE=1
    fi
}

# Execute CodeQL scan with proper build mode
run_codeql() {
    local target=$(get_scan_target)
    local languages_json=$(get_config ".scanners.codeql.languages // [\"auto\"]")
    local languages=$(echo "$languages_json" | jq -r '.[]' 2>/dev/null || echo "auto")
    local build_mode=$(get_config ".scanners.codeql.build_mode // \"auto\"")
    
    # Check if CodeQL is available
    if ! command -v codeql &> /dev/null; then
        warn "CodeQL CLI not found. Install it or use GitHub Actions codeql-action. Skipping CodeQL scan."
        EXIT_CODE=1
        return 1
    fi
    
    log "Running CodeQL analysis..."
    
    # If languages is auto, detect from repository
    if [ "$languages" = "auto" ] || [ -z "$languages" ]; then
        local detected=$(inspect_repository)
        languages=$(echo "$detected" | tr ' ' '\n' | head -1)
        if [ -z "$languages" ]; then
            warn "No languages detected for CodeQL, skipping"
            return
        fi
    fi
    
    for lang in $languages; do
        log "  Analyzing $lang..."
        local output_file="$RESULTS_DIR/codeql-${lang}-${SCAN_ID}.sarif"
        
        # Determine build mode and commands
        case "$lang" in
            "java")
                if [ "$build_mode" = "manual" ] || [ "$build_mode" = "auto" ]; then
                    log "    Using Manual Build Mode for Java"
                    # Initialize CodeQL database
                    if ! codeql database create codeql-db-${lang} --language=$lang --source-root="$target" 2>&1; then
                        warn "    Failed to create CodeQL database for Java"
                        EXIT_CODE=1
                        continue
                    fi
                    
                    # Build with tracing (Maven example)
                    local build_success=false
                    if [ -f "$target/pom.xml" ]; then
                        if codeql database trace-command codeql-db-${lang} -- \
                            mvn -B -DskipTests clean compile -f "$target/pom.xml" 2>&1; then
                            build_success=true
                        fi
                    elif [ -f "$target/build.gradle" ]; then
                        if codeql database trace-command codeql-db-${lang} -- \
                            ./gradlew build -x test -p "$target" 2>&1; then
                            build_success=true
                        fi
                    else
                        # Generic Java build
                        if codeql database trace-command codeql-db-${lang} -- \
                            find "$target" -name "*.java" -exec javac {} \; 2>&1; then
                            build_success=true
                        fi
                    fi
                    
                    if [ "$build_success" = "false" ]; then
                        warn "    Java build failed, but continuing with database finalization"
                        EXIT_CODE=1
                    fi
                    
                    # Finalize database
                    if ! codeql database finalize codeql-db-${lang} 2>&1; then
                        warn "    Failed to finalize CodeQL database for Java"
                        EXIT_CODE=1
                        continue
                    fi
                    
                    # Run queries
                    if codeql database analyze codeql-db-${lang} \
                        --format=sarif-latest \
                        --output="$output_file" \
                        codeql/java-queries:codeql-suites/java-security-extended.qls \
                        security/codeql-queries 2>&1; then
                        log "    CodeQL analysis completed successfully"
                    else
                        warn "    CodeQL analysis encountered issues"
                        EXIT_CODE=1
                    fi
                    
                    if [ -f "$output_file" ]; then
                        log "    CodeQL results saved to $output_file"
                    fi
                fi
                ;;
            "cpp"|"c")
                if [ "$build_mode" = "manual" ] || [ "$build_mode" = "auto" ]; then
                    log "    Using Manual Build Mode for C/C++"
                    if ! codeql database create codeql-db-${lang} --language=cpp --source-root="$target" 2>&1; then
                        warn "    Failed to create CodeQL database for C/C++"
                        EXIT_CODE=1
                        continue
                    fi
                    
                    # Detect build system
                    local build_success=false
                    if [ -f "$target/CMakeLists.txt" ]; then
                        mkdir -p "$target/build"
                        if codeql database trace-command codeql-db-${lang} -- \
                            sh -c "cd $target/build && cmake .. && cmake --build ." 2>&1; then
                            build_success=true
                        fi
                    elif [ -f "$target/Makefile" ]; then
                        if codeql database trace-command codeql-db-${lang} -- \
                            make -C "$target" 2>&1; then
                            build_success=true
                        fi
                    elif [ -f "$target/configure" ]; then
                        if codeql database trace-command codeql-db-${lang} -- \
                            sh -c "cd $target && ./configure && make" 2>&1; then
                            build_success=true
                        fi
                    else
                        # Generic compilation
                        if codeql database trace-command codeql-db-${lang} -- \
                            find "$target" -name "*.c" -o -name "*.cpp" | xargs gcc -c 2>&1; then
                            build_success=true
                        fi
                    fi
                    
                    if [ "$build_success" = "false" ]; then
                        warn "    C/C++ build failed, but continuing with database finalization"
                        EXIT_CODE=1
                    fi
                    
                    if ! codeql database finalize codeql-db-${lang} 2>&1; then
                        warn "    Failed to finalize CodeQL database for C/C++"
                        EXIT_CODE=1
                        continue
                    fi
                    
                    if codeql database analyze codeql-db-${lang} \
                        --format=sarif-latest \
                        --output="$output_file" \
                        codeql/cpp-queries:codeql-suites/cpp-security-extended.qls 2>&1; then
                        log "    CodeQL analysis completed successfully"
                    else
                        warn "    CodeQL analysis encountered issues"
                        EXIT_CODE=1
                    fi
                    
                    if [ -f "$output_file" ]; then
                        log "    CodeQL results saved to $output_file"
                    fi
                fi
                ;;
            "go")
                if [ "$build_mode" = "manual" ] || [ "$build_mode" = "auto" ]; then
                    log "    Using Manual Build Mode for Go"
                    if ! codeql database create codeql-db-${lang} --language=go --source-root="$target" 2>&1; then
                        warn "    Failed to create CodeQL database for Go"
                        EXIT_CODE=1
                        continue
                    fi
                    
                    local build_success=false
                    if [ -f "$target/go.mod" ]; then
                        if codeql database trace-command codeql-db-${lang} -- \
                            sh -c "cd $target && go mod tidy && go build ./..." 2>&1; then
                            build_success=true
                        fi
                    else
                        if codeql database trace-command codeql-db-${lang} -- \
                            sh -c "cd $target && go build ./..." 2>&1; then
                            build_success=true
                        fi
                    fi
                    
                    if [ "$build_success" = "false" ]; then
                        warn "    Go build failed, but continuing with database finalization"
                        EXIT_CODE=1
                    fi
                    
                    if ! codeql database finalize codeql-db-${lang} 2>&1; then
                        warn "    Failed to finalize CodeQL database for Go"
                        EXIT_CODE=1
                        continue
                    fi
                    
                    if codeql database analyze codeql-db-${lang} \
                        --format=sarif-latest \
                        --output="$output_file" \
                        codeql/go-queries:codeql-suites/go-security-extended.qls 2>&1; then
                        log "    CodeQL analysis completed successfully"
                    else
                        warn "    CodeQL analysis encountered issues"
                        EXIT_CODE=1
                    fi
                    
                    if [ -f "$output_file" ]; then
                        log "    CodeQL results saved to $output_file"
                    fi
                fi
                ;;
            "csharp")
                if [ "$build_mode" = "manual" ] || [ "$build_mode" = "auto" ]; then
                    log "    Using Manual Build Mode for C#"
                    if ! codeql database create codeql-db-${lang} --language=csharp --source-root="$target" 2>&1; then
                        warn "    Failed to create CodeQL database for C#"
                        EXIT_CODE=1
                        continue
                    fi
                    
                    local build_success=false
                    if find "$target" -maxdepth 1 -name "*.sln" | head -1 | grep -q .; then
                        local sln_file=$(find "$target" -maxdepth 1 -name "*.sln" | head -1)
                        if codeql database trace-command codeql-db-${lang} -- \
                            dotnet build "$sln_file" 2>&1; then
                            build_success=true
                        fi
                    elif find "$target" -name "*.csproj" | head -1 | grep -q .; then
                        if codeql database trace-command codeql-db-${lang} -- \
                            dotnet build "$target" 2>&1; then
                            build_success=true
                        fi
                    else
                        if codeql database trace-command codeql-db-${lang} -- \
                            find "$target" -name "*.cs" -exec csc {} \; 2>&1; then
                            build_success=true
                        fi
                    fi
                    
                    if [ "$build_success" = "false" ]; then
                        warn "    C# build failed, but continuing with database finalization"
                        EXIT_CODE=1
                    fi
                    
                    if ! codeql database finalize codeql-db-${lang} 2>&1; then
                        warn "    Failed to finalize CodeQL database for C#"
                        EXIT_CODE=1
                        continue
                    fi
                    
                    if codeql database analyze codeql-db-${lang} \
                        --format=sarif-latest \
                        --output="$output_file" \
                        codeql/csharp-queries:codeql-suites/csharp-security-extended.qls 2>&1; then
                        log "    CodeQL analysis completed successfully"
                    else
                        warn "    CodeQL analysis encountered issues"
                        EXIT_CODE=1
                    fi
                    
                    if [ -f "$output_file" ]; then
                        log "    CodeQL results saved to $output_file"
                    fi
                fi
                ;;
            "javascript"|"python")
                log "    Using Build Mode: None for $lang (interpreted language)"
                # For interpreted languages, no build step needed
                if ! codeql database create codeql-db-${lang} --language=$lang --source-root="$target" 2>&1; then
                    warn "    Failed to create CodeQL database for $lang"
                    EXIT_CODE=1
                    continue
                fi
                
                if ! codeql database finalize codeql-db-${lang} 2>&1; then
                    warn "    Failed to finalize CodeQL database for $lang"
                    EXIT_CODE=1
                    continue
                fi
                
                local query_suite="codeql/${lang}-queries:codeql-suites/${lang}-security-extended.qls"
                if codeql database analyze codeql-db-${lang} \
                    --format=sarif-latest \
                    --output="$output_file" \
                    "$query_suite" 2>&1; then
                    log "    CodeQL analysis completed successfully"
                else
                    warn "    CodeQL analysis encountered issues"
                    EXIT_CODE=1
                fi
                
                if [ -f "$output_file" ]; then
                    log "    CodeQL results saved to $output_file"
                fi
                ;;
            *)
                warn "    Unsupported language for CodeQL: $lang"
                continue
                ;;
        esac
        
        log "    CodeQL results saved to $output_file"
    done
}

# Execute Gitleaks scan
run_gitleaks() {
    if ! check_docker; then
        warn "Docker not available, skipping Gitleaks"
        EXIT_CODE=1
        return 1
    fi
    
    local target=$(get_scan_target)
    local output_file="$RESULTS_DIR/gitleaks-${SCAN_ID}.json"
    local config_path=$(get_config ".scanners.gitleaks.config_path // \"security/gitleaks-rules/gitleaks.toml\"")
    local abs_pwd=$(pwd)
    
    log "Running Gitleaks secret detection on: $target"
    
    if docker run --rm \
        -v "$abs_pwd:/src" \
        -w /src \
        zricethezav/gitleaks:latest \
        detect \
        --source="$target" \
        --config="$config_path" \
        --report-format=json \
        --report-path="$output_file" \
        --verbose 2>&1; then
        log "Gitleaks scan completed successfully"
    else
        warn "Gitleaks scan encountered issues (secrets may have been found)"
        EXIT_CODE=1
    fi
    
    if [ -f "$output_file" ]; then
        log "Gitleaks results saved to $output_file"
    else
        warn "Gitleaks output file not created"
        EXIT_CODE=1
    fi
}

# Execute OSV-Scanner
run_osv_scanner() {
    if ! check_docker; then
        warn "Docker not available, skipping OSV-Scanner"
        EXIT_CODE=1
        return 1
    fi
    
    local target=$(get_scan_target)
    local output_file="$RESULTS_DIR/osv-scanner-${SCAN_ID}.json"
    local abs_pwd=$(pwd)
    
    log "Running OSV-Scanner dependency vulnerability scan on: $target"
    
    if docker run --rm \
        -v "$abs_pwd:/src" \
        -w /src \
        ghcr.io/google/osv-scanner:latest \
        /osv-scanner scan -r "$target" \
        --format json \
        --output "$output_file" 2>&1; then
        log "OSV-Scanner completed successfully"
    else
        warn "OSV-Scanner encountered issues"
        EXIT_CODE=1
    fi
    
    if [ -f "$output_file" ]; then
        log "OSV-Scanner results saved to $output_file"
    else
        warn "OSV-Scanner output file not created"
        EXIT_CODE=1
    fi
}

# Execute Trivy scan
run_trivy() {
    if ! check_docker; then
        warn "Docker not available, skipping Trivy"
        EXIT_CODE=1
        return 1
    fi
    
    local target=$(get_scan_target)
    local scan_type=$(get_config ".scanners.trivy.scan_type // \"fs\"")
    local output_file="$RESULTS_DIR/trivy-${SCAN_ID}.json"
    local abs_pwd=$(pwd)
    
    log "Running Trivy $scan_type scan on: $target"
    
    case "$scan_type" in
        "fs")
            if docker run --rm \
                -v "$abs_pwd:/src" \
                -w /src \
                aquasec/trivy:latest \
                fs "$target" \
                --scanners vuln,secret,config \
                --severity CRITICAL,HIGH,MEDIUM \
                --format json \
                --output "$output_file" \
                --no-progress 2>&1; then
                log "Trivy filesystem scan completed successfully"
            else
                warn "Trivy scan encountered issues"
                EXIT_CODE=1
            fi
            ;;
        "image")
            local image=$(get_config ".scanners.trivy.image")
            if docker run --rm \
                aquasec/trivy:latest \
                image "$image" \
                --scanners vuln,secret,config \
                --severity CRITICAL,HIGH,MEDIUM \
                --format json \
                --output "$output_file" \
                --no-progress 2>&1; then
                log "Trivy image scan completed successfully"
            else
                warn "Trivy scan encountered issues"
                EXIT_CODE=1
            fi
            ;;
        *)
            error "Unknown Trivy scan type: $scan_type"
            EXIT_CODE=1
            return 1
            ;;
    esac
    
    if [ -f "$output_file" ]; then
        log "Trivy results saved to $output_file"
    else
        warn "Trivy output file not created"
        EXIT_CODE=1
    fi
}

# Execute Syft SBOM generation
run_syft() {
    if ! check_docker; then
        warn "Docker not available, skipping Syft"
        EXIT_CODE=1
        return 1
    fi
    
    local target=$(get_scan_target)
    local output_file="$RESULTS_DIR/syft-${SCAN_ID}.json"
    local format=$(get_config ".scanners.syft.format // \"spdx-json\"")
    local abs_pwd=$(pwd)
    
    log "Running Syft SBOM generation on: $target"
    
    if docker run --rm \
        -v "$abs_pwd:/src" \
        -w /src \
        anchore/syft:latest \
        "$target" \
        -o "$format" \
        --file "$output_file" 2>&1; then
        log "Syft SBOM generation completed successfully"
    else
        warn "Syft SBOM generation encountered issues"
        EXIT_CODE=1
    fi
    
    if [ -f "$output_file" ]; then
        log "Syft SBOM saved to $output_file"
    else
        warn "Syft output file not created"
        EXIT_CODE=1
    fi
}

# Execute OWASP Noir
run_noir() {
    if ! check_docker; then
        warn "Docker not available, skipping OWASP Noir"
        EXIT_CODE=1
        return 1
    fi
    
    local target=$(get_scan_target)
    local output_file="$RESULTS_DIR/noir-${SCAN_ID}.json"
    local abs_pwd=$(pwd)
    
    log "Running OWASP Noir endpoint discovery on: $target"
    
    if docker run --rm \
        -v "$abs_pwd:/src" \
        -w /src \
        ghcr.io/owasp-noir/noir:v0.26.0 \
        -b "$target" \
        -f json > "$output_file" 2>&1; then
        log "OWASP Noir completed successfully"
    else
        warn "OWASP Noir encountered issues"
        EXIT_CODE=1
    fi
    
    if [ -f "$output_file" ]; then
        log "Noir results saved to $output_file"
    else
        warn "Noir output file not created"
        EXIT_CODE=1
    fi
}

# Main execution
main() {
    log "Starting security scan dispatcher (Scan ID: $SCAN_ID)"
    log "Configuration file: $CONFIG_FILE"
    
    # Validate config file
    if [ ! -f "$CONFIG_FILE" ]; then
        error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Create results directory
    mkdir -p "$RESULTS_DIR"
    
    # Auto-detect and enable scanners if not explicitly configured
    local auto_detect=$(get_config ".auto_detect // true")
    if [ "$auto_detect" = "true" ]; then
        log "Auto-detecting repository structure..."
        inspect_repository > /dev/null
    fi
    
    # Execute enabled scanners
    if is_scanner_enabled "semgrep" || [ "$auto_detect" = "true" ]; then
        run_semgrep || warn "Semgrep scan failed"
    fi
    
    if is_scanner_enabled "codeql" || [ "$auto_detect" = "true" ]; then
        run_codeql || warn "CodeQL scan failed"
    fi
    
    if is_scanner_enabled "gitleaks" || [ "$auto_detect" = "true" ]; then
        run_gitleaks || warn "Gitleaks scan failed"
    fi
    
    if is_scanner_enabled "osv_scanner" || [ "$auto_detect" = "true" ]; then
        run_osv_scanner || warn "OSV-Scanner failed"
    fi
    
    if is_scanner_enabled "trivy" || [ "$auto_detect" = "true" ]; then
        run_trivy || warn "Trivy scan failed"
    fi
    
    if is_scanner_enabled "syft" || [ "$auto_detect" = "true" ]; then
        run_syft || warn "Syft SBOM generation failed"
    fi
    
    if is_scanner_enabled "noir" || [ "$auto_detect" = "true" ]; then
        run_noir || warn "Noir scan failed"
    fi
    
    log "Security scan dispatcher completed"
    log "Results available in: $RESULTS_DIR"
    
    # List generated result files
    if [ -d "$RESULTS_DIR" ]; then
        local file_count=$(find "$RESULTS_DIR" -type f -name "*.json" -o -name "*.sarif" | wc -l)
        log "Generated $file_count result file(s)"
        find "$RESULTS_DIR" -type f \( -name "*.json" -o -name "*.sarif" \) -exec ls -lh {} \;
    fi
    
    # Exit with success if we have at least some results, even if some scanners failed
    if [ $EXIT_CODE -ne 0 ]; then
        warn "Some scanners encountered issues, but scan completed"
        # Don't exit with error if we have results
        if [ -d "$RESULTS_DIR" ] && [ "$(find "$RESULTS_DIR" -type f \( -name "*.json" -o -name "*.sarif" \) | wc -l)" -gt 0 ]; then
            log "Results were generated despite some failures"
            exit 0
        fi
    fi
    
    exit $EXIT_CODE
}

main "$@"
