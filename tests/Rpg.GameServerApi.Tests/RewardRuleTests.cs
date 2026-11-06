using System.Diagnostics;
using System.Net;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using Npgsql;
using Rpg.Client;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Economy;
using Rpg.Contracts.Events;
using Rpg.Contracts.Serialization;
using Rpg.Economy;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Tests.Infrastructure;
using Rpg.Verification;
using static Rpg.GameServerApi.Tests.RunTests;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Spec economy-rewards (slice 4c): the reward-rule table and its admin path (F4–F6, F8, F9), the lookup the worker
/// uses, and trace continuity through the outbox (3.8, F11).
/// </summary>
[Collection(StackCollection.Name)]
public class RewardRuleTests(StackFixture stack)
{
    private static readonly Dictionary<string, string?> Admin = new()
    {
        ["Outbox:Enabled"] = "false",
        ["Monitors:Interval"] = "01:00:00",
        ["Auth:DevAdmins:0"] = "designer",
    };

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static RewardRuleRequest Lich(int amount) => new("boss/enemy.lich", "gems", amount);

    [Fact]
    public async Task APut_CreatesConsecutiveVersions_AndTheListShowsTheLatest()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");

        var first = await admin.PutRewardRuleAsync(Lich(10), Ct);
        var second = await admin.PutRewardRuleAsync(Lich(25), Ct);
        await admin.PutRewardRuleAsync(new("boss/enemy.golem", "gems", 5), Ct);
        var list = await admin.ListRewardRulesAsync(Ct);

