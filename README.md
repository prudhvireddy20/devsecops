# Centralized Security Scanning Platform

A comprehensive, CI-agnostic security scanning platform that allows users to scan source code, files, folders, or containers without directly interacting with CI/CD configuration files. The platform provides a simple dashboard interface while using a static GitHub Actions workflow that dynamically executes scanners based on user-provided JSON configuration.

## 🎯 Key Features

- **One-Click Scanning**: Upload Git repositories, ZIP files, or individual files through a web dashboard
- **Static CI Pipeline**: Pre-built scanner containers with a static GitHub Actions workflow that never changes
- **Dynamic Execution**: Dispatcher script executes appropriate scanners based on JSON configuration
- **Automated Scanner Selection**: Intelligent repository inspection to auto-detect and enable relevant scanners
- **Selective Scanning**: 
  - Single-file scanning (no full repository checkout)
  - Sparse checkout for specific folders
  - Full repository scanning when required
- **Comprehensive Scanners**:
  - **Semgrep**: SAST scanning with custom rules
  - **CodeQL**: Advanced SAST with Manual Build Mode for compiled languages
  - **Gitleaks**: Secret detection
  - **OSV-Scanner**: Dependency vulnerability scanning
  - **Trivy**: Container and filesystem scanning
  - **Syft**: SBOM generation
  - **OWASP Noir**: API endpoint discovery
- **Object Storage**: Results stored in S3-compatible storage (AWS S3, MinIO)
- **Structured Output**: Results in JSON, SARIF, and SBOM formats

## 🏗️ Architecture

```
┌─────────────────┐
│   Dashboard     │  (Web UI for uploads & results)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   REST API      │  (Flask API for scan management)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  GitHub Actions │  (Static workflow - never changes)
│   Dispatcher    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Dispatcher     │  (Bash script - dynamic execution)
│     Script      │
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
┌────────┐ ┌────────┐
│Scanner │ │Scanner │  (Pre-built containers)
│   A    │ │   B    │
└────────┘ └────────┘
```

## 📋 Prerequisites

- Docker and Docker Compose
- Python 3.11+ (for local API development)
- GitHub Actions (for CI execution)
- jq (for JSON parsing in scripts)

## 🚀 Quick Start

### Local Development

1. **Start the platform**:
   ```bash
   docker-compose up -d
   ```

2. **Access the dashboard**:
   - Open http://localhost:8080 in your browser

3. **API endpoint**:
   - API available at http://localhost:5000

4. **MinIO console** (for object storage):
   - Access at http://localhost:9001
   - Credentials: `minioadmin` / `minioadmin`

### Using GitHub Actions

1. **Configure the workflow**:
   The static workflow is located at `.github/workflows/security-scan-dispatcher.yml`

2. **Trigger a scan**:
   ```bash
   gh workflow run security-scan-dispatcher.yml \
     -f scan_config='{"target":{"type":"repository","path":"."},"scanners":{"semgrep":{"enabled":true}}}'
   ```

## 📝 Configuration

### Scan Configuration JSON

Example configurations are available in `platform/config/`:

- **Full Repository Scan**: `scan-config-example.json`
- **Single File Scan**: `single-file-config-example.json`
- **Sparse Checkout**: `sparse-checkout-config-example.json`

#### Configuration Structure

```json
{
  "target": {
    "type": "repository|file|directory",
    "path": ".",
    "url": "https://github.com/user/repo.git",
    "branch": "main"
  },
  "scan_scope": {
    "type": "full|single_file|sparse",
    "paths": [],
    "single_file": null
  },
  "auto_detect": true,
  "scanners": {
    "semgrep": {
      "enabled": true,
      "config_path": "security/semgrep-rules"
    },
    "codeql": {
      "enabled": true,
      "languages": ["auto"],
      "build_mode": "auto"
    },
    "gitleaks": {
      "enabled": true,
      "config_path": "security/gitleaks-rules/gitleaks.toml"
    },
    "osv_scanner": {
      "enabled": true
    },
    "trivy": {
      "enabled": true,
      "scan_type": "fs|image",
      "image": null
    },
    "syft": {
      "enabled": true,
      "format": "spdx-json"
    },
    "noir": {
      "enabled": false
    }
  },
  "output": {
    "formats": ["json", "sarif"],
    "storage": "s3|local",
    "retention_days": 30
  }
}
```

## 🔧 CodeQL Build Modes

The platform supports different CodeQL build modes based on language type:

### Manual Build Mode (Compiled Languages)

