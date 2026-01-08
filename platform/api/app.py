#!/usr/bin/env python3
"""
Centralized Security Scanning Platform - REST API
Handles uploads, scan management, and results retrieval
"""

from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
import os
import json
import uuid
import subprocess
import tempfile
import shutil
from datetime import datetime
from pathlib import Path
import zipfile
import git
from werkzeug.utils import secure_filename

app = Flask(__name__)
CORS(app)

# Configuration
UPLOAD_DIR = os.getenv("UPLOAD_DIR", "/tmp/scan-uploads")
RESULTS_DIR = os.getenv("RESULTS_DIR", "/tmp/scanner-results")
STORAGE_DIR = os.getenv("STORAGE_DIR", "/tmp/scan-storage")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "")
ALLOWED_EXTENSIONS = {'zip', 'json', 'txt', 'py', 'js', 'java', 'cpp', 'c', 'go', 'cs', 'ts', 'tsx', 'jsx'}

# Ensure directories exist
for directory in [UPLOAD_DIR, RESULTS_DIR, STORAGE_DIR]:
    os.makedirs(directory, exist_ok=True)

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

def clone_repository(repo_url, branch="main", target_dir=None):
    """Clone a Git repository"""
    if target_dir is None:
        target_dir = tempfile.mkdtemp(prefix="repo_", dir=UPLOAD_DIR)
    
    try:
        repo = git.Repo.clone_from(repo_url, target_dir, branch=branch, depth=1)
        return target_dir
    except Exception as e:
        raise Exception(f"Failed to clone repository: {str(e)}")

def extract_zip(zip_path, extract_to):
    """Extract ZIP file"""
    try:
        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            zip_ref.extractall(extract_to)
        return extract_to
    except Exception as e:
        raise Exception(f"Failed to extract ZIP: {str(e)}")

def inspect_repository(repo_path):
    """Inspect repository to auto-detect scanners"""
    detected = {
        "languages": [],
        "has_dockerfile": False,
        "has_dependencies": False,
        "dependency_files": []
    }
    
    repo_path = Path(repo_path)
    
    # Check for Dockerfile
    if (repo_path / "Dockerfile").exists() or (repo_path / "docker-compose.yml").exists():
        detected["has_dockerfile"] = True
    
    # Check for dependency files
    dep_patterns = [
        "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
        "requirements.txt", "Pipfile.lock", "poetry.lock",
        "pom.xml", "build.gradle", "gradle.lockfile",
        "go.mod", "go.sum",
        "Cargo.toml", "Cargo.lock",
        "Gemfile", "Gemfile.lock",
        "composer.lock"
    ]
    
    for pattern in dep_patterns:
        for file in repo_path.rglob(pattern):
            detected["dependency_files"].append(str(file.relative_to(repo_path)))
            detected["has_dependencies"] = True
            break
    
    # Detect languages
    lang_extensions = {
        "java": [".java"],
        "cpp": [".cpp", ".c", ".h", ".hpp"],
        "go": [".go"],
        "javascript": [".js", ".jsx", ".ts", ".tsx"],
        "python": [".py"],
        "csharp": [".cs"]
    }
    
    for lang, exts in lang_extensions.items():
        for ext in exts:
            if list(repo_path.rglob(f"*{ext}")):
                detected["languages"].append(lang)
                break
    
    return detected

def generate_scan_config(upload_type, target_path, inspection=None, custom_config=None):
    """Generate scan configuration"""
    if custom_config:
        return custom_config
    
    config = {
        "target": {
            "type": upload_type,
            "path": target_path
        },
        "scan_scope": {
            "type": "full" if upload_type == "repository" else "single_file",
            "paths": [target_path],
            "single_file": target_path if upload_type == "file" else None
        },
        "auto_detect": True,
        "scanners": {
            "semgrep": {"enabled": True, "config_path": "security/semgrep-rules"},
            "codeql": {"enabled": True, "languages": ["auto"], "build_mode": "auto"},
            "gitleaks": {"enabled": True, "config_path": "security/gitleaks-rules/gitleaks.toml"},
            "osv_scanner": {"enabled": inspection["has_dependencies"] if inspection else True},
            "trivy": {"enabled": inspection["has_dockerfile"] if inspection else True, "scan_type": "fs"},
            "syft": {"enabled": False, "format": "spdx-json"},
            "noir": {"enabled": False}
        },
        "output": {
            "formats": ["json", "sarif"],
            "storage": "local",
            "retention_days": 30
        }
    }
    
    return config

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({"status": "healthy", "timestamp": datetime.utcnow().isoformat()})

