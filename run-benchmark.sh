#!/usr/bin/env bash
# ==============================================================================
# GqlGateway Benchmark & Simulation Suite Runner
# Rootless Podman Compose Orchestrator
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

VUS="${VUS:-50}"
DURATION_STEADY="${DURATION_STEADY:-3m}"
SEED_ROW_COUNT="${SEED_ROW_COUNT:-200000}"
CHAOS="${CHAOS:-true}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"

print_help() {
    echo "Usage: ./run-benchmark.sh [options]"
    echo ""
    echo "Options:"
    echo "  --vus <number>         Virtual concurrent users (default: 50)"
    echo "  --duration <time>      Steady state duration, e.g. 3m, 5m (default: 3m)"
    echo "  --seed-rows <number>   Rows seeded in postgres invoices table (default: 200000)"
    echo "  --no-chaos             Disable the Redis outage chaos test"
    echo "  --keep-running         Leave containers running after benchmark"
    echo "  --help                 Show this help message"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vus) VUS="$2"; shift 2 ;;
        --duration) DURATION_STEADY="$2"; shift 2 ;;
        --seed-rows) SEED_ROW_COUNT="$2"; shift 2 ;;
        --no-chaos) CHAOS="false"; shift 1 ;;
        --keep-running) KEEP_RUNNING="true"; shift 1 ;;
        --help) print_help ;;
        *) echo "Unknown option: $1"; print_help ;;
    esac
done

export VUS DURATION_STEADY SEED_ROW_COUNT
export COMPOSE_FILE="${COMPOSE_FILE:-podman-compose.yaml}"
export PACING_SLEEP="${PACING_SLEEP:-false}"

log() { echo -e "\033[1;36m[GqlGateway Bench]\033[0m $1"; }
log_success() { echo -e "\033[1;32m[GqlGateway Bench]\033[0m $1"; }
log_err() { echo -e "\033[1;31m[GqlGateway Bench] ERROR:\033[0m $1" >&2; }

# Determine compose command
if command -v podman &>/dev/null && podman compose version &>/dev/null; then
    COMPOSE="podman compose"
elif command -v podman-compose &>/dev/null; then
    COMPOSE="podman-compose"
else
    log_err "Neither 'podman compose' nor 'podman-compose' was found."
    exit 1
fi
log_success "Using orchestrator: ${COMPOSE}"

# 1. Stage Source Code
./scripts/stage_sources.sh

mkdir -p results

cleanup() {
    if [[ "${KEEP_RUNNING}" != "true" ]]; then
        log "Cleaning up benchmark containers..."
        ${COMPOSE} down || true
        log_success "Teardown complete."
    fi
}
trap cleanup EXIT

# 2. Build and Launch Services
log "Starting infrastructure (PostgreSQL, Redis, Governance Seed, GqlGateway API, Reverse Proxy, Prometheus, Grafana)..."
${COMPOSE} up -d --build postgres redis governance-seed gqlgateway-api reverse-proxy prometheus grafana

# 3. Wait for Health Checks
log "Waiting for services to become healthy..."
MAX_RETRIES=60
READY=false
for ((i=1; i<=MAX_RETRIES; i++)); do
    if curl -fsS http://localhost:8080/health/ready 2>/dev/null | grep -q '"Ready"'; then
        READY=true
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

if [[ "${READY}" != "true" ]]; then
    log_err "Services failed to become ready in time. Container logs:"
    ${COMPOSE} logs gqlgateway-api
    exit 1
fi
log_success "All services healthy! (Reverse Proxy: :8080, Gateway: :5050, Grafana: :3000, Prometheus: :9090)"

# 4. Run k6 Load Generator
log "Executing k6 benchmark (${VUS} VUs, Steady State: ${DURATION_STEADY})..."
${COMPOSE} run --rm load-generator

# 5. Run Chaos Test
if [[ "${CHAOS}" == "true" ]]; then
    log "Executing Chaos Engineering Test (Redis Outage)..."
    if command -v python3 &>/dev/null; then
        python3 scripts/chaos_test.py || true
    else
        podman run --rm --net=gateway-bench-net -v "$(pwd)/results:/results:z" -v "$(pwd)/scripts:/scripts:z" docker.io/library/python:3.12-alpine python /scripts/chaos_test.py || true
    fi
fi

# 6. Generate Report
log "Generating Markdown Benchmark Report..."
if command -v python3 &>/dev/null; then
    python3 scripts/generate_report.py
else
    podman run --rm -v "$(pwd)/results:/results:z" -v "$(pwd)/scripts:/scripts:z" docker.io/library/python:3.12-alpine python /scripts/generate_report.py
fi

if [[ -f results/benchmark-report.md ]]; then
    log_success "REPORT GENERATED: results/benchmark-report.md"
    echo ""
    echo -e "\033[1;32m==========================================================================\033[0m"
    echo -e "\033[1;32m                   GQLGATEWAY BENCHMARK COMPLETE                          \033[0m"
    echo -e "\033[1;32m==========================================================================\033[0m"
    echo "Markdown Report:    results/benchmark-report.md"
    echo "Metrics JSON:       results/benchmark-summary.json"
    echo "Metrics CSV:        results/benchmark-summary.csv"
    echo "Grafana Dashboard:  http://localhost:3000 (User: admin / Pass: admin)"
    echo "Prometheus Metrics: http://localhost:9090"
    echo -e "\033[1;32m==========================================================================\033[0m"
fi

if [[ "${KEEP_RUNNING}" == "true" ]]; then
    log "Containers left running (--keep-running specified). Run '${COMPOSE} down' when done."
fi