For compiled languages (Java, C/C++, Go, C#), CodeQL uses **Manual Build Mode** which requires:

1. **Database Creation**: `codeql database create`
2. **Build Tracing**: `codeql database trace-command` to capture build commands
3. **Database Finalization**: `codeql database finalize`
4. **Analysis**: `codeql database analyze`

#### Java Example
```bash
# Create database
codeql database create codeql-db-java --language=java --source-root=.

# Trace Maven build
codeql database trace-command codeql-db-java -- \
  mvn -B -DskipTests clean compile

# Finalize and analyze
codeql database finalize codeql-db-java
codeql database analyze codeql-db-java \
  --format=sarif-latest \
  --output=results.sarif \
  codeql/java-queries:codeql-suites/java-security-extended.qls
```

#### C/C++ Example
```bash
codeql database create codeql-db-cpp --language=cpp --source-root=.
codeql database trace-command codeql-db-cpp -- \
  sh -c "mkdir build && cd build && cmake .. && cmake --build ."
codeql database finalize codeql-db-cpp
codeql database analyze codeql-db-cpp \
  --format=sarif-latest \
  --output=results.sarif \
  codeql/cpp-queries:codeql-suites/cpp-security-extended.qls
```

### Build Mode: None (Interpreted Languages)

For interpreted languages (JavaScript, Python), CodeQL uses **Build Mode: None**:

```bash
# No build step required
codeql database create codeql-db-js --language=javascript --source-root=.
codeql database finalize codeql-db-js
codeql database analyze codeql-db-js \
  --format=sarif-latest \
  --output=results.sarif \
  codeql/javascript-queries:codeql-suites/javascript-security-extended.qls
```

## 📊 API Endpoints

### Upload & Execute Scan

```bash
# Upload file/ZIP/repository
POST /api/v1/scan/upload
Content-Type: multipart/form-data

# Execute scan
POST /api/v1/scan/{scan_id}/execute
```

### Retrieve Results

```bash
# Get scan results list
GET /api/v1/scan/{scan_id}/results

# Download specific result file
GET /api/v1/scan/{scan_id}/results/{filename}

# Get scan summary
GET /api/v1/scan/{scan_id}/summary

# List all scans
GET /api/v1/scans
```

## 🔍 Scanner Details

### Semgrep
- **Type**: SAST
- **Languages**: 30+ languages
- **Config**: Custom rules in `security/semgrep-rules/`
- **Output**: JSON

### CodeQL
- **Type**: SAST
- **Languages**: Java, C/C++, Go, JavaScript, Python, C#
- **Build Mode**: Auto-detected (Manual for compiled, None for interpreted)
- **Output**: SARIF

### Gitleaks
- **Type**: Secret Detection
- **Config**: Custom rules in `security/gitleaks-rules/`
- **Output**: JSON

### OSV-Scanner
- **Type**: Dependency Vulnerability
- **Supports**: npm, pip, maven, gradle, go, cargo, composer, etc.
- **Output**: JSON

### Trivy
- **Type**: Container/Filesystem Scanning
- **Scans**: Vulnerabilities, secrets, misconfigurations
- **Output**: JSON

### Syft
- **Type**: SBOM Generation
- **Formats**: SPDX, CycloneDX
- **Output**: JSON

### OWASP Noir
- **Type**: API Endpoint Discovery
- **Output**: JSON

## 🗄️ Object Storage

Results are stored in S3-compatible storage. Configure via environment variables:

```bash
STORAGE_TYPE=s3
AWS_ACCESS_KEY_ID=your_key
AWS_SECRET_ACCESS_KEY=your_secret
AWS_REGION=us-east-1
S3_ENDPOINT=https://s3.amazonaws.com  # Optional for MinIO
BUCKET_NAME=security-scan-results
```

For local development, use:
```bash
STORAGE_TYPE=local
LOCAL_STORAGE_PATH=/tmp/scan-storage
```

## 🔐 Security Considerations

- All scanner containers are run in isolated environments
- No direct access to CI/CD configuration files
- Results stored in object storage (not relational DB)
- API supports CORS for dashboard integration
- Uploaded files are stored temporarily and cleaned up

## 📈 Performance Optimization

- **Single-file scanning**: No repository checkout required
- **Sparse checkout**: Only fetch required directories
- **Parallel execution**: Multiple scanners can run concurrently
- **Selective scanning**: Only run enabled scanners
- **Caching**: Scanner containers are pre-built and cached

## 🛠️ Development

### Running API Locally

```bash
cd platform/api
pip install -r requirements.txt
python app.py
```

### Testing Dispatcher Script

```bash
cd platform/dispatcher
./dispatcher.sh ../config/scan-config-example.json
```

### Adding New Scanners

1. Add scanner function to `platform/dispatcher/dispatcher.sh`
2. Update configuration schema in example configs
3. Add scanner option to dashboard UI
4. Update API to handle new scanner

## 📚 Documentation

- **Configuration Examples**: `platform/config/`
- **Security Rules**: `security/`
- **Workflow**: `.github/workflows/security-scan-dispatcher.yml`
- **Dispatcher Script**: `platform/dispatcher/dispatcher.sh`