@app.route('/api/v1/scan/upload', methods=['POST'])
def upload_scan():
    """Upload file, ZIP, or repository URL for scanning"""
    try:
        scan_id = str(uuid.uuid4())
        upload_type = request.form.get('type', 'file')  # file, zip, repository
        
        if upload_type == 'repository':
            repo_url = request.form.get('repository_url')
            branch = request.form.get('branch', 'main')
            if not repo_url:
                return jsonify({"error": "repository_url is required"}), 400
            
            # Clone repository
            target_dir = os.path.join(UPLOAD_DIR, scan_id)
            clone_repository(repo_url, branch, target_dir)
            target_path = target_dir
            
        elif upload_type == 'zip':
            if 'file' not in request.files:
                return jsonify({"error": "No file provided"}), 400
            
            file = request.files['file']
            if file.filename == '':
                return jsonify({"error": "No file selected"}), 400
            
            # Save and extract ZIP
            zip_path = os.path.join(UPLOAD_DIR, f"{scan_id}.zip")
            file.save(zip_path)
            target_dir = os.path.join(UPLOAD_DIR, scan_id)
            os.makedirs(target_dir, exist_ok=True)
            extract_zip(zip_path, target_dir)
            target_path = target_dir
            
        else:  # single file
            if 'file' not in request.files:
                return jsonify({"error": "No file provided"}), 400
            
            file = request.files['file']
            if not allowed_file(file.filename):
                return jsonify({"error": "File type not allowed"}), 400
            
            # Save file
            target_dir = os.path.join(UPLOAD_DIR, scan_id)
            os.makedirs(target_dir, exist_ok=True)
            filename = secure_filename(file.filename)
            target_path = os.path.join(target_dir, filename)
            file.save(target_path)
        
        # Inspect repository if applicable
        inspection = None
        if upload_type in ['repository', 'zip']:
            inspection = inspect_repository(target_path)
        
        # Get custom config if provided
        custom_config = None
        if 'config' in request.form:
            try:
                custom_config = json.loads(request.form['config'])
            except json.JSONDecodeError:
                return jsonify({"error": "Invalid JSON config"}), 400
        
        # Generate scan configuration
        config = generate_scan_config(upload_type, target_path, inspection, custom_config)
        config_path = os.path.join(target_dir, "scan-config.json")
        with open(config_path, 'w') as f:
            json.dump(config, f, indent=2)
        
        return jsonify({
            "scan_id": scan_id,
            "status": "uploaded",
            "target_path": target_path,
            "config": config,
            "inspection": inspection
        }), 201
        
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/v1/scan/<scan_id>/execute', methods=['POST'])
def execute_scan(scan_id):
    """Execute scan for uploaded content"""
    try:
        scan_dir = os.path.join(UPLOAD_DIR, scan_id)
        config_path = os.path.join(scan_dir, "scan-config.json")
        
        if not os.path.exists(config_path):
            return jsonify({"error": "Scan not found or not configured"}), 404
        
        # Read config
        with open(config_path, 'r') as f:
            config = json.load(f)
        
        # Set up environment
        os.environ['RESULTS_DIR'] = os.path.join(RESULTS_DIR, scan_id)
        os.environ['SCAN_ID'] = scan_id
        os.makedirs(os.environ['RESULTS_DIR'], exist_ok=True)
        
        # Execute dispatcher - resolve path correctly
        # Try multiple possible paths for the dispatcher script
        script_dir = os.path.dirname(os.path.abspath(__file__))
        possible_paths = [
            os.path.join(script_dir, '..', 'dispatcher', 'dispatcher.sh'),
            os.path.join(script_dir, '..', '..', 'platform', 'dispatcher', 'dispatcher.sh'),
            os.path.join('/app', '..', 'dispatcher', 'dispatcher.sh'),
            os.path.join(os.path.dirname(script_dir), 'dispatcher', 'dispatcher.sh'),
            'platform/dispatcher/dispatcher.sh',  # Relative from workspace root
        ]
        
        dispatcher_script = None
        for path in possible_paths:
            abs_path = os.path.abspath(path)
            if os.path.exists(abs_path):
                dispatcher_script = abs_path
                break
        
        if not dispatcher_script or not os.path.exists(dispatcher_script):
            return jsonify({
                "error": f"Dispatcher script not found. Tried: {possible_paths}",
                "current_dir": os.getcwd(),
                "script_dir": script_dir,
                "file_dir": os.path.dirname(__file__)
            }), 500
        
        # Ensure script is executable (ignore errors on read-only filesystems)
        try:
            os.chmod(dispatcher_script, 0o755)
        except PermissionError:
            # Read-only volume or insufficient permissions: assume script is already executable
            pass
        except OSError as e:
            # If filesystem is read-only (Errno 30) or other OS errors, continue without failing
            if getattr(e, "errno", None) not in (30,):
                # Log or include warning in response context if needed in future
                pass
        
        result = subprocess.run(
            ['bash', dispatcher_script, config_path],
            cwd=scan_dir,
            capture_output=True,
            text=True,
            timeout=3600,  # 1 hour timeout
            env={**os.environ, 'RESULTS_DIR': os.environ['RESULTS_DIR'], 'SCAN_ID': scan_id}
        )
        
        # Generate summary - resolve path correctly
        script_dir = os.path.dirname(os.path.abspath(__file__))
        possible_summary_paths = [
            os.path.join(script_dir, '..', 'dispatcher', 'generate-summary.sh'),
            os.path.join(script_dir, '..', '..', 'platform', 'dispatcher', 'generate-summary.sh'),
            os.path.join(os.path.dirname(script_dir), 'dispatcher', 'generate-summary.sh'),
            'platform/dispatcher/generate-summary.sh',
        ]
        
        summary_script = None
        for path in possible_summary_paths:
            abs_path = os.path.abspath(path)
            if os.path.exists(abs_path):
                summary_script = abs_path
                break
        
        summary_path = os.path.join(os.environ['RESULTS_DIR'], 'summary.json')
        if summary_script and os.path.exists(summary_script):
            os.chmod(summary_script, 0o755)
            subprocess.run(
                ['bash', summary_script, os.environ['RESULTS_DIR'], summary_path],
                capture_output=True,
                env={**os.environ, 'SCAN_ID': scan_id}
            )
        else:
            # Generate basic summary if script not found
            summary = {
                "metadata": {
                    "timestamp": datetime.utcnow().isoformat(),
                    "scan_id": scan_id,
                    "status": status
                }
            }
            # Count result files
            if os.path.exists(os.environ['RESULTS_DIR']):
                result_files = [f for f in os.listdir(os.environ['RESULTS_DIR']) 
                              if f.endswith(('.json', '.sarif'))]
                for result_file in result_files:
                    scanner_name = result_file.split('-')[0] if '-' in result_file else "unknown"
                    file_path = os.path.join(os.environ['RESULTS_DIR'], result_file)
                    file_size = os.path.getsize(file_path) if os.path.exists(file_path) else 0
                    summary[scanner_name] = {
                        "file": result_file,
                        "findings": 0,  # Would need to parse to get actual count
                        "size_bytes": file_size
                    }
            
            with open(summary_path, 'w') as f:
                json.dump(summary, f, indent=2)
        
        # Read summary
        summary = {}
        if os.path.exists(summary_path):
            with open(summary_path, 'r') as f:
                summary = json.load(f)
        
        # Check if results were generated (success even if exit code is non-zero)
        results_exist = os.path.exists(os.environ['RESULTS_DIR']) and \
                       len([f for f in os.listdir(os.environ['RESULTS_DIR']) 
                           if f.endswith(('.json', '.sarif'))]) > 0
        
        status = "completed" if (result.returncode == 0 or results_exist) else "failed"
        
        return jsonify({
            "scan_id": scan_id,
            "status": status,
            "exit_code": result.returncode,
            "results_generated": results_exist,
            "summary": summary,
            "stdout": result.stdout[-5000:] if result.stdout else "",  # Limit stdout size
            "stderr": result.stderr[-5000:] if result.stderr else ""   # Limit stderr size
        }), 200
        
    except subprocess.TimeoutExpired:
        return jsonify({"error": "Scan timeout"}), 504
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/v1/scan/<scan_id>/results', methods=['GET'])
def get_results(scan_id):
    """Get scan results"""
    try:
        results_dir = os.path.join(RESULTS_DIR, scan_id)
        
        if not os.path.exists(results_dir):
            return jsonify({"error": "Results not found"}), 404
        
        # List all result files
        results = {}
        for file in os.listdir(results_dir):
            file_path = os.path.join(results_dir, file)
            if os.path.isfile(file_path):
                file_size = os.path.getsize(file_path)
                results[file] = {
                    "size": file_size,
                    "url": f"/api/v1/scan/{scan_id}/results/{file}"
                }
        
        return jsonify({
            "scan_id": scan_id,
            "results": results
        }), 200
        
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/v1/scan/<scan_id>/results/<filename>', methods=['GET'])
def download_result(scan_id, filename):
    """Download specific result file"""
    try:
        file_path = os.path.join(RESULTS_DIR, scan_id, filename)
        
        if not os.path.exists(file_path):
            return jsonify({"error": "File not found"}), 404
        
        return send_file(file_path, as_attachment=True)
        
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/v1/scan/<scan_id>/summary', methods=['GET'])
def get_summary(scan_id):
    """Get scan summary"""
    try:
        summary_path = os.path.join(RESULTS_DIR, scan_id, 'summary.json')
        
        if not os.path.exists(summary_path):
            return jsonify({"error": "Summary not found"}), 404
        
        with open(summary_path, 'r') as f:
            summary = json.load(f)
        
        return jsonify(summary), 200
        
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/v1/scans', methods=['GET'])
def list_scans():
    """List all scans with detailed information"""
    try:
        scans = []
        
        # Check if RESULTS_DIR exists
        if not os.path.exists(RESULTS_DIR):
            return jsonify({"scans": []}), 200
        
        for scan_id in os.listdir(RESULTS_DIR):
            scan_dir = os.path.join(RESULTS_DIR, scan_id)
            if not os.path.isdir(scan_dir):
                continue
                
            # Read summary if exists
            summary_path = os.path.join(scan_dir, 'summary.json')
            summary = {}
            if os.path.exists(summary_path):
                try:
                    with open(summary_path, 'r') as f:
                        summary = json.load(f)
                except Exception as e:
                    summary = {"error": f"Failed to parse summary: {str(e)}"}
            
            # Get result files
            result_files = {}
            if os.path.exists(scan_dir):
                for file in os.listdir(scan_dir):
                    file_path = os.path.join(scan_dir, file)
                    if os.path.isfile(file_path) and file.endswith(('.json', '.sarif')):
                        file_size = os.path.getsize(file_path)
                        result_files[file] = {
                            "size": file_size,
                            "url": f"/api/v1/scan/{scan_id}/results/{file}"
                        }
            
            # Get scan metadata
            scan_info = {
                "scan_id": scan_id,
                "summary": summary,
                "result_files": result_files,
                "result_count": len(result_files),
                "has_summary": os.path.exists(summary_path)
            }
            
            # Add metadata from summary if available
            if "metadata" in summary:
                scan_info["metadata"] = summary["metadata"]
            
            scans.append(scan_info)
        
        # Sort by scan_id (most recent first if using timestamps)
        scans.sort(key=lambda x: x.get("scan_id", ""), reverse=True)
        
        return jsonify({"scans": scans}), 200
        
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
