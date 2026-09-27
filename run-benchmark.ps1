<#
.SYNOPSIS
    GqlGateway Simulation & Benchmark Runner for Windows / PowerShell.
.DESCRIPTION
    Orchestrates the complete benchmark lifecycle using Podman Compose:
    stages source code, launches containers, waits for health checks,
    runs the k6 load generator, injects Redis chaos tests, and produces
    detailed Markdown, JSON, and CSV benchmark reports.
.PARAMETER VUs
    Number of virtual concurrent users (default: 50).
.PARAMETER Duration
    Steady-state benchmark duration (default: "3m").
.PARAMETER SeedRows
    Number of rows to seed into PostgreSQL invoices table (default: 200000).
.PARAMETER Chaos
    Whether to run the Redis outage chaos test (default: $true).
.PARAMETER KeepRunning
    Keep containers running after benchmark for interactive inspection (default: $false).
.EXAMPLE
    .\run-benchmark.ps1 -VUs 50 -Duration "3m" -Chaos $true
#>

[CmdletBinding()]
param(
    [int]$VUs = 50,
    [string]$Duration = "3m",
    [int]$SeedRows = 200000,
    [bool]$Chaos = $true,
    [bool]$KeepRunning = $false,
    [bool]$Pacing = $false,
    [int]$ProxyPort = 8082,
    [int]$GatewayPort = 5050
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

function Write-Info($msg) {
    Write-Host "[GqlGateway Bench] $msg" -ForegroundColor Cyan
}

function Write-Success($msg) {
    Write-Host "[GqlGateway Bench] $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "[GqlGateway Bench] WARNING: $msg" -ForegroundColor Yellow
}

function Write-Err($msg) {
    Write-Host "[GqlGateway Bench] ERROR: $msg" -ForegroundColor Red
}

# 1. Verify Podman
Write-Info "Verifying Podman installation..."
$podmanCmd = Get-Command "podman" -ErrorAction SilentlyContinue
if (-not $podmanCmd) {
    Write-Err "Podman was not found in PATH! Please install Podman Desktop or Podman CLI."
    exit 1
}

# Determine compose command: podman compose or podman-compose
$composeCmd = ""
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
try {
    $null = & podman compose version 2>$null
    if ($LASTEXITCODE -eq 0) {
        $composeCmd = "podman compose"
    }
} catch {
    # podman compose failed
} finally {
    $ErrorActionPreference = $prevEAP
}

if (-not $composeCmd) {
    $podmanComposeCmd = Get-Command "podman-compose" -ErrorAction SilentlyContinue
    if ($podmanComposeCmd) {
        $composeCmd = "podman-compose"
    } else {
        Write-Err "Neither 'podman compose' nor 'podman-compose' is available."
        Write-Err "Podman requires an external compose provider on Windows."
        Write-Err "To install Docker Compose (recommended), run:"
        Write-Err "  winget install Docker.DockerCompose"
        Write-Err "Or install podman-compose via Python:"
        Write-Err "  pip install podman-compose"
        exit 1
    }
}
Write-Success "Using compose orchestrator: $composeCmd"

# Ensure compose discovers podman-compose.yaml
$env:COMPOSE_FILE = "podman-compose.yaml"

# 2. Stage Source Code if needed
$srcBuild = Join-Path $ScriptDir "src_build"
if (-not (Test-Path (Join-Path $srcBuild "src"))) {
    Write-Info "Staging GqlGateway source code..."
    $candidate = Join-Path (Split-Path -Parent $ScriptDir) "gql"
    if (-not (Test-Path $candidate)) {
        $candidate = "C:\root\gql"
    }
    if (Test-Path (Join-Path $candidate "src")) {
        New-Item -ItemType Directory -Path $srcBuild -Force | Out-Null
        Copy-Item -Path (Join-Path $candidate "Directory.Build.props") -Destination $srcBuild -Force
        Copy-Item -Path (Join-Path $candidate "GqlGateway.sln") -Destination $srcBuild -Force
        Copy-Item -Path (Join-Path $candidate "src") -Destination $srcBuild -Recurse -Force
        Get-ChildItem -Path $srcBuild -Include "bin", "obj" -Recurse -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "Source code staged successfully."
    } else {
        Write-Warn "Could not find sibling 'gql' directory. Assuming build context is self-contained."
    }
}

# Ensure results folder exists
$resultsDir = Join-Path $ScriptDir "results"
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
$env:RESULTS_DIR = $resultsDir

# Set Environment Variables for Compose
$env:SEED_ROW_COUNT = $SeedRows.ToString()
$env:VUS = $VUs.ToString()
$env:DURATION_STEADY = $Duration
$env:PACING_SLEEP = if ($Pacing) { "true" } else { "false" }
$env:REVERSE_PROXY_PORT = $ProxyPort.ToString()
$env:GATEWAY_PORT = $GatewayPort.ToString()

# Cleanup trap to ensure graceful teardown on exit or error
$script:teardownNeeded = $true
function Clean-Teardown {
    if ($script:teardownNeeded -and -not $KeepRunning) {
        Write-Info "Tearing down Podman Compose containers..."
        Invoke-Expression "$composeCmd down"
        Write-Success "Teardown complete."
    }
}

try {
    # 3. Build & Start Infrastructure Services
    Write-Info "Building and launching infrastructure services..."
    Invoke-Expression "$composeCmd up -d --build postgres redis governance-seed gqlgateway-api reverse-proxy prometheus grafana"
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to build or start infrastructure services. Aborting benchmark."
        exit 1
    }

    # 4. Wait for Health Checks
    Write-Info "Waiting for GqlGateway and Reverse Proxy to become Healthy..."
    $maxRetries = 60
    $isReady = $false
    $targetHost = "localhost"
    $wslIp = ""
    try {
        $wslIpMatch = wsl -d podman-machine-default ip -4 addr show eth0 2>$null | Select-String 'inet (\d+\.\d+\.\d+\.\d+)'
        if ($wslIpMatch -and $wslIpMatch.Matches.Groups.Count -gt 1) {
            $wslIp = $wslIpMatch.Matches.Groups[1].Value
        }
    } catch {}

    for ($i = 1; $i -le $maxRetries; $i++) {
        foreach ($hostCandidate in @("localhost", $wslIp)) {
            if (-not $hostCandidate) { continue }
            try {
                $resp = Invoke-RestMethod -Uri "http://${hostCandidate}:${ProxyPort}/health/ready" -Method Get -TimeoutSec 3 -ErrorAction SilentlyContinue
                if ($resp -and $resp.status -eq "Ready") {
                    $targetHost = $hostCandidate
                    $isReady = $true
                    break
                }
            } catch {
                # Still initializing
            }
        }
        if ($isReady) { break }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 2
    }
    Write-Host ""

    if (-not $isReady) {
        Write-Err "Gateway did not reach 'Ready' healthcheck state within timeout. Check container logs:"
        Invoke-Expression "$composeCmd logs gqlgateway-api"
        exit 1
    }
    $env:TARGET_PROXY = "http://${targetHost}:${ProxyPort}"
    Write-Success "All services healthy! (Reverse Proxy: ${env:TARGET_PROXY}, Gateway: :${GatewayPort}, Grafana: :3000, Prometheus: :9090)"

    # 5. Execute k6 Load Generator
    Write-Info "Starting k6 Load Generator ($VUs VUs, Steady State: $Duration)..."
    Invoke-Expression "$composeCmd run --rm load-generator"

    # 6. Execute Chaos Test (if requested)
    if ($Chaos) {
        Write-Info "Starting Chaos Test (Redis outage fail-open & fail-closed validation)..."
        $pythonCmd = Get-Command "python" -ErrorAction SilentlyContinue
        if ($pythonCmd) {
            & python (Join-Path $ScriptDir "scripts\chaos_test.py")
        } else {
            # Run via python container if host lacks Python
            Invoke-Expression "podman run --rm --net=gateway-bench-net -v ${resultsDir}:/results:z -v ${ScriptDir}/scripts:/scripts:z docker.io/library/python:3.12-alpine python /scripts/chaos_test.py"
        }
    }

    # 7. Generate Comprehensive Benchmark Report
    Write-Info "Generating Markdown Benchmark Report..."
    $pythonCmd = Get-Command "python" -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        & python (Join-Path $ScriptDir "scripts\generate_report.py")
    } else {
        Invoke-Expression "podman run --rm -v ${resultsDir}:/results:z -v ${ScriptDir}/scripts:/scripts:z docker.io/library/python:3.12-alpine python /scripts/generate_report.py"
    }

    $reportPath = Join-Path $resultsDir "benchmark-report.md"
    if (Test-Path $reportPath) {
        Write-Success "REPORT GENERATED: $reportPath"
        Write-Host ""
        Write-Host "==========================================================================" -ForegroundColor Green
        Write-Host "                   GQLGATEWAY BENCHMARK COMPLETE                          " -ForegroundColor Green
        Write-Host "==========================================================================" -ForegroundColor Green
        Write-Host "View the report:   $reportPath"
        Write-Host "Metrics summary:   $(Join-Path $resultsDir 'benchmark-summary.json')"
        Write-Host "Grafana dashboard: http://localhost:3000 (User: admin / Pass: admin)"
        Write-Host "Prometheus:        http://localhost:9090"
        Write-Host "==========================================================================" -ForegroundColor Green
    }

    if ($KeepRunning) {
        $script:teardownNeeded = $false
        Write-Info "Containers kept running as requested (-KeepRunning `$true)."
        Write-Info "Run '$composeCmd down' when finished."
    }

} finally {
    Clean-Teardown
}
