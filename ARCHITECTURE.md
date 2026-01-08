# Platform Architecture

## System Overview

The Centralized Security Scanning Platform is designed with a **static CI pipeline** architecture where the GitHub Actions workflow never changes. Instead, a dynamic dispatcher script executes scanners based on user-provided JSON configuration.

## Component Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      User Interface                         │
│  ┌──────────────┐              ┌──────────────────────┐   │
│  │   Dashboard  │              │   REST API           │   │
│  │  (Web UI)    │◄─────────────┤  (Flask)             │   │
│  └──────────────┘              └──────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              GitHub Actions Workflow                        │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  security-scan-dispatcher.yml (STATIC - Never Changes)│ │
│  │  - Accepts JSON config via workflow_dispatch          │ │
│  │  - Sets up environment                                │ │
│  │  - Executes dispatcher script                         │ │
│  └──────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              Dispatcher Script (Dynamic)                     │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  dispatcher.sh                                        │ │
│  │  - Parses JSON configuration                          │ │
│  │  - Inspects repository structure                      │ │
│  │  - Auto-detects scanners                              │ │
│  │  - Executes enabled scanners                          │ │
│  │  - Handles selective scanning                         │ │
│  └──────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│   Semgrep    │   │   CodeQL     │   │  Gitleaks    │
│  (Container) │   │  (Manual     │   │  (Container) │
│              │   │   Build)     │   │              │
└──────────────┘   └──────────────┘   └──────────────┘
        │                   │                   │
        ▼                   ▼                   ▼
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ OSV-Scanner  │   │    Trivy     │   │     Syft     │
│  (Container) │   │  (Container) │   │  (Container) │
└──────────────┘   └──────────────┘   └──────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              Results Processing                              │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  generate-summary.sh                                  │ │
│  │  - Aggregates results                                 │ │
│  │  - Generates summary JSON                             │ │
│  └──────────────────────────────────────────────────────┘ │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  upload-results.sh                                    │ │
│  │  - Uploads to S3/MinIO                                │ │
│  │  - Stores in object storage                           │ │
│  └──────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              Object Storage (S3/MinIO)                       │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  /scans/{scan_id}/                                    │ │
│  │    - semgrep-{id}.json                                │ │
│  │    - codeql-{lang}-{id}.sarif                         │ │
│  │    - gitleaks-{id}.json                                │ │
│  │    - osv-scanner-{id}.json                             │ │
│  │    - trivy-{id}.json                                   │ │
│  │    - syft-{id}.json                                    │ │
│  │    - summary.json                                      │ │
│  └──────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Data Flow

### 1. Upload Phase
```
User → Dashboard → REST API → File System / Git Clone
```

### 2. Configuration Phase
```
Repository Inspection → Auto-detection → Config Generation
```

### 3. Execution Phase
```
GitHub Actions → Dispatcher Script → Scanner Containers → Results
```

### 4. Storage Phase
```
Results → Summary Generation → Object Storage → Dashboard
```

## Key Design Principles

### 1. Static CI Pipeline
- **Never changes**: The GitHub Actions workflow is static
- **Configuration-driven**: All customization via JSON config
- **Version controlled**: Workflow changes require code review

### 2. Dynamic Execution
- **Dispatcher script**: Handles all dynamic behavior
- **Scanner selection**: Based on repository inspection
- **Selective scanning**: Single-file, sparse, or full repo

### 3. Container-Based Scanners
- **Isolation**: Each scanner runs in its own container
- **Pre-built**: Scanner images are pre-built and cached
- **Consistent**: Same scanner version across all scans

### 4. Object Storage
- **Scalable**: S3-compatible storage for results
- **Non-relational**: No database dependencies
- **Retention**: Configurable retention policies

## Scanner Execution Model

### Compiled Languages (CodeQL Manual Build Mode)
```
1. Database Creation
2. Build Tracing (captures compilation)
3. Database Finalization
4. Query Execution
5. SARIF Generation
```

### Interpreted Languages (CodeQL Build Mode: None)
```
1. Database Creation
2. Database Finalization (no build)
3. Query Execution
4. SARIF Generation
```

### Container-Based Scanners
```
1. Mount source code
2. Execute scanner command
3. Capture JSON output
4. Store results
```

## Selective Scanning Strategies

### Single File Scanning
- **No checkout**: Direct file access
- **Fast**: Minimal resource usage
- **Limited**: Only file-level scanners

### Sparse Checkout
- **Selective**: Only fetch required paths
- **Efficient**: Reduced download time
- **Flexible**: Multiple directories

### Full Repository
- **Complete**: All files available
- **Comprehensive**: All scanners enabled
- **Resource-intensive**: Higher compute usage

## Security Considerations

1. **Isolation**: Scanners run in containers
2. **No CI Access**: Users don't modify CI files
3. **Temporary Storage**: Uploads cleaned after scan
4. **Result Storage**: Encrypted object storage
5. **Access Control**: API authentication (to be implemented)

## Scalability

1. **Horizontal Scaling**: Multiple API instances
2. **Queue System**: Async scan execution (future)
3. **Caching**: Scanner container images
4. **CDN**: Dashboard static assets
5. **Load Balancing**: Multiple dispatcher workers

## Extension Points

1. **New Scanners**: Add function to dispatcher.sh
2. **Custom Rules**: Add to security/ directory
3. **Storage Backends**: Extend upload-results.sh
4. **Notification**: Add webhook support
5. **Analytics**: Add metrics collection
