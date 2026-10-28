using System;
using System.Text.Json;
using System.Threading.Tasks;
using Godot;
using Rpg.Client;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;

namespace rpgDemo.Net;

/// <summary>
/// The one adapter between GDScript and the server (spec server-authority 3.7, client-godot CLAUDE.md section 1).
/// Wraps <see cref="GameServerClient"/>; every method takes and returns whole Rpg.Contracts records as JSON strings,
/// returns a request id at once, and completes later through the <c>Completed</c> signal on the main thread.
/// No game logic, no retries (ServerLink decides those).
/// <para>Completed(requestId, ok, json): ok → the response record's JSON ("null" for a 204); not ok →
/// <c>{"status": int (0 = no response), "errorCode": int|null, "title": string, "detail": string,
/// "retryAfterSeconds": number|null}</c>.</para>
/// </summary>
public partial class ServerBridge : Node
{
    [Signal]
    public delegate void CompletedEventHandler(long requestId, bool ok, string json);

    private GameServerClient? _client;
    private long _nextRequest;

    /// <summary>
    /// Points the bridge at a server. <paramref name="devPlayer"/>: Part A's X-Dev-Player name ("" for none).
    /// </summary>
    public void Configure(string baseUrl, string devPlayer, double timeoutSeconds)
    {
        var http = new System.Net.Http.HttpClient
        {
            BaseAddress = new Uri(baseUrl.EndsWith('/') ? baseUrl : baseUrl + "/"),
            Timeout = TimeSpan.FromSeconds(timeoutSeconds),
        };
        _client = new GameServerClient(http, devPlayer.Length > 0 ? devPlayer : null);
    }

    /// <summary>POST /api/v1/runs with a RunStartRequest; completes with a RunStartResponse.</summary>
    public long StartRun(string requestJson) =>
        Start(client => client.StartRunAsync(Parse<RunStartRequest>(requestJson)));

    /// <summary>POST /api/v1/runs/{runId}/floors/{floor} with a FloorSeedRequest; completes with a FloorSeedResponse.</summary>
    public long GetFloorSeed(string runId, int floor, string requestJson) =>
        Start(client => client.GetFloorSeedAsync(runId, floor, Parse<FloorSeedRequest>(requestJson)));

    /// <summary>GET /api/v1/runs/{runId}; completes with a RunSummaryResponse.</summary>
    public long GetRun(string runId) => Start(client => client.GetRunAsync(runId));

    /// <summary>GET /api/v1/runs/current; completes with a RunSummaryResponse or "null" (no active run).</summary>
    public long GetCurrentRun() => Start(client => client.GetCurrentRunAsync());

    private long Start<T>(Func<GameServerClient, Task<T>> call)
    {
        var id = ++_nextRequest;
        _ = RunAsync(id, call);
        return id;
    }

    private async Task RunAsync<T>(long id, Func<GameServerClient, Task<T>> call)
    {
        bool ok;
        string json;
        try
        {
            var client = _client ?? throw new InvalidOperationException("ServerBridge.Configure was not called.");
            json = JsonSerializer.Serialize(await call(client), RpgJson.Options);
            ok = true;
        }
        catch (GameServerApiException ex)
        {
            ok = false;
            json = Error((int)ex.StatusCode, ex.ErrorCode, ex.Problem?.Title ?? ex.Message, ex.Problem?.Detail ?? "",
                ex.RetryAfter?.TotalSeconds);
        }
        catch (Exception ex)
        {
            // No response at all: network down, timeout, refused connection, unreadable body.
            ok = false;
            json = Error(0, null, ex.GetType().Name, ex.Message, null);
        }

        Callable.From(() => EmitSignal(SignalName.Completed, id, ok, json)).CallDeferred();
    }

    private static T Parse<T>(string json) =>
        JsonSerializer.Deserialize<T>(json, RpgJson.Options)
        ?? throw new ArgumentException($"Expected a {typeof(T).Name} JSON object.");

    private static string Error(int status, int? errorCode, string title, string detail, double? retryAfterSeconds) =>
        JsonSerializer.Serialize(new { status, errorCode, title, detail, retryAfterSeconds }, RpgJson.Options);
}
