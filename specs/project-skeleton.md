# Spec: project-skeleton (slice 0)

Status: 📝 Reviewed, ready to implement · Roadmap: slice 0 · Date: 2026-10-14

## 1. Purpose & enterprise mapping
Create the .NET solution and prove that every build and runtime connection works end to end before any game or workflow
code exists. After this slice:
- `dotnet build` and `dotnet test` at the repo root pass.
- `Rpg.GameServerApi` starts on the host, connects to the compose stack and reports readiness.
- Prometheus scrapes the server and Grafana can query it.
- `Rpg.Client` (the client's HTTP layer) calls the server successfully in tests, and the Godot project compiles against it.

No battle, gacha, persistence schema, queue topology or event topic is created here.

| Component | Used in this slice | How |
|---|---|---|
| Service layer (`Rpg.GameServerApi`) | ✅ | Minimal API host: health, info, metrics |
| Contracts (`Rpg.Contracts`) | ✅ | One DTO plus the shared JSON serializer options |
| PostgreSQL | ✅ connectivity only | Readiness probe. No tables, no migration tool yet (chosen in slice 2). |
| Redis | ✅ connectivity only | Readiness probe, reported as *Degraded* rather than failing (see §4) |
| RabbitMQ | ✅ connectivity only | One long-lived connection plus a readiness probe. No exchanges or queues are declared. |
| Redpanda | ❌ | N/A: only the outbox relay (slice 4) talks to it |
| Prometheus / Grafana | ✅ | Scrape `/metrics`; the existing datasource is enough. No dashboards yet (slice 6). |
| OpenTelemetry | ✅ baseline | Metrics plus trace instrumentation wired. Trace export only if an OTLP endpoint is configured (none in compose yet). |
| Client HTTP layer (`Rpg.Client`) | ✅ | Typed wrapper over .NET's built-in `HttpClient`: one method, `GetInfoAsync` |
| Godot client C# | ✅ project file only | `rpgDemo.csproj` referencing `Rpg.Client`. No C# scripts, no scenes, nothing in `content/` or `presentation/`. |
| Verifier workers, SignalR, web-dashboard, Locust | ❌ | Later slices |

### Repository layout created
```
global.json                         # pins the .NET 10 SDK (10.0.402, rollForward latestFeature; 5/8/9 are also installed)
Rpg.slnx                            # root solution (.NET 10 SDK default XML format)
Directory.Build.props               # net10.0, nullable, warnings-as-errors
Directory.Packages.props            # central package versions, all pinned exactly
src/Rpg.Contracts/                  # classlib: wire shapes only, no package dependencies
src/Rpg.Client/                     # classlib: typed HTTP client over HttpClient; references Rpg.Contracts only
src/Rpg.GameServerApi/              # ASP.NET Core 10 minimal API; references Rpg.Contracts
tests/Rpg.Contracts.Tests/          # xUnit: JSON golden vectors, purity guards
tests/Rpg.GameServerApi.Tests/      # xUnit: WebApplicationFactory + Testcontainers, driven through Rpg.Client
client-godot/rpgDemo.csproj         # Godot.NET.Sdk, matching the pinned editor build; references Rpg.Client
```
Dependency direction: `Rpg.Contracts` ← `Rpg.Client` ← Godot, and `Rpg.Contracts` ← `Rpg.GameServerApi`. The server never
references `Rpg.Client`, and neither library references Godot.
- **Why a library and not Godot's `HTTPRequest` node:** `HttpClient` is .NET's built-in HTTP stack, so nothing homemade is
  involved. `Rpg.Client` is only a few typed methods (route + DTO) on top of it. Keeping it outside Godot means `dotnet test`
  exercises the real client against the real server without launching Godot. Godot's `HTTPRequest` would need a scene-tree
  node and returns untyped dictionaries instead of the `Rpg.Contracts` records.
- `rpgDemo.csproj` is included in `Rpg.slnx`, so the root build catches contract breaks in the client too.
  Godot also keeps its own `client-godot/rpgDemo.sln` for the editor; both reference the same `.csproj`.
- The CLAUDE.md "Current state" table and `specs/roadmap.md` are updated when the slice lands.

## 2. Sequence flow

**A. Dev startup**
1. `cd infra && docker compose up -d` (optionally `--profile observability`).
2. `dotnet run --project src/Rpg.GameServerApi` listens on `http://localhost:5000`, the port `infra/prometheus/prometheus.yml` already scrapes.
   Startup does **not** block on dependencies: Npgsql, the Redis multiplexer and RabbitMQ all connect lazily or with
   automatic recovery, so the server starts even if the stack is down.
3. Secrets: connection settings come from configuration keys (below). In dev, passwords go in `dotnet user-secrets`
   for `Rpg.GameServerApi`. In containers (later slices), they come from environment variables. Nothing secret is committed.

**B. Readiness probe**
```
probe/curl ──GET /health/ready──▶ GameServerApi
                                   ├─▶ Postgres  SELECT 1             (timeout 2 s)
                                   ├─▶ Redis     PING                 (timeout 1 s)
                                   └─▶ RabbitMQ  connection IsOpen    (no network call)
                                  ◀── 200 Healthy | 200 Degraded | 503 Unhealthy (JSON per-check report)
```
`GET /health/live` runs no dependency checks: it returns 200 whenever the process is serving.

**C. Client call**
```
Rpg.Client GameServerClient ──GET /api/v1/info──▶ GameServerApi ──▶ 200 ServerInfoResponse
```
```csharp
namespace Rpg.Client;

public sealed class GameServerClient(HttpClient http)   // caller owns HttpClient and its BaseAddress
{
    public Task<ServerInfoResponse> GetInfoAsync(CancellationToken ct = default);
}
```
- Deserializes with `RpgJson.Options`. A non-2xx response throws `GameServerApiException` carrying the status code and
  the parsed `ProblemDetails` (if any).
- In this slice it's called from tests only. Godot code starts calling it in slice 2.

**D. Metrics**
```
Prometheus ──GET /metrics (every 5 s)──▶ GameServerApi (OpenTelemetry Prometheus exporter)
Grafana ──PromQL──▶ Prometheus
```

### Configuration keys
| Key | Dev default (`appsettings.Development.json`) | Secret? |
|---|---|---|
| `ConnectionStrings:Postgres` | `Host=localhost;Port=5432;Database=rpg_db;Username=postgres` (password via user-secrets) | password |
| `ConnectionStrings:Redis` | `localhost:6379,abortConnect=false` | no |
| `RabbitMq:Uri` | `amqp://rpg@localhost:5672/` (password via user-secrets) | password |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset → no trace export | no |

## 3. Data contracts

### `Rpg.Contracts` (namespace `Rpg.Contracts`)
```csharp
namespace Rpg.Contracts.Api.V1;

/// GET /api/v1/info. Lets clients confirm which server build they are talking to.
public sealed record ServerInfoResponse(
    string Service,            // "rpg-game-server-api"
    string BuildVersion,       // assembly informational version, e.g. "0.1.0+f81f7ac"
    DateTimeOffset ServerTimeUtc);
```
```csharp
namespace Rpg.Contracts.Serialization;

/// The single JSON convention shared by server and client. Configuration only, no logic.
public static class RpgJson
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        // Web defaults: camelCase properties, case-insensitive reads.
        // Enums serialize as strings (e.g. "Rejected"); numeric codes like errorCode are separate int fields.
        Converters = { new JsonStringEnumConverter() },
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };
}
```
- The server registers `RpgJson.Options` for minimal-API JSON (`ConfigureHttpJsonOptions`), so wire output and client
  parsing cannot drift.
- `Rpg.Contracts` has **zero** package references and targets `net10.0` (or `net8.0` under the fallback in Decisions §4). No game logic, as CLAUDE.md requires.
- **Error envelope:** 4xx responses use ASP.NET Core's built-in `ProblemDetails` (`AddProblemDetails()`). No custom
  error DTO is added yet. The verdict shape with `errorCode` 2002 belongs to slice 3, where it is used.

### RabbitMQ / Redpanda / Redis
N/A: no queues, topics or keys are declared in this slice. The server opens a RabbitMQ connection and a Redis
multiplexer only to prove connectivity.

## 4. Failure modes
No acceptance scenario from the root CLAUDE.md is completed by this slice. It sets two policies that later slices depend on:

| Situation | Behaviour | Why | Test |
|---|---|---|---|
| Postgres down | `/health/ready` → **503 Unhealthy**; `/health/live` → 200 | Postgres is the source of truth; nothing can be served correctly without it | `Ready_Returns503_WhenPostgresUnreachable` |
| Redis down | `/health/ready` → **200 Degraded** | Redis is never the source of correctness; groundwork for **scenario 4** (the slice 2 fallback) | `Ready_ReportsDegraded_WhenRedisUnreachable` |
| RabbitMQ down | `/health/ready` → **503 Unhealthy**; the client auto-recovers when the broker returns | `/verify` (slice 3) cannot accept work without the broker | `Ready_Returns503_WhenRabbitUnreachable`, `Ready_RecoversAfterRabbitRestart` |
| Any dependency down at startup | Server still starts; readiness reflects reality | Lets you start services in any order and supports chaos tests later | `Server_Starts_WithNoDependencies` |
| Slow dependency | Each check has its own timeout (above), so one hang cannot stall the probe | Probes must answer quickly | covered by the 503 tests (unreachable host + timeout) |
| Unknown route | 404 `ProblemDetails` | Error contract: 4xx only for malformed or unauthorized requests. No endpoint takes a request body yet, so 400 validation arrives in slice 2 with `/battle/start` | `UnknownRoute_Returns404ProblemDetails` |

Idempotency, retries and dead-lettering: N/A, no writes or queues in this slice.

## 5. Observability
OpenTelemetry .NET with the Prometheus exporter (`OpenTelemetry.Exporter.Prometheus.AspNetCore`), mapped at `/metrics`.
Note: that exporter is still published as a **prerelease** package. It is pinned to an exact version in
`Directory.Packages.props`. The fallback, if it causes trouble, is `prometheus-net` behind the same `/metrics` path.

| Metric (Prometheus name) | Type | Labels | Source |
|---|---|---|---|
| `http_server_request_duration_seconds` | histogram | `http_route`, `http_request_method`, `http_response_status_code` | ASP.NET Core instrumentation |
| `process_runtime_dotnet_*` / `dotnet_*` | various | — | Runtime instrumentation (GC, thread pool, exceptions) |
| `rpg_build_info` | gauge (always 1) | `service`, `version` | Custom: lets Grafana show which build is running |
| `rpg_dependency_health` | gauge (1 healthy, 0.5 degraded, 0 unhealthy) | `dependency` = `postgres`/`redis`/`rabbitmq` | Custom: health-check publisher, every 10 s |

- `/metrics`, `/health/*` are excluded from the HTTP histogram so scrapes and probes don't drown real traffic.
- Tracing: ASP.NET Core + HttpClient instrumentation enabled, resource `service.name=rpg-game-server-api`. Export via OTLP only when
  `OTEL_EXPORTER_OTLP_ENDPOINT` is set. A trace backend (Tempo or Jaeger) arrives in slice 6.
- Prometheus target port 5000 is set in `Properties/launchSettings.json`, and the comment in `prometheus.yml` is updated to point to it.

## 6. Test plan

### `tests/Rpg.Contracts.Tests` (no Docker)
- **Golden vector:** `ServerInfoResponse` serialized with `RpgJson.Options` equals the committed file
  `tests/Rpg.Contracts.Tests/golden/server-info.json` byte for byte (fixed input, camelCase, ISO-8601 `+00:00` time).
- **Round trip:** the golden file deserializes back to an equal record.
- **Enum convention:** a test-local enum serializes as a string, proving the converter is registered.
- **Purity guards:** reflection tests asserting `Rpg.Contracts` references only `System.*` assemblies, and `Rpg.Client`
  references only `System.*` plus `Rpg.Contracts` (no Godot, no server).

### `tests/Rpg.GameServerApi.Tests` (Docker required)
`WebApplicationFactory<Program>` with real Postgres 16, Redis 7 and RabbitMQ 4.1 started by **Testcontainers**, using the
same images as `infra/docker-compose.yml`. Docker Desktop is already a project prerequisite, so `dotnet test` at the root
runs these by default.
- `Live_Returns200_Always`
- `Ready_Returns200Healthy_WhenAllUp`
- `Ready_Returns503_WhenPostgresUnreachable` (container stopped)
- `Ready_ReportsDegraded_WhenRedisUnreachable`
- `Ready_Returns503_WhenRabbitUnreachable` and `Ready_RecoversAfterRabbitRestart`
- `Server_Starts_WithNoDependencies` (connection strings point at closed ports)
- `Client_GetInfo_ReturnsServerInfo` (`GameServerClient` wrapped around the factory's `HttpClient`: real client, real server)
- `Client_Throws_WithProblemDetails_OnErrorStatus`
- `Metrics_ExposesBuildInfoAndHttpHistogram` (calls `/api/v1/info`, then checks `/metrics` text)
- `UnknownRoute_Returns404ProblemDetails`

### Godot client
- `dotnet build` at the root compiles `rpgDemo.csproj` with its `Rpg.Client` reference. Nothing runs in Godot this slice.

### Done when
- [ ] `dotnet build` and `dotnet test` pass at the root (with Docker running).
- [ ] `docker compose --profile observability up -d` plus the running server shows target `rpg-game-server-api` **UP** in Prometheus.
- [ ] `rpg_dependency_health` is queryable in Grafana Explore.
- [ ] CLAUDE.md status table, `client-godot/CLAUDE.md` language split and `specs/roadmap.md` updated.

## Decisions (resolved in review, 2026-10-14)
1. **Godot build:** `Godot_v4.7.2-stable_mono_win64` (local editor at `H:\Godot\`). `rpgDemo.csproj` uses
   `Sdk="Godot.NET.Sdk/4.7.2"`, pinned exactly; it must change in lockstep with the editor and the verifier image.
2. **Docker is required for `dotnet test`.** Server tests run by default with no filter or skip; without Docker they fail visibly.
3. **Prerelease OpenTelemetry Prometheus exporter**, pinned, versus `prometheus-net` (stable but not OpenTelemetry). Chosen: OpenTelemetry, because it fits the pitch.
4. **.NET 10 (LTS, supported to Nov 2028)** for every project, replacing .NET 8 (support ends 2026-11-10).
   **First implementation step:** prove Godot 4.7.2 builds and runs a `net10.0` project headless
   (`Godot_v4.7.2-stable_mono_win64_console.exe --headless`). **Fallback if it can't:** `rpgDemo.csproj`, `Rpg.Contracts`
   and `Rpg.Client` target `net8.0`; `Rpg.GameServerApi` and the tests stay on `net10.0`. Record the outcome here.
