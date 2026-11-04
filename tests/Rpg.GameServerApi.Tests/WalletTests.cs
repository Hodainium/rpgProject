using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using Rpg.Client;
using Rpg.Contracts.Economy;
using Rpg.GameServerApi.Economy;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Tests.Infrastructure;
using Rpg.Verification;
using StackExchange.Redis;
using static Rpg.GameServerApi.Tests.RunTests;

namespace Rpg.GameServerApi.Tests;

/// <summary>Spec settlement-outbox 2.4, 3.2, 3.5: the wallet read model, its cache, and the schema's money constraints.</summary>
[Collection(StackCollection.Name)]
public class WalletTests(StackFixture stack)
{
    private static readonly Dictionary<string, string?> Quiet = new()
    {
        ["Outbox:Enabled"] = "false",
        ["Monitors:Interval"] = "01:00:00",
    };

    /// <summary>A player name of this test's own: the wallet cache in the shared Redis is keyed by player.</summary>
    private static string Alice([System.Runtime.CompilerServices.CallerMemberName] string test = "") =>
        "w" + Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(System.Text.Encoding.UTF8.GetBytes(test)))[..16];

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task GetWallet_ANewPlayer_HasNothing()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, Alice());

        var wallet = await client.GetWalletAsync(Ct);

        Assert.Equal(0, wallet.Gems);
        Assert.Empty(wallet.Recent);
    }

    [Fact]
    public async Task GetWallet_RequiresAToken()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);

        var error = await Assert.ThrowsAsync<GameServerApiException>(() => new GameServerClient(factory.CreateClient()).GetWalletAsync(Ct));

        Assert.Equal(System.Net.HttpStatusCode.Unauthorized, error.StatusCode);
    }

    [Fact]
    public async Task GetWallet_ShowsGemsAndRecentLedgerRows_AndIsCachedForSixtySeconds()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        await ReadyProbe.WaitUntilAsync(factory.CreateClient(), r => r.StatusOf("redis") == "Healthy");
        var client = await ClientAsync(factory, Alice());
        var player = await PlayerIdAsync(factory, Alice());
        await GrantAsync(factory, player, "b1", "warrior", 10);
        await GrantAsync(factory, player, "b1", "cleric", 10);

        var wallet = await client.GetWalletAsync(Ct);
        await ExecuteAsync(factory, $"UPDATE wallets SET gems = 999 WHERE player_id = '{player}'");  // behind the cache's back
        var cached = await client.GetWalletAsync(Ct);

        Assert.Equal(20, wallet.Gems);
        Assert.Equal(2, wallet.Recent.Count);
        Assert.Equal("completion_mark", wallet.Recent[0].Reason);
        Assert.Equal(20, cached.Gems);  // served from Redis
        var redis = await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString);
        var ttl = await redis.GetDatabase().KeyTimeToLiveAsync(VerifyPolicy.WalletKey(player));
        Assert.InRange(ttl!.Value, TimeSpan.FromSeconds(50), TimeSpan.FromSeconds(60));
    }

    [Fact]
    public async Task GetWallet_RedisFlushed_IsServedFromPostgres()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        await ReadyProbe.WaitUntilAsync(factory.CreateClient(), r => r.StatusOf("redis") == "Healthy");
        var client = await ClientAsync(factory, Alice());
        var player = await PlayerIdAsync(factory, Alice());
        await GrantAsync(factory, player, "b1", "warrior", 10);
        var first = await client.GetWalletAsync(Ct);

        var redis = await ConnectionMultiplexer.ConnectAsync(stack.RedisConnectionString);
        await redis.GetDatabase().KeyDeleteAsync(VerifyPolicy.WalletKey(player));  // scenario 4
        await ExecuteAsync(factory, $"UPDATE wallets SET gems = 15, version = version + 1 WHERE player_id = '{player}'");
        var second = await client.GetWalletAsync(Ct);

        Assert.Equal(10, first.Gems);
        Assert.Equal(15, second.Gems);  // F15: Postgres is the truth
    }

    [Fact]
    public async Task GetWallet_RedisDown_StillAnswersFromPostgres()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, redis: StackFixture.Unreachable.Redis, settings: Quiet);
        var client = await ClientAsync(factory, Alice());
        await GrantAsync(factory, await PlayerIdAsync(factory, Alice()), "b1", "warrior", 10);

        Assert.Equal(10, (await client.GetWalletAsync(Ct)).Gems);
    }

    [Fact]
    public async Task Schema_RefusesNegativeGems_ADoubleLedgerKey_AndASecondMark()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Quiet);
        var client = await ClientAsync(factory, Alice());
        var player = await PlayerIdAsync(factory, Alice());
        var run = await client.StartRunAsync(new Rpg.Contracts.Runs.RunStartRequest(ApiFactory.TestRuleset, "descent", ["warrior"]), Ct);
        await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start(), RunLog.Battle(run.RunId, 2)), Ct);
        var battle = $"{run.RunId}/f0/c5";
        await GrantAsync(factory, player, battle, "warrior", 10);
        await ExecuteAsync(factory,
            $"INSERT INTO completion_marks (player_id, character_id, boss_id, battle_id) VALUES ('{player}', 'warrior', 'boss', '{battle}')");

        var negative = await Assert.ThrowsAsync<PostgresException>(() =>
            ExecuteAsync(factory, $"UPDATE wallets SET gems = -1 WHERE player_id = '{player}'"));
        var duplicateKey = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(factory,
            $"INSERT INTO wallet_ledger (player_id, currency, delta, reason, idempotency_key) VALUES ('{player}', 'gems', 5, 'x', 'mark:{battle}:warrior:boss')"));
        var secondMark = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(factory,
            $"INSERT INTO completion_marks (player_id, character_id, boss_id, battle_id) VALUES ('{player}', 'warrior', 'boss', '{battle}')"));
        var badDestination = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(factory,
            "INSERT INTO outbox (id, destination, topic, key, type, payload) VALUES (gen_random_uuid(), 'carrier-pigeon', 't', 'k', 't', '{}')"));
        var zeroDelta = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(factory,
            $"INSERT INTO wallet_ledger (player_id, currency, delta, reason, idempotency_key) VALUES ('{player}', 'gems', 0, 'x', 'k0')"));

        Assert.Equal("23514", negative.SqlState);
        Assert.Equal("wallet_ledger_idempotency_key_key", duplicateKey.ConstraintName);
        Assert.Equal("completion_marks_pkey", secondMark.ConstraintName);
        Assert.Equal("23514", badDestination.SqlState);
        Assert.Equal("23514", zeroDelta.SqlState);
    }

    [Fact]
    public async Task Migration0004_BackfillsAJobForEverySessionStillWaitingForAVerdict()
    {
        // A database at 0003 holding a Submitted and a Verified session, then 0004 applied on top of it.
        var connectionString = await stack.NewDatabaseAsync();
        await using var data = NpgsqlDataSource.Create(connectionString);
        var scripts = MigrationRunner.Scripts;
        var upToThree = scripts.Where(s => string.CompareOrdinal(s.Name, "0004") < 0).ToList();
        foreach (var script in upToThree)
        {
            await using var apply = data.CreateCommand(script.Sql);
            await apply.ExecuteNonQueryAsync(Ct);
        }

        var runId = Guid.NewGuid();
        var playerId = Guid.NewGuid();
        await Exec(data, $"INSERT INTO players VALUES ('{playerId}', 'p', now())");
        await Exec(data,
            $"INSERT INTO runs (run_id, player_id, ruleset_version, run_structure_id, character_ids, status, started_at) " +
            $"VALUES ('{runId}', '{playerId}', 'r', 's', '{{a}}', 'Active', now())");
        foreach (var seq in new[] { 1, 2 })
        {
            await Exec(data,
                $"INSERT INTO run_actions (run_id, seq, floor, type, action, state_hash, played_at, received_at) " +
                $"VALUES ('{runId}', {seq}, 0, 'battle', '{{}}', 'h', now(), now())");
        }

        await Exec(data,
            $"INSERT INTO battle_sessions (battle_id, run_id, run_seq, seed, ruleset_version, conditions, action_log, status, submitted_at) " +
            $"VALUES ('waiting', '{runId}', 1, 1, 'r', '{{}}', '{{}}', 'Submitted', now())");
        await Exec(data,
            $"INSERT INTO battle_sessions (battle_id, run_id, run_seq, seed, ruleset_version, conditions, action_log, status, submitted_at, verdict) " +
            $"VALUES ('done', '{runId}', 2, 1, 'r', '{{}}', '{{}}', 'Verified', now(), '{{}}')");

        await using (var apply = data.CreateCommand(scripts.Single(s => s.Name.StartsWith("0004", StringComparison.Ordinal)).Sql))
        {
            await apply.ExecuteNonQueryAsync(Ct);
        }

        await using var read = data.CreateCommand("SELECT key, destination, type FROM outbox");
        await using var reader = await read.ExecuteReaderAsync(Ct);
        Assert.True(await reader.ReadAsync(Ct));
        Assert.Equal(("waiting", "rabbit", "VerifyBattleJob"), (reader.GetString(0), reader.GetString(1), reader.GetString(2)));
        Assert.False(await reader.ReadAsync(Ct));  // the verified session needs no job
    }

    private static async Task Exec(NpgsqlDataSource data, string sql)
    {
        await using var command = data.CreateCommand(sql);
        await command.ExecuteNonQueryAsync(Ct);
    }

    private static async Task<Guid> PlayerIdAsync(ApiFactory factory, string name)
    {
        var client = new GameServerClient(factory.CreateClient());
        return Guid.Parse((await client.GetDevTokenAsync(new Rpg.Contracts.Auth.DevTokenRequest(name), Ct)).PlayerId);
    }

    /// <summary>What the worker's settlement transaction leaves behind for one mark (without the mark row itself).</summary>
    private static async Task GrantAsync(ApiFactory factory, Guid player, string battle, string character, int gems)
    {
        await ExecuteAsync(factory, $"INSERT INTO players VALUES ('{player}', 'p', now()) ON CONFLICT DO NOTHING");
        await ExecuteAsync(factory,
            $"INSERT INTO wallets (player_id, gems, version) VALUES ('{player}', {gems}, 1) " +
            $"ON CONFLICT (player_id) DO UPDATE SET gems = wallets.gems + {gems}, version = wallets.version + 1");
        await ExecuteAsync(factory,
            "INSERT INTO wallet_ledger (player_id, currency, delta, reason, ref_battle_id, idempotency_key) " +
            $"VALUES ('{player}', 'gems', {gems}, 'completion_mark', '{battle}', 'mark:{battle}:{character}:boss')");
    }

    private static async Task ExecuteAsync(ApiFactory factory, string sql)
    {
        await factory.Services.GetRequiredService<MigrationRunner>().EnsureMigratedAsync(Ct);
        await using var command = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(sql);
        await command.ExecuteNonQueryAsync(Ct);
    }
}
