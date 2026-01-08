# Quick Start Guide

## 🚀 Getting Started in 5 Minutes

### Option 1: Docker Compose (Recommended)

1. **Start all services**:
   ```bash
   docker-compose up -d
   ```

2. **Access the dashboard**:
   - Open http://localhost:8080

3. **Upload and scan**:
   - Select upload type (File, ZIP, or Repository)
   - Choose scanners
   - Click "Start Security Scan"

4. **View results**:
   - Navigate to "Scan History" tab
   - Click "View Details" on any scan

### Option 2: Local Development

1. **Start the API**:
   ```bash
   cd platform/api
   pip install -r requirements.txt
   python app.py
   ```

2. **Open dashboard**:
   - Open `platform/dashboard/index.html` in your browser
   - Update API_BASE in the script to point to your API

3. **Run a scan**:
   - Use the dashboard or make API calls directly

### Option 3: GitHub Actions

1. **Trigger workflow manually**:
   ```bash
   gh workflow run security-scan-dispatcher.yml \
     -f scan_config='{
       "target": {"type": "repository", "path": "."},
       "scanners": {
         "semgrep": {"enabled": true},
         "gitleaks": {"enabled": true}
       }
     }'
   ```

2. **Or use repository dispatch**:
   ```bash
   gh api repos/:owner/:repo/dispatches \
     -f event_type=security-scan-request \
     -f client_payload='{"scan_config": {...}}'
   ```

## 📝 Example API Calls

### Upload a File

```bash
curl -X POST http://localhost:5000/api/v1/scan/upload \
  -F "type=file" \
  -F "file=@example.py"
```

### Upload a Repository

```bash
curl -X POST http://localhost:5000/api/v1/scan/upload \
  -F "type=repository" \
  -F "repository_url=https://github.com/user/repo.git" \
  -F "branch=main"
```

### Execute Scan

```bash
curl -X POST http://localhost:5000/api/v1/scan/{scan_id}/execute
```

### Get Results

```bash
curl http://localhost:5000/api/v1/scan/{scan_id}/results
```

## 🔧 Configuration Examples

### Full Repository Scan

```json
{
  "target": {
    "type": "repository",
    "path": "."
  },
  "auto_detect": true,
  "scanners": {
    "semgrep": {"enabled": true},
    "codeql": {"enabled": true, "languages": ["auto"]},
    "gitleaks": {"enabled": true},
    "osv_scanner": {"enabled": true},
    "trivy": {"enabled": true}
  }
}
```

### Single File Scan

```json
{
  "target": {
    "type": "file",
    "path": "src/main.py"
  },
  "scan_scope": {
    "type": "single_file",
    "single_file": "src/main.py"
  },
  "scanners": {
    "semgrep": {"enabled": true},
    "gitleaks": {"enabled": true},
    "codeql": {"enabled": false}
  }
}
```

## 🐛 Troubleshooting

### API not starting
- Check if port 5000 is available
- Verify Python dependencies: `pip install -r platform/api/requirements.txt`

### Scanners not running
- Ensure Docker is running
- Check scanner container images are available
- Review dispatcher script logs

### Results not appearing
- Check `/tmp/scanner-results/` directory
- Verify object storage configuration
- Review API logs for errors

## 📚 Next Steps

- Read the full [README.md](README.md)
- Review [CodeQL Build Modes](docs/CODEQL_BUILD_MODES.md)
- Explore configuration examples in `platform/config/`
- Customize security rules in `security/`
