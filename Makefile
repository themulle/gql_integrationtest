# ==============================================================================
# Makefile for GqlGateway Benchmark & Simulation Suite
# ==============================================================================

.PHONY: all bench up down chaos report clean test

all: bench

# Run full end-to-end benchmark suite
bench:
	@chmod +x run-benchmark.sh scripts/*.sh scripts/*.py 2>/dev/null || true
	./run-benchmark.sh

# Start infrastructure containers and wait for healthchecks
up:
	@./scripts/stage_sources.sh
	podman compose up -d --build postgres redis governance-seed gqlgateway-api reverse-proxy prometheus grafana || \
	podman-compose up -d --build postgres redis governance-seed gqlgateway-api reverse-proxy prometheus grafana

# Tear down containers and networks
down:
	podman compose down || podman-compose down

# Execute Redis outage chaos test against running environment
chaos:
	python3 scripts/chaos_test.py

# Re-generate Markdown and CSV report from recorded metrics
report:
	python3 scripts/generate_report.py

# Clean generated reports and staged build cache
clean:
	rm -rf results/*.json results/*.csv results/*.md src_build/
