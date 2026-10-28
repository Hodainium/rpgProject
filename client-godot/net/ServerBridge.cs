using System;
using System.Text.Json;
using System.Threading.Tasks;
using Godot;
using Rpg.Client;
using Rpg.Contracts.Auth;
using Rpg.Contracts.Presence;
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
/// "retryAfterSeconds": number|null, "expectedSeq": int|null (1102), "lastSeq": int|null (1103, 1106)}</c>.</para>
/// </summary>
public partial class ServerBridge : Node
{
    [Signal]
    public delegate void CompletedEventHandler(long requestId, bool ok, string json);

    private GameServerClient? _client;
    private long _nextRequest;

    /// <summary>Points the bridge at a server, with no token yet (<see cref="SetToken"/>).</summary>
    public void Configure(string baseUrl, double timeoutSeconds)
    {
        var http = new System.Net.Http.HttpClient
        {
            BaseAddress = new Uri(baseUrl.EndsWith('/') ? baseUrl : baseUrl + "/"),
            Timeout = TimeSpan.FromSeconds(timeoutSeconds),
        };
        _client = new GameServerClient(http);
    }

    /// <summary>The bearer token sent from now on ("" for none).</summary>
    public void SetToken(string accessToken)
    {
        if (_client is not null)
        {
            _client.AccessToken = accessToken.Length > 0 ? accessToken : null;
        }
    }

    /// <summary>POST /api/v1/auth/dev-token with a DevTokenRequest; completes with a DevTokenResponse.</summary>
    public long GetDevToken(string requestJson) =>
        Start(client => client.GetDevTokenAsync(Parse<DevTokenRequest>(requestJson)));

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

    /// <summary>POST /api/v1/runs/{runId}/actions with a RunActionBatch; completes with a RunActionAck.</summary>
    public long SendActions(string runId, string batchJson) =>
        Start(client => client.SendActionsAsync(runId, Parse<RunActionBatch>(batchJson)));

    /// <summary>POST /api/v1/runs/{runId}/end with a RunEndRequest; completes with a RunEndResponse.</summary>
    public long EndRun(string runId, string requestJson) =>
        Start(client => client.EndRunAsync(runId, Parse<RunEndRequest>(requestJson)));

    /// <summary>GET /api/v1/runs/{runId}/resume; completes with a RunResumeResponse.</summary>
    public long Resume(string runId) => Start(client => client.ResumeAsync(runId));

    /// <summary>GET /api/v1/runs/{runId}/battles/{seq}; completes with a BattleSessionResponse.</summary>
    public long GetBattle(string runId, int seq) => Start(client => client.GetBattleAsync(runId, seq));

    /// <summary>POST /api/v1/presence with a PresenceRequest; completes with "null" (204).</summary>
    public long Heartbeat(string requestJson) =>
        Start<object?>(async client =>
        {
            await client.HeartbeatAsync(Parse<PresenceRequest>(requestJson));
            return null;
        });

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
                ex.RetryAfter?.TotalSeconds, ex.Problem?.ExpectedSeq, ex.Problem?.LastSeq);
        }
        catch (Exception ex)
        {
            // No response at all: network down, timeout, refused connection, unreadable body.
            ok = false;
            json = Error(0, null, ex.GetType().Name, ex.Message, null, null, null);
        }

        // The game may be quitting (a heartbeat still in flight): a disposed bridge has no one to tell.
        Callable.From(() =>
        {
            if (IsInstanceValid(this))
            {
                EmitSignal(SignalName.Completed, id, ok, json);
            }
        }).CallDeferred();
    }

    private static T Parse<T>(string json) =>
        JsonSerializer.Deserialize<T>(json, RpgJson.Options)
        ?? throw new ArgumentException($"Expected a {typeof(T).Name} JSON object.");

    private static string Error(int status, int? errorCode, string title, string detail, double? retryAfterSeconds,
        int? expectedSeq, int? lastSeq) =>
        JsonSerializer.Serialize(new { status, errorCode, title, detail, retryAfterSeconds, expectedSeq, lastSeq },
            RpgJson.Options);
}
