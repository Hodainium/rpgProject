# Turn-Based RPG Distributed System Demo

A data-driven roguelike (Isaac-style floors and items × Honkai: Star Rail turn-based combat, Godot 4.7 + GodotGAS)
that plays offline-first and submits battles and runs to a .NET 10 backend for verification, settlement, player
analytics and live monitoring. Its real purpose is to produce traffic for a distributed backend that mirrors enterprise infrastructure
patterns.

Every battle and every run is a versioned distributed workflow with server-issued floor seeds, an ordered idempotent command
log, at-least-once replay verification, exactly-once reward effects, outbox-based event publication, player analytics,
and end-to-end observability.

## Enterprise mapping
| Component | Tech here | Analogous to | Fit |
|---|---|---|---|
| Service layer | ASP.NET Core 10 REST (`src/Rpg.GameServerApi`) | BAS-style services: contracts, request context, deadlines | Conceptual |
| Replay verifiers | Headless Godot worker pool | Versioned calculation workers in a managed compute pool | Architectural, not technological |
| Work queues | RabbitMQ | BlazingMQ | Strong |
| Event log | Redpanda (Kafka API) | BMS Kafka | Strong |
| Game analytics | Redpanda consumers projecting into Postgres tables, read by the dashboard | Event-driven reporting / data products fed from the event log | Strong |
| Relational store | PostgreSQL | Managed Postgres; Comdb2 patterns | Strong, not one-to-one |
| Cache / coordination | Redis | Cache and duplicate-work suppression (not the source of correctness) | Strong |
| Observability | Prometheus + Grafana + OpenTelemetry | GUTS metrics, Grafana, distributed tracing | Strong |
| Admin UI | React/TS (`web-dashboard`) | BBUI-style web frontend | Strong |
| Browser push | SignalR / WebSockets | Push gateway to the browser | Delivery layer only |
| Load testing | Locust (`load-test`) | Load, capacity and failure testing | Strong |

## Running infra
```sh
cd infra
cp .env.example .env   # then edit
docker compose up -d                          # core services
docker compose --profile observability up -d  # + Prometheus (9090) and Grafana (3000)
```
