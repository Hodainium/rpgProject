using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using Npgsql;
using Rpg.Client;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Auth;
using Rpg.Contracts.Runs;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Runs;
using Rpg.GameServerApi.Tests.Infrastructure;
using StackExchange.Redis;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Spec server-authority Part A, section 4 (failure modes) and 6 (server and client tests): runs, floor seeds, the
/// run read model and its Redis cache (scenario 4), through the real Rpg.Client against the real server with dev
/// tokens. Every test gets a database of its own. No actions are uploaded here, so the stairs go after seq 0.
/// </summary>
[Collection(StackCollection.Name)]
public class RunTests(StackFixture stack)
{
    private static readonly RunStartRequest Start =
        new(ApiFactory.TestRuleset, "descent", ["warrior", "cleric", "ranger"]);

    /// <summary>The stairs with nothing uploaded: Part B's gate wants the last stored seq, 0.</summary>
    private static readonly FloorSeedRequest Stairs = new(0);

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task StartRun_CreatesActiveRun_WithFloorZeroSeedFromHmac()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");

        var started = await client.StartRunAsync(Start, Ct);
        var summary = await client.GetRunAsync(started.RunId, Ct);

        Assert.Equal(0, started.Floor);
        Assert.Equal(Seeds(factory).Derive(Guid.Parse(started.RunId), 0).ToString(), started.FloorSeed);
        Assert.Equal(RunStatus.Active, summary.Status);
        Assert.Equal(0, summary.CurrentFloor);
        Assert.Equal(0, summary.LastSeq);
        Assert.Equal(ApiFactory.TestRuleset, summary.RulesetVersion);
        Assert.Null(summary.EndedAt);
    }

    [Fact]
    public async Task StartRun_AbandonsPrevious()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");

        var first = await client.StartRunAsync(Start, Ct);
        var firstBefore = await client.GetRunAsync(first.RunId, Ct);  // cached, so the start must delete it
        var second = await client.StartRunAsync(Start, Ct);

        var firstAfter = await client.GetRunAsync(first.RunId, Ct);
        var current = await client.GetCurrentRunAsync(Ct);
        Assert.Equal(RunStatus.Active, firstBefore.Status);
        Assert.Equal(RunStatus.Abandoned, firstAfter.Status);
        Assert.NotNull(firstAfter.EndedAt);
        Assert.Equal(second.RunId, current?.RunId);
        Assert.NotEqual(first.FloorSeed, second.FloorSeed);
    }

    [Fact]
    public async Task StartRun_UnknownRuleset_Rejected()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");

        var ex = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.StartRunAsync(Start with { RulesetVersion = "4.7.2.stable.mono+ffffffffffffffff" }, Ct));

        Assert.Equal(HttpStatusCode.Conflict, ex.StatusCode);
        Assert.Equal(ApiErrors.RulesetMismatch, ex.ErrorCode);
        Assert.Null(await client.GetCurrentRunAsync(Ct));
    }

    [Fact]
    public async Task StartRun_InvalidBody_Returns400()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");

        var noParty = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.StartRunAsync(Start with { CharacterIds = [] }, Ct));
        var http = factory.CreateClient();
        http.DefaultRequestHeaders.Authorization = new("Bearer", client.AccessToken);
        var malformed = await http.PostAsync("/api/v1/runs",
            new StringContent("{not json", System.Text.Encoding.UTF8, "application/json"), Ct);

        Assert.Equal(HttpStatusCode.BadRequest, noParty.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, malformed.StatusCode);
    }

    [Fact]
    public async Task FloorSeed_NextFloor_IssuedAndBecomesCurrent()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);

        var floor1 = await client.GetFloorSeedAsync(run.RunId, 1, Stairs, Ct);
        var floor2 = await client.GetFloorSeedAsync(run.RunId, 2, Stairs, Ct);

        Assert.Equal(Seeds(factory).Derive(Guid.Parse(run.RunId), 1).ToString(), floor1.FloorSeed);
        Assert.NotEqual(floor1.FloorSeed, floor2.FloorSeed);
        Assert.Equal(2, (await client.GetRunAsync(run.RunId, Ct)).CurrentFloor);
    }

    [Fact]
    public async Task FloorSeed_Retry_ReturnsSameSeed()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);

        var first = await client.GetFloorSeedAsync(run.RunId, 1, Stairs, Ct);
        var retry = await client.GetFloorSeedAsync(run.RunId, 1, Stairs, Ct);

        Assert.Equal(first, retry);
        Assert.Equal(1, (await client.GetRunAsync(run.RunId, Ct)).CurrentFloor);
        Assert.Equal(2L, await ScalarAsync(factory, $"SELECT count(*) FROM run_floors WHERE run_id = '{run.RunId}'"));
    }

    [Fact]
    public async Task FloorSeed_NotNextFloor_Rejected()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);

        var skip = await Assert.ThrowsAsync<GameServerApiException>(() => client.GetFloorSeedAsync(run.RunId, 2, Stairs, Ct));
        await client.GetFloorSeedAsync(run.RunId, 1, Stairs, Ct);
        var back = await Assert.ThrowsAsync<GameServerApiException>(() => client.GetFloorSeedAsync(run.RunId, 0, Stairs, Ct));

        Assert.Equal(ApiErrors.FloorNotReachable, skip.ErrorCode);
        Assert.Equal(ApiErrors.FloorNotReachable, back.ErrorCode);
        Assert.Equal(HttpStatusCode.Conflict, back.StatusCode);
        Assert.Equal(1, (await client.GetRunAsync(run.RunId, Ct)).CurrentFloor);
    }

    [Fact]
    public async Task FloorSeed_EndedRun_Rejected()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var abandoned = await client.StartRunAsync(Start, Ct);
        await client.StartRunAsync(Start, Ct);

        var ex = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.GetFloorSeedAsync(abandoned.RunId, 1, Stairs, Ct));

        Assert.Equal(ApiErrors.RunNotActive, ex.ErrorCode);
    }

    [Fact]
    public async Task Runs_OtherPlayer_NotFound()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var alice = await ClientAsync(factory, "alice");
        var bob = await ClientAsync(factory, "bob");
        var run = await alice.StartRunAsync(Start, Ct);
        await alice.GetRunAsync(run.RunId, Ct);  // cached: the cached copy must not leak either

        var read = await Assert.ThrowsAsync<GameServerApiException>(() => bob.GetRunAsync(run.RunId, Ct));
        var stairs = await Assert.ThrowsAsync<GameServerApiException>(() => bob.GetFloorSeedAsync(run.RunId, 1, Stairs, Ct));
        var missing = await Assert.ThrowsAsync<GameServerApiException>(() =>
            bob.GetRunAsync(Guid.NewGuid().ToString(), Ct));

        Assert.Equal(HttpStatusCode.NotFound, read.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, stairs.StatusCode);
        Assert.Equal(read.Problem?.Title, missing.Problem?.Title);
        Assert.Null(await bob.GetCurrentRunAsync(Ct));
    }

    [Fact]
    public async Task Endpoints_RequireAuth()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var alice = await ClientAsync(factory, "alice");
        var run = await alice.StartRunAsync(Start, Ct);
        var forged = new DevTokenIssuer(Microsoft.Extensions.Options.Options.Create(new AuthOptions
        {
            SigningKey = "another-signing-key-that-is-long-enough",
        }), TimeProvider.System).Issue("alice").AccessToken;

        foreach (var token in new string?[] { null, "not-a-token", forged })
        {
            var client = new GameServerClient(factory.CreateClient(), token);
            Func<Task>[] calls =
            [
                () => client.StartRunAsync(Start, Ct),
                () => client.GetFloorSeedAsync(run.RunId, 1, Stairs, Ct),
                () => client.GetRunAsync(run.RunId, Ct),
                () => client.GetCurrentRunAsync(Ct),
                () => client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(1)), Ct),
                () => client.EndRunAsync(run.RunId, RunLog.End(1, RunEndStatus.Lost), Ct),
                () => client.ResumeAsync(run.RunId, Ct),
                () => client.GetBattleAsync(run.RunId, 1, Ct),
                () => client.HeartbeatAsync(new Rpg.Contracts.Presence.PresenceRequest(
                    Rpg.Contracts.Presence.PresenceActivity.Map), Ct),
            ];
            foreach (var call in calls)
            {
                var ex = await Assert.ThrowsAsync<GameServerApiException>(call);
                Assert.Equal(HttpStatusCode.Unauthorized, ex.StatusCode);
            }
        }

        Assert.Equal(0, (await alice.GetRunAsync(run.RunId, Ct)).LastSeq);
    }

    [Fact]
    public async Task DevToken_IdIsStablePerName_AndBadNamesAre400()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = new GameServerClient(factory.CreateClient());

        var first = await client.GetDevTokenAsync(new DevTokenRequest("alice"), Ct);
        var again = await client.GetDevTokenAsync(new DevTokenRequest("alice"), Ct);
        var bad = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.GetDevTokenAsync(new DevTokenRequest("no spaces"), Ct));

        Assert.Equal(first.PlayerId, again.PlayerId);
        Assert.Equal(DevTokenIssuer.IdOf("alice").ToString("D"), first.PlayerId);
        Assert.True(first.ExpiresAt > DateTimeOffset.UtcNow);
        Assert.Equal(HttpStatusCode.BadRequest, bad.StatusCode);
    }

    [Fact]
    public async Task Cache_WriteDeletesKey_NextReadIsFresh()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        var redis = await RedisAsync();
        var key = RunSummaryCache.SummaryKey(Guid.Parse(run.RunId));

        await client.GetRunAsync(run.RunId, Ct);
        var filled = await redis.GetDatabase().KeyExistsAsync(key);
        await client.GetFloorSeedAsync(run.RunId, 1, Stairs, Ct);
        var afterWrite = await redis.GetDatabase().KeyExistsAsync(key);
        var fresh = await client.GetRunAsync(run.RunId, Ct);

        Assert.True(filled, "a read fills the cache");
        Assert.False(afterWrite, "a write deletes the key, never sets it");
        Assert.Equal(1, fresh.CurrentFloor);
        Assert.True(await redis.GetDatabase().KeyExistsAsync(key), "the next read re-fills it");
        Assert.InRange((await redis.GetDatabase().KeyTimeToLiveAsync(key))!.Value, TimeSpan.FromMinutes(29),
            RunSummaryCache.Ttl);
    }

    [Fact]
    public async Task RedisFlushed_ReadFallsBackToPostgres()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.GetFloorSeedAsync(run.RunId, 1, Stairs, Ct);
        var before = await client.GetRunAsync(run.RunId, Ct);
        var current = await client.GetCurrentRunAsync(Ct);
        var redis = await RedisAsync();

        await redis.GetServers().Single().FlushDatabaseAsync();

        Assert.Equal(before, await client.GetRunAsync(run.RunId, Ct));
        Assert.Equal(current, await client.GetCurrentRunAsync(Ct));
        Assert.True(await redis.GetDatabase().KeyExistsAsync(RunSummaryCache.SummaryKey(Guid.Parse(run.RunId))));
    }

    [Fact]
    public async Task RedisDown_WritesStillSucceed()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, redis: StackFixture.Unreachable.Redis);
        var client = await ClientAsync(factory, "alice");

        var first = await client.StartRunAsync(Start, Ct);
        var second = await client.StartRunAsync(Start, Ct);
        var floor = await client.GetFloorSeedAsync(second.RunId, 1, Stairs, Ct);

        Assert.Equal(RunStatus.Abandoned, (await client.GetRunAsync(first.RunId, Ct)).Status);
        Assert.Equal(1, (await client.GetCurrentRunAsync(Ct))?.CurrentFloor);
        Assert.Equal(1, floor.Floor);
        var metrics = await factory.CreateClient().GetStringAsync("/metrics", Ct);
        Assert.Contains("rpg_cache_errors_total{", metrics);
    }

    [Fact]
    public async Task StartRun_PostgresDown_Returns503()
    {
        await using var factory = new ApiFactory(StackFixture.Unreachable.Postgres, stack.RedisConnectionString,
            stack.RabbitMqUri, "Development");
        var http = factory.CreateClient();
        http.DefaultRequestHeaders.Authorization = new("Bearer", Token(factory, "alice"));

        using var response = await http.PostAsJsonAsync("/api/v1/runs", Start, Ct);

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
    }

    [Fact]
    public async Task DevConveniences_OffOutsideDevelopment()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, environment: "Production",
            settings: new Dictionary<string, string?>
            {
                ["Ruleset:AcceptAny"] = "true",
                ["Auth:DevTokens"] = "true",
                ["Run:AutoApproveWins"] = "true",
            });

        // No dev tokens outside Development, whatever Auth:DevTokens says.
        var noToken = await Assert.ThrowsAsync<GameServerApiException>(() =>
            new GameServerClient(factory.CreateClient()).GetDevTokenAsync(new DevTokenRequest("alice"), Ct));
        Assert.Equal(HttpStatusCode.NotFound, noToken.StatusCode);

        // A properly signed token still works: bearer auth itself isn't a development convenience.
        var client = new GameServerClient(factory.CreateClient(), Token(factory, "alice"));

        // AcceptAny is set, but outside Development only the Accepted list counts.
        var refused = await Assert.ThrowsAsync<GameServerApiException>(() =>
            client.StartRunAsync(Start with { RulesetVersion = "anything" }, Ct));
        Assert.Equal(ApiErrors.RulesetMismatch, refused.ErrorCode);
        var ruleset = factory.Services.GetRequiredService<RulesetPolicy>();
        Assert.False(ruleset.Accepts("anything"));
        Assert.True(ruleset.Accepts(ApiFactory.TestRuleset));

        // AutoApproveWins is set, but a won run still waits for its verdict.
        var run = await client.StartRunAsync(Start, Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(1)), Ct);
        var end = await client.EndRunAsync(run.RunId, RunLog.End(2, RunEndStatus.Won), Ct);
        Assert.Equal(RunStatus.Verifying, end.Status);
    }

    [Fact]
    public async Task Metrics_CountRunStartsAndFloorSeeds()
    {
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);
        await client.StartRunAsync(Start, Ct);
        await client.GetFloorSeedAsync(run.RunId, 1, Stairs, Ct).ContinueWith(_ => { }, Ct);  // ended: not counted
        var live = await client.StartRunAsync(Start, Ct);
        await client.GetFloorSeedAsync(live.RunId, 1, Stairs, Ct);
        await client.GetFloorSeedAsync(live.RunId, 1, Stairs, Ct);
        await client.GetFloorSeedAsync(live.RunId, 3, Stairs, Ct).ContinueWith(_ => { }, Ct);

        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_runs_in_progress"));

        Assert.Equal("1", Sample(metrics, "rpg_run_starts_total", "result=\"created\""));
        Assert.Equal("2", Sample(metrics, "rpg_run_starts_total", "result=\"abandoned_previous\""));
        Assert.Equal("1", Sample(metrics, "rpg_floor_seeds_total", "result=\"issued\""));
        Assert.Equal("1", Sample(metrics, "rpg_floor_seeds_total", "result=\"repeated\""));
        Assert.Equal("1", Sample(metrics, "rpg_floor_seeds_total", "result=\"not_reachable\""));
    }

    /// <summary>The value of the series <paramref name="name"/> carrying <paramref name="label"/> (other labels, such as
    /// the exporter's scope labels, may sit beside it), or null.</summary>
    internal static string? Sample(string metrics, string name, string label) =>
        metrics.Split('\n')
            .Where(line => line.StartsWith(name + "{", StringComparison.Ordinal) && line.Contains(label))
            .Select(line => line[(line.LastIndexOf('}') + 1)..].Trim().Split(' ')[0])
            .FirstOrDefault();

    [Fact]
    public async Task Traces_IncludeRedisAndNpgsqlSpans()
    {
        var sources = new System.Collections.Concurrent.ConcurrentDictionary<string, bool>();
        using var listener = new ActivityListener
        {
            ShouldListenTo = source => source.Name.Contains("StackExchangeRedis") || source.Name == "Npgsql",
            Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllData,
            ActivityStopped = activity => sources[activity.Source.Name] = true,
        };
        ActivitySource.AddActivityListener(listener);
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);

        // Redis commands are drained from the profiling session on an interval: keep reading until a span shows.
        var deadline = Stopwatch.StartNew();
        while (!sources.Keys.Any(name => name.Contains("StackExchangeRedis")) && deadline.Elapsed < TimeSpan.FromSeconds(20))
        {
            await client.GetRunAsync(run.RunId, Ct);
            await Task.Delay(500, Ct);
        }

        Assert.Contains(sources.Keys, name => name.Contains("StackExchangeRedis"));
        Assert.Contains("Npgsql", sources.Keys);
    }

    /// <summary>A client holding a dev token for <paramref name="player"/>, fetched through the real endpoint.</summary>
    internal static async Task<GameServerClient> ClientAsync(ApiFactory factory, string player)
    {
        var client = new GameServerClient(factory.CreateClient());
        client.AccessToken = (await client.GetDevTokenAsync(new DevTokenRequest(player), Ct)).AccessToken;
        return client;
    }

    /// <summary>A token signed by the server's own issuer (works in any environment).</summary>
    internal static string Token(ApiFactory factory, string player) =>
        factory.Services.GetRequiredService<DevTokenIssuer>().Issue(player).AccessToken;

    private static FloorSeeds Seeds(ApiFactory factory) =>
        new(factory.Services.GetRequiredService<IOptions<SeedOptions>>());

    internal static async Task<long> ScalarAsync(ApiFactory factory, string sql)
    {
        await using var command = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(sql);
        return (long)(await command.ExecuteScalarAsync(Ct))!;
    }

    private async Task<ConnectionMultiplexer> RedisAsync() =>
        await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString + ",allowAdmin=true");

    /// <summary>Gauges appear after their first observation, counters after the first scrape; poll briefly.</summary>
    internal static async Task<string> PollMetricsAsync(ApiFactory factory, Func<string, bool> ready)
    {
        var http = factory.CreateClient();
        var deadline = Stopwatch.StartNew();
        string text;
        do
        {
            text = await http.GetStringAsync("/metrics", Ct);
            if (ready(text))
            {
                break;
            }

            await Task.Delay(250, Ct);
        } while (deadline.Elapsed < TimeSpan.FromSeconds(15));

        return text;
    }
}
