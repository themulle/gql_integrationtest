# GqlGateway Simulations- und Benchmark-Umgebung

Vollständige, reproduzierbare Last- und Latenz-Benchmark-Umgebung für das Projekt **GqlGateway** (.NET 8/10 GraphQL-Gateway mit Consent-, RLS- und Column-Masking-Governance-Schicht) auf Basis von **Podman Compose**.

---

## 1. Architektur-Übersicht

```
                           [ k6 Load Generator ]
                      (60% Simple | 20% Complex | 10% Mutations | 10% Invalid)
                                     │
                             HTTP (Port 8080)
                                     ▼
                        [ Nginx Reverse Proxy ]
               (ForwardAuth Ingress, Header Injection, Shared Secret)
                                     │
                             HTTP (Port 5000)
                                     ▼
                        [ GqlGateway.Api (.NET 10) ]
                   ┌─────────────────┼─────────────────┐
                   ▼                 ▼                 ▼
          [ PostgreSQL DB ]     [ Redis 7 ]    [ SQLite Governance DB ]
          (200k+ Invoices &     (Rate Limiter,  (Policies, Data Owners,
           Line Items)           Consent Cache,  Consents & Row Filters)
                                 Idempotency)
```

### Enthaltene Services in der `podman-compose.yaml`
1. **`gqlgateway-api`**: Multi-Stage Build (`Containerfile`) mit .NET 10 Runtime. Startet in gehärteter Production-Konfiguration: ForwardAuth aktiv, TestAuthHandler deaktiviert, Token-Bucket Rate Limiter aktiv, Postgres- und Redis-Anbindung.
2. **`postgres`**: Echtes Enterprise-RDBMS für Invoices & Items. Mit automatischen Init-SQL-Skripten, die über `generate_series()` konfigurierbare Zeilenmengen (Standard: 200.000 Zeilen) inkl. sensibler Daten (`email`, `iban`, `salary`) für Masking-Tests seeden.
3. **`redis`**: Cache-Store für `ConsentCacheService` (Epoch Invalidation Pub/Sub), `RedisRateLimiterService` (Token-Bucket Lua-Scripts), `RedisIdempotencyStore` und EventBus.
4. **`governance-seed`**: Init-Container (`Containerfile`), der die SQLite-Governance-DB (`/data/governance.db`) mit Rollen, Gruppen, Data-Ownern, Vier-Augen-Prinzip-Tabellen, Masking-Regeln und RLS-Row-Filtern initialisiert.
5. **`reverse-proxy`**: Nginx ForwardAuth Gateway. Injiziert `X-Forwarded-Secret` und leitet Benutzeridentitäten (`X-Forwarded-User`, `X-Forwarded-Roles`, `X-Forwarded-Groups`) unter echten Netzwerkbedingungen an das Gateway weiter.
6. **`load-generator`**: k6-Container mit parametrisierbarem Lastprofil (Ramp-up → Steady State → Ramp-down) und dem geforderten 60/20/10/10 Query-Mix.
7. **`prometheus` & `grafana`**: Automatisches Scraping von Gateway-Metriken (`/metrics`) und vorkonfiguriertes Grafana-Dashboard (`http://localhost:3000`).

---

## 2. Systemvoraussetzungen

- **Betriebssystem**: Windows 10/11 (mit Podman Desktop / WSL2) oder Linux (RHEL, Fedora, Ubuntu, Debian) oder macOS.
- **Podman**: Version 4.4+ oder 5.x (`podman compose` oder `podman-compose`).
- **Hardware-Empfehlung**:
  - Mindestens: 4 CPU-Kerne, 8 GB RAM.
  - Empfohlen für Benchmark mit 50 VUs & 200k Zeilen: 8 CPU-Kerne, 16 GB RAM.

---

## 3. Schnellstart (One-Click)

### Unter Windows (PowerShell)
Startet die gesamte Umgebung mit Standardparametern (50 VUs, 3 Minuten Steady State, 200.000 Zeilen Seed-Daten, Redis-Chaos-Test):

```powershell
.\run-benchmark.ps1
```

Mit individuellen Parametern:
```powershell
.\run-benchmark.ps1 -VUs 100 -Duration "5m" -SeedRows 500000 -Chaos $true
```

Um die Container nach dem Test für manuelle Analysen laufen zu lassen:
```powershell
.\run-benchmark.ps1 -KeepRunning $true
```

### Unter Linux / WSL / macOS (Bash oder Make)
```bash
# Mit Bash-Skript
./run-benchmark.sh --vus 50 --duration 3m --seed-rows 200000

# Oder mit Makefile
make bench
```

---

## 4. Parameter-Anpassung

Alle Parameter lassen sich über CLI-Argumente oder Umgebungsvariablen anpassen:

| Parameter | PowerShell Flag | Bash Flag | Standardwert | Beschreibung |
| :--- | :--- | :--- | :---: | :--- |
| **Gleichzeitige Nutzer** | `-VUs 50` | `--vus 50` | `50` | Anzahl virtueller Nutzer in k6 |
| **Steady State Dauer** | `-Duration "3m"` | `--duration 3m` | `3m` | Dauer der Maximallast (z. B. `1m`, `5m`, `10m`) |
| **Seed-Zeilenanzahl** | `-SeedRows 200000` | `--seed-rows 200000`| `200000` | Zeilenanzahl in der PostgreSQL `invoices`-Tabelle |
| **Redis Chaos Test** | `-Chaos $true` | `--no-chaos` | `$true` | Führt Redis-Ausfalltest zur Validierung von Fail-Open/Fail-Closed durch |
| **Container behalten** | `-KeepRunning $true`| `--keep-running` | `$false` | Verhindert automatischen Teardown am Testende |

