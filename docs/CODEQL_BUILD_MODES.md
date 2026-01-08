# CodeQL Build Modes Documentation

This document explains the difference between Manual Build Mode (for compiled languages) and Build Mode: None (for interpreted languages) in CodeQL scanning.

## Overview

CodeQL requires different approaches based on the language type:

- **Compiled Languages** (Java, C/C++, Go, C#): Require **Manual Build Mode** with build command tracing
- **Interpreted Languages** (JavaScript, Python): Use **Build Mode: None** (no build step)

## Manual Build Mode (Compiled Languages)

### Why Manual Build Mode?

Compiled languages require a build step to generate executable code. CodeQL needs to trace the compilation process to understand:
- Source file dependencies
- Build system configuration
- Compiler flags and options
- Generated artifacts

### Process Flow

1. **Database Creation**: Initialize CodeQL database with language and source root
2. **Build Tracing**: Execute build commands with CodeQL tracing enabled
3. **Database Finalization**: Complete database construction
4. **Analysis**: Run security queries against the database

### Language-Specific Examples

#### Java (Maven)

```bash
# Step 1: Create database
codeql database create codeql-db-java \
  --language=java \
  --source-root=.

# Step 2: Trace Maven build
codeql database trace-command codeql-db-java -- \
  mvn -B -DskipTests clean compile

# Step 3: Finalize database
codeql database finalize codeql-db-java

# Step 4: Analyze
codeql database analyze codeql-db-java \
  --format=sarif-latest \
  --output=results.sarif \
  codeql/java-queries:codeql-suites/java-security-extended.qls \
  security/codeql-queries
```

**SDK Requirements**:
- Java JDK (8+)
- Maven or Gradle
- CodeQL Java extractor

#### Java (Gradle)

```bash
codeql database create codeql-db-java --language=java --source-root=.
codeql database trace-command codeql-db-java -- \
  ./gradlew build -x test
codeql database finalize codeql-db-java
codeql database analyze codeql-db-java \
  --format=sarif-latest \
  --output=results.sarif \
  codeql/java-queries:codeql-suites/java-security-extended.qls
```

#### C/C++ (CMake)

```bash
# Step 1: Create database
codeql database create codeql-db-cpp \
  --language=cpp \
  --source-root=.

# Step 2: Trace CMake build
codeql database trace-command codeql-db-cpp -- \
  sh -c "mkdir -p build && cd build && cmake .. && cmake --build ."

# Step 3: Finalize
codeql database finalize codeql-db-cpp

# Step 4: Analyze
codeql database analyze codeql-db-cpp \
  --format=sarif-latest \
  --output=results.sarif \
  codeql/cpp-queries:codeql-suites/cpp-security-extended.qls
```

**SDK Requirements**:
- C/C++ compiler (gcc, clang, MSVC)
- CMake or Make
- CodeQL C/C++ extractor

#### C/C++ (Make)

```bash
codeql database create codeql-db-cpp --language=cpp --source-root=.
codeql database trace-command codeql-db-cpp -- \
  make -C .
codeql database finalize codeql-db-cpp
codeql database analyze codeql-db-cpp \
  --format=sarif-latest \
  --output=results.sarif \
  codeql/cpp-queries:codeql-suites/cpp-security-extended.qls
```

#### Go

```bash
# Step 1: Create database
codeql database create codeql-db-go \
  --language=go \
  --source-root=.

# Step 2: Trace Go build
codeql database trace-command codeql-db-go -- \
  sh -c "go mod tidy && go build ./..."

# Step 3: Finalize
codeql database finalize codeql-db-go

# Step 4: Analyze
codeql database analyze codeql-db-go \
  --format=sarif-latest \
  --output=results.sarif \
  codeql/go-queries:codeql-suites/go-security-extended.qls
```

**SDK Requirements**:
- Go SDK (1.16+)
- CodeQL Go extractor

#### C# (.NET)

```bash
# Step 1: Create database
codeql database create codeql-db-csharp \
  --language=csharp \
  --source-root=.

# Step 2: Trace .NET build
codeql database trace-command codeql-db-csharp -- \
  dotnet build *.sln

# Step 3: Finalize
codeql database finalize codeql-db-csharp

# Step 4: Analyze
codeql database analyze codeql-db-csharp \
  --format=sarif-latest \
  --output=results.sarif \
  codeql/csharp-queries:codeql-suites/csharp-security-extended.qls
```

**SDK Requirements**:
- .NET SDK (5.0+)
- CodeQL C# extractor

## Build Mode: None (Interpreted Languages)

### Why Build Mode: None?

Interpreted languages don't require compilation. CodeQL can analyze source code directly without tracing build commands.

### Process Flow

1. **Database Creation**: Initialize CodeQL database
2. **Database Finalization**: Complete database (no build step)
3. **Analysis**: Run security queries

### Language-Specific Examples

#### JavaScript/TypeScript

```bash
# Step 1: Create database (no build needed)
codeql database create codeql-db-js \
  --language=javascript \
  --source-root=.

# Step 2: Finalize (no build tracing)
codeql database finalize codeql-db-js

# Step 3: Analyze
codeql database analyze codeql-db-js \
  --format=sarif-latest \
  --output=results.sarif \
  codeql/javascript-queries:codeql-suites/javascript-security-extended.qls
```

**Requirements**:
- Node.js (for dependency resolution, optional)
- CodeQL JavaScript extractor

#### Python

```bash
# Step 1: Create database
codeql database create codeql-db-python \
  --language=python \
  --source-root=.

# Step 2: Finalize
codeql database finalize codeql-db-python

# Step 3: Analyze
codeql database analyze codeql-db-python \
  --format=sarif-latest \
  --output=results.sarif \
  codeql/python-queries:codeql-suites/python-security-extended.qls
```

**Requirements**:
- Python 3.x
- CodeQL Python extractor

## Comparison Table

| Aspect | Manual Build Mode | Build Mode: None |
|--------|------------------|------------------|
| **Languages** | Java, C/C++, Go, C# | JavaScript, Python |
| **Build Step** | Required (traced) | Not required |
| **Database Creation** | `codeql database create` | `codeql database create` |
| **Build Tracing** | `codeql database trace-command` | N/A |
| **Finalization** | `codeql database finalize` | `codeql database finalize` |
| **Analysis** | `codeql database analyze` | `codeql database analyze` |
| **SDK Required** | Language-specific build tools | Language runtime only |
| **Complexity** | Higher (requires build setup) | Lower (direct analysis) |

## Implementation in Dispatcher

The dispatcher script (`platform/dispatcher/dispatcher.sh`) automatically detects the language and applies the appropriate build mode:

```bash
case "$lang" in
    "java"|"cpp"|"go"|"csharp")
        # Use Manual Build Mode
        codeql database create ...
        codeql database trace-command ...
        codeql database finalize ...
        codeql database analyze ...
        ;;
    "javascript"|"python")
        # Use Build Mode: None
        codeql database create ...
        codeql database finalize ...
        codeql database analyze ...
        ;;
esac
```

## Troubleshooting

### Common Issues

1. **Build command not found**: Ensure build tools (mvn, gradle, cmake, go, dotnet) are installed
2. **Database creation fails**: Check source root path and language specification
3. **Tracing fails**: Verify build commands work independently first
4. **Analysis produces no results**: Check query suite paths and database finalization

### Debug Mode

Enable verbose output:
```bash
codeql database create --verbose ...
codeql database trace-command --verbose ...
```

## Best Practices

1. **Always test build commands** before running CodeQL
2. **Use appropriate query suites** for your language
3. **Include custom queries** from `security/codeql-queries/`
4. **Set proper source root** to include all relevant files
5. **Handle build failures gracefully** in automation

## References

- [CodeQL Documentation](https://codeql.github.com/docs/)
- [CodeQL CLI Reference](https://codeql.github.com/docs/codeql-cli/)
- [Language-Specific Guides](https://codeql.github.com/docs/codeql-overview/)