        Assert.Equal((1, 10, "designer"), (first.Version, first.Amount, first.CreatedBy));
        Assert.Equal((2, 25, 0), (second.Version, second.Amount, second.Generation));
        Assert.Equal(["boss/enemy.golem:1:5", "boss/enemy.lich:2:25"], list.Rules.Select(r => $"{r.ChallengeId}:{r.Version}:{r.Amount}"));
        Assert.Equal(3L, await ScalarAsync(factory, "SELECT count(*) FROM reward_rules"));  // append-only
    }

    [Fact]
    public async Task AWeeklyRule_StoresItsCycleAndEnd()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        var ends = DateTimeOffset.UtcNow.AddDays(30);

        var put = await admin.PutRewardRuleAsync(new("demo.challenge.lich_trial.fast", "gems", 10, RewardCycles.Weekly, ends), Ct);
        var list = await admin.ListRewardRulesAsync(Ct);

        Assert.Equal((10, RewardCycles.Weekly), (put.Amount, put.Cycle));
        Assert.Equal(ends.ToUnixTimeMilliseconds(), put.EndsAt!.Value.ToUnixTimeMilliseconds());
        Assert.Equal((10, RewardCycles.Weekly), (list.Rules.Single().Amount, list.Rules.Single().Cycle));
        Assert.Equal(ends.ToUnixTimeMilliseconds(), list.Rules.Single().EndsAt!.Value.ToUnixTimeMilliseconds());
    }

    [Fact]
    public async Task APut_WritesRewardRuleChanged_WithThePreviousAmount_InTheSameTransaction()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");

        await admin.PutRewardRuleAsync(Lich(10), Ct);
        await admin.PutRewardRuleAsync(Lich(25), Ct);

        var payloads = await TextsAsync(factory, "SELECT payload::text FROM outbox WHERE type = 'RewardRuleChanged' ORDER BY seq");
        var events = payloads.Select(p => System.Text.Json.JsonSerializer
            .Deserialize<DomainEvent<RewardRuleChangedPayload>>(p, RpgJson.Options)!).ToList();
        Assert.Equal([(1, (int?)null, 10), (2, 10, 25)], events.Select(e => (e.Payload.Version, e.Payload.PreviousAmount, e.Payload.Amount)));
        Assert.All(events, e => Assert.Equal("designer", e.Payload.ChangedBy));
        Assert.Equal(["rule:boss/enemy.lich"], await TextsAsync(factory, "SELECT DISTINCT key FROM outbox"));
        Assert.Equal([EventTopics.Economy], await TextsAsync(factory, "SELECT DISTINCT topic FROM outbox"));
        Assert.Equal(["redpanda"], await TextsAsync(factory, "SELECT DISTINCT destination FROM outbox"));
    }

    [Fact]
    public async Task RetiringARule_IsAPutWithAmountZero()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        await admin.PutRewardRuleAsync(Lich(10), Ct);

        var retired = await admin.PutRewardRuleAsync(Lich(0), Ct);

        Assert.Equal((2, 0), (retired.Version, retired.Amount));
    }

    [Fact]
    public async Task APutWithoutAnAmount_IsRefused_NotTreatedAsRetire()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        using var request = new HttpRequestMessage(HttpMethod.Put, "api/v1/admin/reward-rules")
        {
            Content = new StringContent("""{"challengeId":"boss/enemy.lich","currency":"gems"}""", System.Text.Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", admin.AccessToken);

        using var response = await factory.CreateClient().SendAsync(request, Ct);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal(0L, await ScalarAsync(factory, "SELECT count(*) FROM reward_rules"));
    }

    public static TheoryData<string, string, string, int, int> BadRules() => new()
    {
        { "boss/enemy.lich", "dust", "once", 10, 0 },     // unknown currency
        { "boss/enemy:lich", "gems", "once", 10, 0 },     // ':' in the id
        { "boss/enemy lich", "gems", "once", 10, 0 },     // whitespace
        { "", "gems", "once", 10, 0 },                    // empty id
        { "boss/enemy.lich", "gems", "daily", 10, 0 },    // unknown cycle
        { "boss/enemy.lich", "gems", "once", -1, 0 },
        { "boss/enemy.lich", "gems", "once", 100001, 0 }, // over the cap
        { "boss/enemy.lich", "gems", "once", 10, -1 },    // endsAt one day in the past
    };

    [Theory]
    [MemberData(nameof(BadRules))]
    public async Task InvalidRule_Is400_1301_AndNothingIsWritten(string id, string currency, string cycle, int amount, int endsInDays)  // C15
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        DateTimeOffset? ends = endsInDays == 0 ? null : DateTimeOffset.UtcNow.AddDays(endsInDays);

        var error = await Assert.ThrowsAsync<GameServerApiException>(
            () => admin.PutRewardRuleAsync(new RewardRuleRequest(id, currency, amount, cycle, ends), Ct));

        Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.RewardRuleInvalid), (error.StatusCode, error.ErrorCode));
        Assert.Equal(0L, await ScalarAsync(factory, "SELECT count(*) FROM reward_rules"));
        Assert.Equal(0L, await ScalarAsync(factory, "SELECT count(*) FROM outbox"));
    }

    [Fact]
    public async Task TheCap_IsConfigurable()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>(Admin)
        {
            ["Economy:MaxRewardAmount"] = "50",
        });
        var admin = await ClientAsync(factory, "designer");

        Assert.Equal(50, (await admin.PutRewardRuleAsync(Lich(50), Ct)).Amount);
        var error = await Assert.ThrowsAsync<GameServerApiException>(() => admin.PutRewardRuleAsync(Lich(51), Ct));
        Assert.Equal(ApiErrors.RewardRuleInvalid, error.ErrorCode);
    }

    [Fact]
    public async Task Admin_RequiresTheRole()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var player = await ClientAsync(factory, "alice");
        var anonymous = new GameServerClient(factory.CreateClient());
        var reset = new RewardCycleResetRequest("boss/enemy.lich");

        var put = await Assert.ThrowsAsync<GameServerApiException>(() => player.PutRewardRuleAsync(Lich(10), Ct));
        var list = await Assert.ThrowsAsync<GameServerApiException>(() => player.ListRewardRulesAsync(Ct));
        var resetDenied = await Assert.ThrowsAsync<GameServerApiException>(() => player.ResetRewardCycleAsync(reset, Ct));  // C19
        var noToken = await Assert.ThrowsAsync<GameServerApiException>(() => anonymous.PutRewardRuleAsync(Lich(10), Ct));
        var resetNoToken = await Assert.ThrowsAsync<GameServerApiException>(() => anonymous.ResetRewardCycleAsync(reset, Ct));

        Assert.Equal((HttpStatusCode.Forbidden, ApiErrors.AdminRequired), (put.StatusCode, put.ErrorCode));
        Assert.Equal((HttpStatusCode.Forbidden, ApiErrors.AdminRequired), (resetDenied.StatusCode, resetDenied.ErrorCode));
        Assert.Equal(HttpStatusCode.Forbidden, list.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, noToken.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, resetNoToken.StatusCode);
        Assert.Equal(0L, await ScalarAsync(factory, "SELECT count(*) FROM reward_rules"));
        Assert.Equal(0L, await ScalarAsync(factory, "SELECT count(*) FROM reward_cycle_resets"));
        Assert.Equal(0L, await ScalarAsync(factory, "SELECT count(*) FROM outbox"));
    }

    [Fact]
    public async Task DevAdmins_HasNoEffectOutsideDevelopment()
    {
        var options = Options.Create(new AuthOptions { SigningKey = ApiFactory.TestSigningKey, DevAdmins = ["designer"] });

        var production = new DevTokenIssuer(options, TimeProvider.System, new StubEnvironment(Environments.Production)).Issue("designer");
        var development = new DevTokenIssuer(options, TimeProvider.System, new StubEnvironment(Environments.Development)).Issue("designer");
        var other = new DevTokenIssuer(options, TimeProvider.System, new StubEnvironment(Environments.Development)).Issue("alice");

        Assert.False(HasRole(production.AccessToken));
        Assert.True(HasRole(development.AccessToken));
        Assert.False(HasRole(other.AccessToken));

        // And a real server outside Development refuses the dev-token endpoint, so no token with the role exists at all.
        await using var testing = await ApiFactory.RunsAsync(stack, environment: "Testing", settings: Admin);
        var error = await Assert.ThrowsAsync<GameServerApiException>(
            () => new GameServerClient(testing.CreateClient()).GetDevTokenAsync(new Rpg.Contracts.Auth.DevTokenRequest("designer"), Ct));
        Assert.Equal(HttpStatusCode.NotFound, error.StatusCode);

        static bool HasRole(string token) =>
            new Microsoft.IdentityModel.JsonWebTokens.JsonWebToken(token).Claims
                .Any(c => c.Type == "role" && c.Value == "economy-admin");
    }

    [Fact]
    public async Task ConcurrentPuts_ProduceConsecutiveVersions()  // C17
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");

        var responses = await Task.WhenAll(Enumerable.Range(1, 12).Select(n => admin.PutRewardRuleAsync(Lich(n), Ct)));

        Assert.Equal(Enumerable.Range(1, 12), responses.Select(r => r.Version).Order());
        Assert.Equal(12L, await ScalarAsync(factory, "SELECT count(DISTINCT version) FROM reward_rules"));
        Assert.Equal(12L, await ScalarAsync(factory, "SELECT max(version) FROM reward_rules"));
        // Each version's event names the amount before it.
        Assert.Equal(11L, await ScalarAsync(factory,
            "SELECT count(*) FROM outbox WHERE (payload->'payload'->>'previousAmount') IS NOT NULL"));
    }

    [Fact]
    public async Task RuleChange_AndItsEvent_AreOneTransaction()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        var data = factory.Services.GetRequiredService<NpgsqlDataSource>();
        await factory.Services.GetRequiredService<MigrationRunner>().EnsureMigratedAsync(Ct);

        // The caller's transaction rolls back after both writes: neither survives.
        await using (var connection = await data.OpenConnectionAsync(Ct))
        await using (var transaction = await connection.BeginTransactionAsync(Ct))
        {
            await RewardRules.InsertVersionAsync(connection, transaction, Lich(10), Guid.NewGuid(), "designer", DateTimeOffset.UtcNow, Ct);
            await transaction.RollbackAsync(Ct);
        }

        // The event write fails: the rule goes with it.
        await ExecuteAsync(factory, "ALTER TABLE outbox ADD CONSTRAINT no_rule_events CHECK (type <> 'RewardRuleChanged')");
        await Assert.ThrowsAnyAsync<Exception>(() => admin.PutRewardRuleAsync(Lich(10), Ct));

        Assert.Equal(0L, await ScalarAsync(factory, "SELECT count(*) FROM reward_rules"));
        Assert.Equal(0L, await ScalarAsync(factory, "SELECT count(*) FROM outbox"));
    }

    [Fact]
    public async Task SeedRules_FillOnlyChallengesWithoutARule_AndNeverOverwriteAnAdminRule()
    {
        var seeds = new Dictionary<string, string?>(Admin)
        {
            ["Economy:SeedRules:0:ChallengeId"] = "boss/enemy.lich", ["Economy:SeedRules:0:Currency"] = "gems",
            ["Economy:SeedRules:0:Amount"] = "10",
            ["Economy:SeedRules:1:ChallengeId"] = "demo.challenge.lich_trial.fast", ["Economy:SeedRules:1:Currency"] = "gems",
            ["Economy:SeedRules:1:Amount"] = "5", ["Economy:SeedRules:1:Cycle"] = "weekly",
        };
        await using var factory = await ApiFactory.RunsAsync(stack, settings: seeds);
        var admin = await ClientAsync(factory, "designer");
        await WaitAsync(async () => await ScalarAsync(factory, "SELECT count(*) FROM reward_rules") == 2);

        await admin.PutRewardRuleAsync(Lich(25), Ct);
        var options = factory.Services.GetRequiredService<IOptions<Rpg.GameServerApi.Economy.EconomyOptions>>().Value;
        var created = await RewardRules.SeedAsync(factory.Services.GetRequiredService<NpgsqlDataSource>(), options.SeedRules,  // a restart
            options.MaxRewardAmount, DateTimeOffset.UtcNow, Ct);

        Assert.Equal(0, created);  // F9
        var list = await admin.ListRewardRulesAsync(Ct);
        var lich = list.Rules.Single(r => r.ChallengeId == "boss/enemy.lich");
        var fast = list.Rules.Single(r => r.ChallengeId == "demo.challenge.lich_trial.fast");
        Assert.Equal((2, 25), (lich.Version, lich.Amount));
        Assert.Equal((1, 5, RewardCycles.Weekly), (fast.Version, fast.Amount, fast.Cycle));
        Assert.Equal("seed", (await TextsAsync(factory, "SELECT created_by FROM reward_rules WHERE challenge_id = 'demo.challenge.lich_trial.fast'")).Single());
    }

    [Fact]
    public async Task TheSchema_RefusesBadChallengeIds_AndTheLookupTakesTheLatestVersionInForce()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        await admin.PutRewardRuleAsync(Lich(10), Ct);
        await admin.PutRewardRuleAsync(Lich(25), Ct);
        await ExecuteAsync(factory,
            "INSERT INTO reward_rules (challenge_id, currency, amount, version, effective_from, created_by) VALUES ('boss/enemy.lich','gems',99,3, now() + interval '1 hour','t')");

        foreach (var id in new[] { "a:b", "a b", "a\tb", "" })
        {
            await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(factory,
                $"INSERT INTO reward_rules (challenge_id, currency, amount, version, created_by) VALUES ('{id}','gems',1,1,'t')"));
        }

        await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(factory,
            "INSERT INTO reward_rules (challenge_id, currency, amount, version, created_by) VALUES ('boss/enemy.lich','gems',1,2,'t')"));  // UNIQUE (challenge, version)
        var data = factory.Services.GetRequiredService<NpgsqlDataSource>();
        await using var connection = await data.OpenConnectionAsync(Ct);
        await using var transaction = await connection.BeginTransactionAsync(Ct);
        var rule = await RewardRules.LookupAsync(connection, transaction, "boss/enemy.lich", Ct);
        var none = await RewardRules.LookupAsync(connection, transaction, "boss/enemy.nobody", Ct);

        Assert.Equal((2, 25), (rule!.Version, rule.Amount));  // the version dated in the future is ignored
        Assert.Null(none);
    }

    // ---- Cycle resets (spec economy-challenges 2.2, C18-C20, C24) ----

    private static async Task<Guid> AddPlayerAsync(ApiFactory factory, string name)
    {
        var id = Guid.NewGuid();
        await ExecuteAsync(factory, $"INSERT INTO players (player_id, display_name, created_at) VALUES ('{id}', '{name}', now())");
        return id;
    }

    [Fact]
    public async Task AResetForEveryone_RaisesTheGlobalGeneration_ShowsInTheList_AndWritesItsEvent()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        await admin.PutRewardRuleAsync(Lich(10), Ct);

        var first = await admin.ResetRewardCycleAsync(new RewardCycleResetRequest("boss/enemy.lich", Reason: "run it again"), Ct);
        var second = await admin.ResetRewardCycleAsync(new RewardCycleResetRequest("boss/enemy.lich"), Ct);
        var list = await admin.ListRewardRulesAsync(Ct);

        Assert.Equal((1, (Guid?)null, "designer"), (first.Generation, first.PlayerId, first.ResetBy));
        Assert.Equal(2, second.Generation);
        Assert.Equal(2, list.Rules.Single().Generation);
        var events = (await TextsAsync(factory, "SELECT payload::text FROM outbox WHERE type = 'RewardCycleReset' ORDER BY seq"))
            .Select(p => System.Text.Json.JsonSerializer.Deserialize<DomainEvent<RewardCycleResetPayload>>(p, RpgJson.Options)!).ToList();
        Assert.Equal([1, 2], events.Select(e => e.Payload.Generation));
        Assert.Equal("run it again", events[0].Payload.Reason);
        Assert.Equal(["rule:boss/enemy.lich"], await TextsAsync(factory, "SELECT DISTINCT key FROM outbox WHERE type = 'RewardCycleReset'"));
        Assert.Equal(2L, await ScalarAsync(factory, "SELECT count(*) FROM reward_cycle_resets"));
    }

    [Fact]
    public async Task AResetForOnePlayer_CountsItsOwnGeneration_AndLeavesTheGlobalOneAlone()  // C24
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        var alice = await AddPlayerAsync(factory, "alice");
        var bob = await AddPlayerAsync(factory, "bob");
        await admin.PutRewardRuleAsync(Lich(10), Ct);

        var a1 = await admin.ResetRewardCycleAsync(new("boss/enemy.lich", alice), Ct);
        var a2 = await admin.ResetRewardCycleAsync(new("boss/enemy.lich", alice), Ct);
        var b1 = await admin.ResetRewardCycleAsync(new("boss/enemy.lich", bob), Ct);
        var everyone = await admin.ResetRewardCycleAsync(new("boss/enemy.lich"), Ct);

        Assert.Equal([1, 2, 1, 1], new[] { a1.Generation, a2.Generation, b1.Generation, everyone.Generation });
        Assert.Equal(alice, a1.PlayerId);
        Assert.Equal(1, (await admin.ListRewardRulesAsync(Ct)).Rules.Single().Generation);  // the list shows the global one
    }

    [Fact]
    public async Task ConcurrentResets_AreConsecutive_InEveryScope()  // C20
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        var alice = await AddPlayerAsync(factory, "alice");
        await admin.PutRewardRuleAsync(Lich(10), Ct);

        var everyone = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => admin.ResetRewardCycleAsync(new("boss/enemy.lich"), Ct)));
        var one = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => admin.ResetRewardCycleAsync(new("boss/enemy.lich", alice), Ct)));

        Assert.Equal(Enumerable.Range(1, 8), everyone.Select(r => r.Generation).Order());
        Assert.Equal(Enumerable.Range(1, 8), one.Select(r => r.Generation).Order());
    }

    [Fact]
    public async Task AResetOfUnknownTargets_Is404_1303_AndABadIdIs400_1301()  // C19
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        await admin.PutRewardRuleAsync(Lich(10), Ct);

        var noRule = await Assert.ThrowsAsync<GameServerApiException>(() => admin.ResetRewardCycleAsync(new("boss/enemy.nobody"), Ct));
        var noPlayer = await Assert.ThrowsAsync<GameServerApiException>(() => admin.ResetRewardCycleAsync(new("boss/enemy.lich", Guid.NewGuid()), Ct));
        var badId = await Assert.ThrowsAsync<GameServerApiException>(() => admin.ResetRewardCycleAsync(new("boss/enemy lich"), Ct));

        Assert.Equal((HttpStatusCode.NotFound, ApiErrors.RewardTargetUnknown), (noRule.StatusCode, noRule.ErrorCode));
        Assert.Equal((HttpStatusCode.NotFound, ApiErrors.RewardTargetUnknown), (noPlayer.StatusCode, noPlayer.ErrorCode));
        Assert.Equal((HttpStatusCode.BadRequest, ApiErrors.RewardRuleInvalid), (badId.StatusCode, badId.ErrorCode));
        Assert.Equal(0L, await ScalarAsync(factory, "SELECT count(*) FROM reward_cycle_resets"));
        Assert.Equal(1L, await ScalarAsync(factory, "SELECT count(*) FROM outbox"));  // only the rule's own event
    }

    [Fact]
    public async Task AResetOfARetiredChallenge_IsAllowed_BecauseItStillHasARule()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        await admin.PutRewardRuleAsync(Lich(10), Ct);
        await admin.PutRewardRuleAsync(Lich(0), Ct);

        var reset = await admin.ResetRewardCycleAsync(new("boss/enemy.lich"), Ct);

        Assert.Equal(1, reset.Generation);
    }

    [Fact]
    public async Task AResetAndItsEvent_AreOneTransaction()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        await admin.PutRewardRuleAsync(Lich(10), Ct);
        await ExecuteAsync(factory, "ALTER TABLE outbox ADD CONSTRAINT no_reset_events CHECK (type <> 'RewardCycleReset')");

        await Assert.ThrowsAnyAsync<Exception>(() => admin.ResetRewardCycleAsync(new("boss/enemy.lich"), Ct));

        Assert.Equal(0L, await ScalarAsync(factory, "SELECT count(*) FROM reward_cycle_resets"));
    }

    [Fact]
    public async Task TheResetsUniqueIndex_RefusesATwinGeneration_InTheSameScope()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        var alice = await AddPlayerAsync(factory, "alice");
        await admin.PutRewardRuleAsync(Lich(10), Ct);
        await admin.ResetRewardCycleAsync(new("boss/enemy.lich"), Ct);
        await admin.ResetRewardCycleAsync(new("boss/enemy.lich", alice), Ct);

        await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(factory,
            "INSERT INTO reward_cycle_resets (challenge_id, generation, reset_by) VALUES ('boss/enemy.lich', 1, 't')"));
        await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(factory,
            $"INSERT INTO reward_cycle_resets (challenge_id, player_id, generation, reset_by) VALUES ('boss/enemy.lich', '{alice}', 1, 't')"));
    }

    // ---- Trace continuity (spec economy-rewards 3.8, F11) ----

    [Fact]
    public async Task ARuleChange_StoresTheAdminRequestsTraceParent_OnItsOutboxRow()
    {
        using var listener = Listen();
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        var admin = await ClientAsync(factory, "designer");
        var traceId = ActivityTraceId.CreateRandom();
        var sent = $"00-{traceId}-{ActivitySpanId.CreateRandom()}-01";
        using var request = new HttpRequestMessage(HttpMethod.Put, "api/v1/admin/reward-rules")
        {
            Content = System.Net.Http.Json.JsonContent.Create(Lich(10), options: RpgJson.Options),
        };
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", admin.AccessToken);
        request.Headers.Add("traceparent", sent);

        using var response = await factory.CreateClient().SendAsync(request, Ct);

        response.EnsureSuccessStatusCode();
        var stored = (await TextsAsync(factory, "SELECT traceparent FROM outbox WHERE type = 'RewardRuleChanged'")).Single();
        Assert.True(ActivityContext.TryParse(stored, null, out var context), stored);
        Assert.Equal(traceId, context.TraceId);  // the row says which request wrote it
    }

    [Fact]
    public async Task AnExplicitTraceParent_WinsOverTheCurrentActivity_AndNoActivityStoresNull()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Admin);
        await factory.Services.GetRequiredService<MigrationRunner>().EnsureMigratedAsync(Ct);
        var data = factory.Services.GetRequiredService<NpgsqlDataSource>();
        const string explicitParent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";

        await using (var connection = await data.OpenConnectionAsync(Ct))
        await using (var transaction = await connection.BeginTransactionAsync(Ct))
        {
            await OutboxWriter.InsertAsync(connection, transaction, new OutboxMessage(Guid.NewGuid(), "redpanda", EventTopics.Battle,
                "k", "explicit", "{}", explicitParent), Ct);
            await OutboxWriter.InsertAsync(connection, transaction, new OutboxMessage(Guid.NewGuid(), "redpanda", EventTopics.Battle,
                "k", "none", "{}"), Ct);
            await transaction.CommitAsync(Ct);
        }

        Assert.Equal(explicitParent, (await TextsAsync(factory, "SELECT traceparent FROM outbox WHERE type = 'explicit'")).Single());
        Assert.Empty(await TextsAsync(factory, "SELECT traceparent FROM outbox WHERE type = 'none' AND traceparent IS NOT NULL"));
    }

    private static ActivityListener Listen()
    {
        var listener = new ActivityListener
        {
            ShouldListenTo = _ => true,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllDataAndRecorded,
        };
        ActivitySource.AddActivityListener(listener);
        return listener;
    }

    private sealed class StubEnvironment(string name) : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = name;

        public string ApplicationName { get; set; } = "test";

        public string ContentRootPath { get; set; } = "";

        public Microsoft.Extensions.FileProviders.IFileProvider ContentRootFileProvider { get; set; } = null!;
    }

    private static async Task<long> ScalarAsync(ApiFactory factory, string sql)
    {
        await factory.Services.GetRequiredService<MigrationRunner>().EnsureMigratedAsync(Ct);
        await using var command = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(sql);
        return Convert.ToInt64(await command.ExecuteScalarAsync(Ct));
    }

    private static async Task<List<string>> TextsAsync(ApiFactory factory, string sql)
    {
        await using var command = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync(Ct);
        var values = new List<string>();
        while (await reader.ReadAsync(Ct))
        {
            values.Add(reader.GetString(0));
        }

        return values;
    }

    private static async Task ExecuteAsync(ApiFactory factory, string sql)
    {
        await factory.Services.GetRequiredService<MigrationRunner>().EnsureMigratedAsync(Ct);
        await using var command = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(sql);
        await command.ExecuteNonQueryAsync(Ct);
    }

    private static async Task WaitAsync(Func<Task<bool>> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (!await condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "timed out");
            await Task.Delay(100, Ct);
        }
    }
}