---

## 5. Podman-spezifische Besonderheiten

Die Umgebung wurde speziell für **Podman** entwickelt und beachtet alle Eigenheiten:
1. **Rootless Betrieb**: Alle Container laufen ohne Root-Rechte mit dedizierten Benutzer-IDs (`appuser:10001` in `gqlgateway-api`).
2. **SELinux-Volume-Labels**:
   - `:Z` für private Volumes (`postgres-data`, `prometheus-data`, read-only SQL scripts).
   - `:z` für geteilte Volumes zwischen Containern (`governance-data` zwischen `governance-seed` und `gqlgateway-api`).
3. **Keine `privileged: true`-Direktiven**: Maximale Sicherheit im Zero-Trust-Modus.
4. **Healthcheck-Ketten**:
   - `gqlgateway-api` wartet auf gesunde `postgres`-, `redis`- und `governance-seed`-Container.
   - `reverse-proxy` wartet auf gesunden `gqlgateway-api`-Dienst.
   - `load-generator` startet erst, wenn der Reverse-Proxy vollständig betriebsbereit ist.

---

## 6. Query-Mix im Lasttest (k6)

Der Lastgenerator bildet ein realistisches Anwendungsszenario ab:

- **60 % Einfache paginierte Abfragen**:
  - GraphQL-Query: `table(domain: "finance", name: "invoices", schema: "public", first: 10..50, after: 0..500)`.
  - Testet RLS-Pushdown (`WHERE department = 'Finance'`) und dynamisches Column-Masking (`email`, `iban`, `salary`).
- **20 % Komplexe Abfragen & Relationen**:
  - GraphQL-Query: `finance.invoicesWithItems(first: 5..15) { id, amount, vendor, email, items { productName, price, sensitiveNote } }`.
  - Nutzt GreenDonut `BatchDataLoader` zur Vermeidung des N+1 Problems bei 1:N-Relationen.
  - Dynamische Katalogabfragen (`catalog { domain, schema, tableName, columns }`) mit Rollen-Filterung.
- **10 % Mutationen & Idempotenz**:
  - Consent-Antragsflow (`requestTableAccess(...)`).
  - Sendet Duplikate mit identischem `Idempotency-Key` und prüft, ob die Antwort sofort aus dem Redis-Idempotency-Store bedient wird.
- **10 % Ungültige / Übergroße Anfragen**:
  - Paginierung über das Response-Cap (`first: 99999`) -> `RESPONSE_TOO_LARGE`.
  - Anfragen blockierter Benutzer (`X-Benchmark-Role: Blocked`) -> `FORBIDDEN`.
  - Anfragen auf nicht-existente Tabellen -> `FORBIDDEN` (Anti-Enumeration).
  - Burst-Anfragen zur Prüfung der IP- und SID-Token-Bucket-Limits -> `RATE_LIMIT_EXCEEDED`.

---

## 7. Chaos Engineering: Redis-Ausfall-Test

Das Skript `scripts/chaos_test.py` simuliert einen temporären Ausfall des Redis-Containers während des Betriebs:
- **Rate Limiter (Fail-Open)**: Bei Nichterreichbarkeit von Redis fällt `RedisRateLimiterService` laut Architektur auf den lokalen In-Memory-Rate-Limiter zurück. Reguläre Anfragen werden nicht blockiert (Verfügbarkeit bleibt erhalten).
- **Governance & Sicherheit (Fail-Closed)**: Unautorisierte Zugriffe (z. B. blockierte Rollen oder fehlende ALLOW-Consents) werden weiterhin strikt mit `FORBIDDEN` abgewiesen.
- **Healthcheck**: `/health/ready` meldet während des Ausfalls korrekt `HTTP 503 Service Unavailable` für die Komponente Redis.
- **Recovery**: Nach Neustart des Redis-Containers verbindet sich das Gateway automatisch neu und `/health/ready` liefert wieder `HTTP 200 Ready`.

---

## 8. Monitoring & Dashboards

- **Grafana**: `http://localhost:3000` (Login: `admin` / `admin`)
  - Vorkonfiguriertes Dashboard **"GqlGateway Benchmark Dashboard"**:
    - Request Throughput (RPS)
    - Latenz-Perzentile (p50, p95, p99)
    - ConsentCache Hits vs. Misses
    - Rate Limit Rejections (`pre_auth_ip` vs. `post_auth_sid`)
    - GC Memory und CPU-Auslastung des .NET-Gateways
- **Prometheus**: `http://localhost:9090`

---

## 9. Ergebnis-Artefakte

Nach jedem Durchlauf werden strukturierte Reports im Ordner `results/` abgelegt:
1. `results/benchmark-report.md`: Ausführlicher Markdown-Ergebnisbericht mit KPI-Tabellen, Latenzkurven und Sicherheitsbewertung.
2. `results/benchmark-summary.json`: Alle k6-Metriken im JSON-Format.
3. `results/benchmark-summary.csv`: Tabellarische Metriken für automatisierte CI/CD-Auswertungen.
4. `results/chaos-test-result.json`: Validierungsergebnis des Redis-Chaos-Tests.
