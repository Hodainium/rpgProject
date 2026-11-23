# Spec: upload-compression (slice 5f): Brotli on the client's uploads

Status: **built 2026-11-22 (spec synced to the build the same day); awaiting playtest.** Decisions taken with the user the same
day (section 7). Follows `specs/hash-id-lists.md` (5d2) and `specs/server-authority.md` (Part B: the action log, its checkpoints
and the run end).

## 1. Purpose & enterprise mapping

**What.** The client compresses the bodies it uploads with Brotli, and the API decompresses them before anything reads them.
Nothing else changes: the same JSON arrives at the endpoints, is stored, verified and replayed exactly as today.

**Why (measured 2026-11-22 on the dev database, with the .NET built-in compressors this slice ships).**
- A batch of 50 actions averages 185 KB and reaches 1.0 MB (battle logs and checkpoint snapshots together; 60 real batches).
- Over half of all uploaded actions carry a snapshot (1204 of 2186), because every battle is a checkpoint. They stay:
  checkpoints keep steps short, verification parallel and the stairs wait quick (user, 2026-11-22). The lever is the size of
  each upload, not their number.
- Consecutive checkpoints in a batch are mostly alike, so a whole batch compresses far better than one snapshot (4x alone):

| Codec and level | Smaller by | Average batch | Compress per batch | Decompress per batch |
|---|---|---|---|---|
| gzip Fastest | 11.5x | 16 KB | 0.12 ms | 0.11 ms |
| gzip Optimal | 24.9x | 7 KB | 0.31 ms | 0.08 ms |
| Brotli Fastest | 34.4x | 5 KB | 0.14 ms | 0.15 ms |
| **Brotli Optimal (chosen)** | **47.3x** | **3 KB** | **0.36 ms** | **0.10 ms** |
| Brotli Smallest | 61.6x | 3 KB | 37.5 ms | 0.13 ms |

**What it is not.**
- Not storage: Postgres already compresses large values (a 10 KB snapshot is stored as about 3 KB). Database growth is
  retention's job (slice 7b).
- Not the verifier's speed: its cost is replaying the game.
- Not responses: `GET /resume` and other downloads stay as they are (section 7).

