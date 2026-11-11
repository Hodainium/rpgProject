# Enterprise mapping

Internal design note, kept off the README on purpose. How each part of this project corresponds to the enterprise
infrastructure it is modelled on.

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