**Enterprise mapping.** `src/Rpg.Client` (the client's HTTP layer, shared by the Godot `ServerBridge` and the .NET tests) and
`src/Rpg.GameServerApi` (ASP.NET Core request decompression, per-endpoint size limits, metrics). Postgres, Redis, RabbitMQ,
Redpanda and the verifier worker are not touched. No contract records change. GDScript gains only the dev switch
(`ServerLink.compression` and the console's `server compression on|off`, section 3).

**Rejected alternatives.**
- Fewer checkpoints: longer steps, slower verification, a longer stairs wait.
- Deltas (only what changed since the last checkpoint): complex, and one bug corrupts the state the verifier relies on.
- gzip: 2x larger than Brotli at the same cost (the table). The server still accepts gzip bodies (the middleware's default
  providers), so a client that sends gzip works.
- Brotli Smallest: 100x the CPU of Optimal for 1.3x less.
- Compression in GDScript: the HTTP layer is C# by the language split (`client-godot/CLAUDE.md` section 1).

## 2. Sequence flow

1. The game calls `ServerBridge` with a whole record as JSON (unchanged). `GameServerClient.SendAsync` builds the request
   content as today (`JsonContent.Create`).
2. **New:** when the serialized body is at least `CompressAbove` bytes (default 1024) and compression is on (default on),
   the client compresses it with Brotli (`System.IO.Compression.BrotliStream`, `CompressionLevel.Optimal`), sends it as
   `ByteArrayContent` with `Content-Type: application/json; charset=utf-8` and `Content-Encoding: br`. Smaller bodies go as
   they are: a 300-byte batch gains nothing.
3. The request reaches the API. **The middleware order (`Program.cs`):** routing (explicit `UseRouting`, so each endpoint's
   limit and rate-limit bucket are known), authentication, authorization and presence (none reads the body; an anonymous
   request is refused with 401 before anything is inflated, and a refused upload still counts as presence), then the upload
   pipeline (`src/Rpg.GameServerApi/Uploads/Uploads.cs`), only for a request that can have a body and matched an endpoint:
   1. `UploadGate`: the encoding must be none (`identity`) or exactly one of `br`, `gzip`, `deflate` (the default
      providers), else 415; with `Uploads:Decompress=false` any compressed body is 415. A declared `Content-Length` already
      past the endpoint's limit is 413 at once. **The endpoint's rate-limit token is taken here**, before anything is
      inflated (section 4, U11). It sets `IHttpMaxRequestBodySizeFeature` to the limit (Kestrel's raw limit, and the one the
      decompression middleware reads) and wraps the raw body in a counting stream (the bytes on the wire).
   2. ASP.NET Core `RequestDecompression` (`AddRequestDecompression` + `UseRequestDecompression`): a compressed body is
      replaced by a decompressing stream and the header is removed.
   3. `UploadBuffer`: reads the (decompressed) body into memory with `UploadPipeline.ReadBoundedAsync`, which **stops one byte
      past the limit**, so a decompressing stream never inflates the rest (413). A body the decoder refuses is 400; Kestrel's own
      refusal of the body keeps its status (408 for a too slow upload, 400 for one that ends early); a client that went away
      gets no answer. The endpoint then reads the buffered bytes (`Content-Length` set to their size, restored afterwards).

   **Per-endpoint limits on the decompressed body:** 8 MB for `POST /runs/{id}/actions` and `POST /runs/{id}/end`
   (`Uploads:MaxLogBodyBytes`, 8x the largest batch measured; the endpoints carry `LogUploadMetadata` through `.LogUpload(route)`),
   64 KB for every other endpoint (`Uploads:MaxBodyBytes`; their bodies are a few hundred bytes). Plain (identity) bodies get the
   same limits, so the limit drops from Kestrel's 30 MB default for them too. The limit is enforced by the bounded read itself,
   whatever the framework does (D1).
4. The endpoint binds the JSON exactly as today. Idempotency (the body comparison of a retried batch), the rate limiter,
   auth, the stores and the outbox see the same data whatever the encoding.
5. Responses are unchanged.

**Deployment order.** The server accepts every encoding, so it goes out first; a client that compresses must never meet a
server that cannot decompress. In this repo both ship together, and `ServerBridge` can turn compression off (section 3).

## 3. Data contracts

No `Rpg.Contracts` record changes and no new error codes, no queue, topic or Redis key.

- **`Rpg.Client`:** `GameServerClient` gains `UploadCompression` options: `bool Enabled = true`, `int CompressAbove = 1024`,
  set through a constructor parameter (default on) or the settable `Compression` property. The body is serialized and
  compressed off the caller's thread (`Task.Run`: Godot calls in on its main thread), and every body, plain or compressed, is
  buffered and sent with its `Content-Length`. Applies to every request with a body (actions, end, run start, floor seeds,
  presence, card account calls, the admin calls).
- **`ServerBridge` (Godot C#):** `Configure(url, timeout)` keeps its signature and turns compression on. A new
  `SetCompression(bool enabled)`, inside the bridge's `#if DEBUG` section like the admin calls (not in the release `player`
  export, pinned by `test_admin_calls_stay_out_of_the_player_build`), lets the dev console turn it off: `server compression
  [on|off]` sets `ServerLink.compression` and calls the bridge (a new link starts with it on), to test an old client against
  the server. No Settings row: players never see it.
- **API configuration:** `Uploads:MaxLogBodyBytes` (default 8388608, the actions and end endpoints), `Uploads:MaxBodyBytes`
  (default 65536, every other endpoint), `Uploads:Decompress` (default true; false refuses compressed bodies with 415, an
  emergency switch-off). Both limits must be positive and below `int.MaxValue / 2` (the body is buffered in memory).
- **HTTP behaviour (the contract the client relies on).** Standard statuses with plain ProblemDetails and no `errorCode`,
  like a malformed JSON body today: our error codes are for domain cases the client acts on, and these are transport problems
  the status already names (user, 2026-11-22).

| Request | Answer |
|---|---|
| `Content-Encoding: br` or `gzip`, valid, decompressed size within the endpoint's limit | As today (the endpoint's own answer) |
| No `Content-Encoding` (identity), within the limit | As today |
| A `Content-Encoding` the server does not support (`zstd`, `x-foo`), or more than one coding (`gzip, br`) | 415 (the detail names the accepted codings, never repeats the header) |
| A compressed body the decoder refuses (corrupt) | 400 (`bad_body`) |
| A truncated compressed body | 400 from the endpoint's JSON binding: .NET's Brotli and gzip decoders end a cut-off stream early without an error, and a prefix of a JSON object is never a whole one; not counted as `bad_body` |
| Kestrel refuses the body on the wire (too slow, ends early) | Kestrel's status (408, 400) |
| Over the endpoint's rate limit | 429 1201 with `Retry-After`, before the body is read (U11) |
| No bearer token | 401, before the body is read (U12) |
| A body whose decompressed size passes the endpoint's limit (a zip bomb, or a huge plain body) | 413; the decompression stops at the limit, never reads the rest |

The client treats these like any other 4xx refusal: it never retries a 4xx.

## 4. Failure modes

| # | Failure | Behaviour | Test |
|---|---|---|---|
| U1 | A batch sent compressed, then retried | The retry may be compressed or plain: the endpoint compares the decoded body, so the retry is the same no-op as today | `Actions_RetriedBatch_BrotliThenPlain_IsANoOp` |
| U2 | A zip bomb: a few KB of Brotli that expand to gigabytes | 413 once the decompressed bytes pass the limit; memory stays bounded (the stream stops at the limit) | `Upload_ZipBomb_Is413_AndReadsNoMoreThanTheLimit` (16 MB of zeros as Brotli, a few KB, on the actions endpoint; and 1 MB on a small endpoint, past its 64 KB) |
| U3 | A corrupt or truncated compressed body | 400, nothing stored (a truncated one through the binding, section 3) | `Upload_CorruptBrotli_Is400` |
| U4 | An unsupported `Content-Encoding` | 415, nothing stored | `Upload_UnknownEncoding_Is415` |
| U5 | An old client (no compression) | Works as today | the existing suites with compression off for one class, plus `Upload_Identity_StillAccepted` |
| U6 | Compression switched off on the server (`Uploads:Decompress=false`) | Compressed bodies 415; identity bodies as today; the client can be told to stop compressing (`SetCompression(false)`) | `Upload_DecompressOff_RefusesCompressed` |
| U7 | A body under `CompressAbove` | Sent plain | `Client_SmallBodies_GoPlain` (Rpg.Client unit test over a fake handler) |
| U8 | Compression changes what the endpoint sees | It must not: every existing API test runs with the client's default (compression on), so the whole suite is the proof | the existing `Rpg.GameServerApi.Tests` and e2e scenarios, unchanged |
| U9 | A gzip body (another client) | Accepted, like Brotli | `Upload_Gzip_StillAccepted` |
| U10 | A plain body over the new 64 KB limit on a small endpoint | 413 (today accepted up to 30 MB) | `Upload_PlainOverTheSmallLimit_Is413` |
| D1 | (Design check) the decompression middleware enforces the body size limit on the decompressed bytes on .NET 10 | Not relied on: the bounded read (`ReadBoundedAsync`) enforces the limit whatever the framework does (the spec's fallback, made the design) | U2 (also reads the bomb through the bounded read and counts exactly limit + 1 inflated bytes) |
| U11 | Over the rate limit with a compressed bomb | 429 before anything is inflated; one token per request (the endpoint filter takes none when the gate took it). Side effect, accepted: a body later refused (400, 413) has spent its token, so a client sending broken bodies is throttled too | `Upload_RateLimitedBeforeTheBodyIsInflated`, and `RateLimit_Exceeded_Returns429` (one token per request) |
| U12 | An anonymous compressed bomb | 401 before anything is inflated (authentication runs before the upload pipeline) | `Upload_Anonymous_Is401_BeforeAnythingIsInflated` |

Acceptance failure scenarios (root `CLAUDE.md`): none directly. Scenario 7 (load spike: backpressure visible in Grafana)
gains the upload sizes as a signal; the load test (slice 8) shows them before and after.

## 5. Observability

- `rpg_upload_wire_bytes` (histogram, bytes on the wire, counted as read: a body without a `Content-Length` is chunked): labels `route` (`actions`, `end`, `other`) and `encoding`
  (`br`, `gzip`, `identity`, `other`). Buckets 256 B to 8 MB, powers of 4.
- `rpg_upload_body_bytes` (histogram, decompressed bytes the endpoint read): the same labels and buckets (plus 8 MB, the log
  limit). Both are recorded for every body read in full, before the endpoint runs, so a 409 retry, a domain 400 or a 503 is
  counted too; a refused body and a request to an unknown route are not. With the one above,
  Grafana shows the compression ratio per route, and how close real batches come to the limit.
- `rpg_upload_refused_total` (counter): label `reason` (`unsupported_encoding`, `bad_body`, `too_large`).
- Panel 16 "Upload size by encoding" on the "Run verification" dashboard: wire and body bytes per second by route and
  encoding, and the compression ratio per route for Brotli bodies on a right axis (plain bodies would pull it towards 1).

No ids as labels. The client logs nothing new.

## 6. Test plan

- **`Rpg.Client` unit tests** (new `GameServerClientCompressionTests` in `tests/Rpg.GameServerApi.Tests/UploadCompressionTests.cs`,
  as there is no Rpg.Client test project; no Docker; over a recording `HttpMessageHandler`): a body above
  the threshold goes as Brotli with `Content-Encoding: br` and decompresses to the exact JSON `JsonContent` would have sent;
  a small body goes plain; `Enabled = false` sends plain; the bearer token and the content type are unchanged.
- **`Rpg.GameServerApi.Tests`** (Testcontainers, real Postgres and Redis): U1 to U6, U9, U10 and D1 as listed; the metrics
  present with the right labels after one compressed and one plain upload.
- **The whole .NET suite** runs with compression on by default (U8): every action, end, card and admin test now goes
  through decompression.
- **Godot:** `test_server_mode`'s fake bridge gains `SetCompression`; `test_e2e_tools` tests `server compression [on|off]`
  (`test_server_compression_command`, `test_server_compression_command_needs_server_mode`); `test_export_preset` keeps
  `SetCompression` out of the player build.
- **e2e:** every scenario runs compressed by default. `full_run.metrics` gains a line checking
  `rpg_upload_wire_bytes_count{route="actions",encoding="br"}` is above 0. One new scenario `upload_plain` runs a whole run
  with `server compression off` (an old client) and checks `encoding="identity"` instead. The `.metrics` format only matches
  lines that are present, so it cannot prove that no Brotli batch went; `GameServerClientCompressionTests` prove the switch.
- **Measured once, recorded in the spec after implementation:** the ratio per route on a real smart run of The Descent (from
  the two histograms), against the table in section 1. **So far (2026-11-22, the exported dev build against the dev stack, one
  floor of the demo's one-floor run):** actions 68,980 → 4,980 bytes (13.9x, two short batches), end 5,638 → 1,433 (3.9x). Short
  batches compress less than the 50-action batches of section 1; the Descent measurement is still to do. The exported player
  build ships `System.IO.Compression.Native.dll`.

## 7. Decisions, open questions, what stays out

**Decided with the user (2026-11-22):**
1. Brotli at `CompressionLevel.Optimal`, bodies of 1 KB and up, on by default (measured in section 1: 47x on real batches,
   0.36 ms to compress). The server also accepts gzip and plain bodies.
2. Per-endpoint limits on the decompressed body: 8 MB for the actions and end endpoints, 64 KB for every other one. Plain
   bodies get the same limits (down from Kestrel's 30 MB).
3. No new error codes: standard statuses (415, 400, 413) with plain ProblemDetails.
4. Responses stay uncompressed: there is no measured need (downloads are rare), and response compression needs a BREACH
   review. The load test shows whether downloads matter; a small follow-up then.
5. The dev console can turn compression off; the player cannot.

**Open:** none.

**Stays out:**
- Compressing responses (decision 4).
- Fewer checkpoints and deltas (section 1).
- Storage and retention (7b).
- The verifier worker's own traffic (it reads Postgres, not HTTP).
- Trailing bytes after a valid compressed stream: ignored. A few KB lands in the decoder's read buffer (counted on the wire),
  anything longer is drained by Kestrel uncounted; the endpoint reads the right JSON. Refusing them would need a hand-written
  decoder loop instead of ASP.NET Core's middleware.
