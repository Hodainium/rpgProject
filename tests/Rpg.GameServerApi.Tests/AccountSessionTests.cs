using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using Rpg.Client;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Auth;
using Rpg.Contracts.Cards;
using Rpg.Contracts.Runs;
using Rpg.GameServerApi.Tests.Infrastructure;
using static Rpg.GameServerApi.Tests.CardFixtures;
using static Rpg.GameServerApi.Tests.RunTests;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Spec account-session (slice 5b1) section 4: the login session fences every account-changing call (an older session is refused
/// with 409 1412 and nothing is written), the expected version refuses a decision made on a stale view (409 1413), the replay of
/// a committed request comes before both checks, the login waits for an action mid-commit, and every writer of the account
/// raises its version. Real Postgres, Redis and RabbitMQ; the card fixtures, never the demo content. The two reward writers
/// (a granted challenge reward, a released pending reward) are covered by the worker's
/// <c>SettlementTests.ABossVictory_GrantsOneMarkPerCharacter_AndWritesTheLedgerWalletAndEventsTogether</c> (version 2 after two
/// grants that went through pending and release).
/// </summary>
[Collection(StackCollection.Name)]
public class AccountSessionTests(StackFixture stack)
{
    private static readonly Dictionary<string, string?> Cards = new()
    {
        ["Cards:Enabled"] = "true",
        ["Outbox:Enabled"] = "false",
        ["Monitors:Interval"] = "01:00:00",
        ["Auth:DevAdmins:0"] = "designer",
    };

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static string Name([System.Runtime.CompilerServices.CallerMemberName] string test = "") =>
        "s" + Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(Encoding.UTF8.GetBytes(test)))[..16];

    private async Task<ApiFactory> FactoryAsync()
    {
        var factory = await ApiFactory.RunsAsync(stack, null, settings: Cards);
        await SeedAsync(factory);
        await ReadyProbe.WaitUntilAsync(factory.CreateClient(), r => r.StatusOf("redis") == "Healthy");
        await factory.Services.GetRequiredService<Rpg.GameServerApi.Cards.CatalogCache>()
            .InvalidateAsync(Rpg.GameServerApi.Cards.CatalogCache.CardsKey, Rpg.GameServerApi.Cards.CatalogCache.PacksKey);
        return factory;
    }

    /// <summary>A device of the player: a client of its own with its own token (the same player id for the same name).</summary>
    private static async Task<(GameServerClient Client, string PlayerId)> DeviceAsync(ApiFactory factory, string name)
    {
        var client = new GameServerClient(factory.CreateClient());
        var token = await client.GetDevTokenAsync(new DevTokenRequest(name), Ct);
        client.AccessToken = token.AccessToken;
        return (client, token.PlayerId);
    }

    private static async Task<GameServerApiException> RefusedAsync(Func<Task> call) =>
        await Assert.ThrowsAsync<GameServerApiException>(call);

    private static Task<long> CountAsync(ApiFactory factory, string sql) => ScalarAsync(factory, sql);

    private static async Task<long> VersionAsync(GameServerClient client) => (await client.GetCollectionAsync(Ct)).AccountVersion;

    /// <summary>Everything an account action writes: a refusal must leave every one of these unchanged.</summary>
    private static async Task<string> FootprintAsync(ApiFactory factory, string player) =>
        string.Join("|", await CountAsync(factory, $"SELECT count(*) FROM wallet_ledger WHERE player_id = '{player}'"),
            await CountAsync(factory, $"SELECT count(*) FROM card_ledger WHERE player_id = '{player}'"),
            await CountAsync(factory, $"SELECT count(*) FROM pack_ledger WHERE player_id = '{player}'"),
            await CountAsync(factory, $"SELECT count(*) FROM account_requests WHERE player_id = '{player}'"),
            await CountAsync(factory, $"SELECT COALESCE(sum(gems + dust + account_version), 0)::bigint FROM wallets WHERE player_id = '{player}'"),
            await CountAsync(factory, $"SELECT COALESCE(sum(count), 0)::bigint FROM pack_inventory WHERE player_id = '{player}'"),
            await CountAsync(factory, $"SELECT count(*) FROM card_holdings WHERE player_id = '{player}'"),
            await CountAsync(factory, $"SELECT count(*) FROM runs WHERE player_id = '{player}' AND status = 'Abandoned'"),
            await CountAsync(factory, $"SELECT count(*) FROM runs WHERE player_id = '{player}'"),
            await CountAsync(factory, $"SELECT count(*) FROM wallets WHERE player_id = '{player}'"),
            await CountAsync(factory, $"SELECT COALESCE(max(account_session), 0) FROM players WHERE player_id = '{player}'"));

    // ---- the session (2.1) -------------------------------------------------------------------------------------------

    [Fact]
    public async Task Session_RisesByOnePerLogin_AndReturnsTheCollection()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await DeviceAsync(factory, Name());
        await GrantAsync(factory, player, gems: 120, dust: 30);

        var first = await client.StartAccountSessionAsync(Ct);
        var second = await client.StartAccountSessionAsync(Ct);
        var read = await client.GetCollectionAsync(Ct);

        Assert.Equal(first.Session + 1, second.Session);
        Assert.Equal(1L, first.Session);
        Assert.Equal(read with { Owned = [], Pity = [], OwnedPacks = [] }, second.Collection with { Owned = [], Pity = [], OwnedPacks = [] });
        Assert.Equal(read.Owned, second.Collection.Owned);
        Assert.Equal(read.OwnedPacks, second.Collection.OwnedPacks);
        Assert.Equal(1L, await CountAsync(factory, $"SELECT count(*) FROM players WHERE player_id = '{player}' AND account_session = 2"));
    }

    /// <summary>
    /// Row 2 (acceptance 2): a crashed client's buy is mid-commit (it holds the account lock) when the player logs in again. The
    /// login waits for it, so its snapshot already shows what the buy did: no older request can commit behind it.
    /// </summary>
    [Fact]
    public async Task Session_WaitsForAnActionMidCommit_AndItsSnapshotShowsIt()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await DeviceAsync(factory, Name());
        await GrantAsync(factory, player, gems: 100);
        await client.StartAccountSessionAsync(Ct);
        var before = await client.GetCollectionAsync(Ct);

        var data = factory.Services.GetRequiredService<NpgsqlDataSource>();
        await using var connection = await data.OpenConnectionAsync(Ct);
        await using var action = await connection.BeginTransactionAsync(Ct);
        await using (var lockIt = new NpgsqlCommand("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", connection, action))
        {
            lockIt.Parameters.Add(new NpgsqlParameter { Value = "acct:" + player });
            await lockIt.ExecuteNonQueryAsync(Ct);
        }

        await using (var spend = new NpgsqlCommand(
                         "UPDATE wallets SET gems = gems - 40, account_version = account_version + 1 WHERE player_id = $1", connection, action))
        {
            spend.Parameters.Add(new NpgsqlParameter { Value = Guid.Parse(player) });
            await spend.ExecuteNonQueryAsync(Ct);
        }

        var login = client.StartAccountSessionAsync(Ct);
        await Task.Delay(500, Ct);
        var waited = !login.IsCompleted;
        await action.CommitAsync(Ct);
        var snapshot = (await login).Collection;

        Assert.True(waited, "the login waits on the account lock");
        Assert.Equal(before.Gems - 40, snapshot.Gems);
        Assert.Equal(before.AccountVersion + 1, snapshot.AccountVersion);
    }

    // ---- the fence (2.2) ---------------------------------------------------------------------------------------------

    /// <summary>
    /// Rows 3 and 4: a request from an older session (a crashed client's late request, a second device) is refused with 1412 by
    /// each of the seven fenced calls (the run start too: it abandons the active run), and writes nothing; the newest login's calls go through.
    /// </summary>
    [Fact]
    public async Task OldSession_IsRefusedByEveryFencedCall_AndWritesNothing_TheNewestLoginWins()
    {
        await using var factory = await FactoryAsync();
        var (phone, player) = await DeviceAsync(factory, Name());
        var (laptop, _) = await DeviceAsync(factory, Name());
        await GrantAsync(factory, player, gems: 500, dust: 2000);
        await OwnAsync(factory, player, "item.k1");
        var old = await phone.StartAccountSessionAsync(Ct);
        await phone.BuyPackAsync(StarterPack, new PackBuyRequest(Guid.NewGuid(), 1, old.Session, old.Collection.AccountVersion), Ct);
        var run = await phone.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"], old.Session), Ct);
        var version = await VersionAsync(phone);
        var current = await laptop.StartAccountSessionAsync(Ct);   // the newest login
        var footprint = await FootprintAsync(factory, player);

        GameServerApiException[] refused =
        [
            await RefusedAsync(() => phone.BuyPackAsync(StarterPack, new PackBuyRequest(Guid.NewGuid(), 1, old.Session, version), Ct)),
            await RefusedAsync(() => phone.OpenPackAsync(StarterPack, new AccountActionRequest(Guid.NewGuid(), old.Session, version), Ct)),
            await RefusedAsync(() => phone.DustCardAsync("item.r1", new AccountActionRequest(Guid.NewGuid(), old.Session, version), Ct)),
            await RefusedAsync(() => phone.CraftCardAsync("item.e1", new AccountActionRequest(Guid.NewGuid(), old.Session, version), Ct)),
            await RefusedAsync(() => phone.RefundPacksAsync(new PackRefundsRequest(old.Session), Ct)),
            await RefusedAsync(() => phone.AbandonRunAsync(run.RunId, new RunAbandonRequest(old.Session), Ct)),
            await RefusedAsync(() => phone.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"], old.Session), Ct)),
        ];

        Assert.All(refused, error => Assert.Equal((HttpStatusCode.Conflict, ApiErrors.AccountSessionReplaced),
            (error.StatusCode, error.ErrorCode)));
        Assert.All(refused, error => Assert.Equal(current.Session, error.Problem?.CurrentSession));
        Assert.Equal(footprint, await FootprintAsync(factory, player));
        Assert.Equal(RunStatus.Active, (await phone.GetRunAsync(run.RunId, Ct)).Status);

        // The newest login's calls go through.
        var bought = await laptop.BuyPackAsync(StarterPack, new PackBuyRequest(Guid.NewGuid(), 1, current.Session, version), Ct);
        Assert.Equal(2, bought.Owned);
        await laptop.AbandonRunAsync(run.RunId, new RunAbandonRequest(current.Session), Ct);
        Assert.Equal(RunStatus.Abandoned, (await laptop.GetRunAsync(run.RunId, Ct)).Status);
    }

    /// <summary>
    /// Review fix: a cancel whose 204 was lost stays a success when retried after a newer login (it changes nothing, like the
    /// replay of a committed account action); a cancel that has not happened is still fenced.
    /// </summary>
    [Fact]
    public async Task RetriedAbandon_AfterANewerLogin_IsStillASuccess()
    {
        await using var factory = await FactoryAsync();
        var (phone, _) = await DeviceAsync(factory, Name());
        var (laptop, _) = await DeviceAsync(factory, Name());
        var old = await phone.StartAccountSessionAsync(Ct);
        var run = await phone.StartRunAsync(new RunStartRequest(ApiFactory.TestRuleset, "run.test", ["hero.a"], old.Session), Ct);

        await phone.AbandonRunAsync(run.RunId, new RunAbandonRequest(old.Session), Ct);   // its 204 is lost
        await laptop.StartAccountSessionAsync(Ct);
        await phone.AbandonRunAsync(run.RunId, new RunAbandonRequest(old.Session), Ct);   // the retry

        Assert.Equal(RunStatus.Abandoned, (await phone.GetRunAsync(run.RunId, Ct)).Status);
    }

    /// <summary>Row 5: a decision made on a stale view (the account moved since it was read) is refused with 1413 and writes nothing.</summary>
    [Fact]
    public async Task StaleVersion_IsRefusedByEveryDecision_AndWritesNothing()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await DeviceAsync(factory, Name());
        await GrantAsync(factory, player, gems: 500, dust: 2000);
        await OwnAsync(factory, player, "item.k1");
        var session = (await client.StartAccountSessionAsync(Ct)).Session;
        await client.BuyPackAsync(StarterPack, new PackBuyRequest(Guid.NewGuid(), 1, session, await VersionAsync(client)), Ct);
        var current = await VersionAsync(client);
        var stale = current - 1;   // what the screen read before the buy
        var footprint = await FootprintAsync(factory, player);

        GameServerApiException[] refused =
        [
            await RefusedAsync(() => client.BuyPackAsync(StarterPack, new PackBuyRequest(Guid.NewGuid(), 1, session, stale), Ct)),
            await RefusedAsync(() => client.OpenPackAsync(StarterPack, new AccountActionRequest(Guid.NewGuid(), session, stale), Ct)),
            await RefusedAsync(() => client.DustCardAsync("item.k1", new AccountActionRequest(Guid.NewGuid(), session, stale), Ct)),
            await RefusedAsync(() => client.CraftCardAsync("item.e1", new AccountActionRequest(Guid.NewGuid(), session, stale), Ct)),
        ];

        Assert.All(refused, error => Assert.Equal((HttpStatusCode.Conflict, ApiErrors.AccountVersionStale),
            (error.StatusCode, error.ErrorCode)));
        Assert.All(refused, error => Assert.Equal(current, error.Problem?.CurrentAccountVersion));
        Assert.Equal(footprint, await FootprintAsync(factory, player));
    }

    /// <summary>Row 5: a refusal stores nothing under the key, so the client's same key goes through after it read the account again.</summary>
    [Fact]
    public async Task SameKey_AfterAStaleRefusal_GoesThroughOnce()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await DeviceAsync(factory, Name());
        await GrantAsync(factory, player, gems: 300);
        var session = (await client.StartAccountSessionAsync(Ct)).Session;
        var key = Guid.NewGuid();

        var stale = await RefusedAsync(() => client.BuyPackAsync(StarterPack, new PackBuyRequest(key, 1, session, 99), Ct));
        var bought = await client.BuyPackAsync(StarterPack,
            new PackBuyRequest(key, 1, session, stale.Problem!.CurrentAccountVersion!.Value), Ct);

        Assert.Equal(ApiErrors.AccountVersionStale, stale.ErrorCode);
        Assert.Equal((1, 200L), (bought.Owned, bought.Gems));
        Assert.Equal(1L, await CountAsync(factory, $"SELECT count(*) FROM wallet_ledger WHERE player_id = '{player}' AND reason = 'pack_buy'"));
        Assert.Equal(bought.AccountVersion, await VersionAsync(client));
    }

    /// <summary>
    /// Rows 1 and 6: the replay of a committed request comes before the session and version checks: a retry with its key gets
    /// the stored answer even though its own commit moved the version and a newer login happened since.
    /// </summary>
    [Fact]
    public async Task Replay_ComesBeforeTheSessionAndVersionChecks()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await DeviceAsync(factory, Name());
        await GrantAsync(factory, player, gems: 300);
        var first = await client.StartAccountSessionAsync(Ct);
        var request = new PackBuyRequest(Guid.NewGuid(), 2, first.Session, first.Collection.AccountVersion);

        var committed = await client.BuyPackAsync(StarterPack, request, Ct);
        await client.StartAccountSessionAsync(Ct);   // a newer login
        var replayed = await client.BuyPackAsync(StarterPack, request, Ct);

        Assert.Equal(committed, replayed);
        Assert.Equal(first.Collection.AccountVersion + 1, committed.AccountVersion);
        Assert.Equal(1L, await CountAsync(factory, $"SELECT count(*) FROM wallet_ledger WHERE player_id = '{player}' AND reason = 'pack_buy'"));
    }

    /// <summary>Row 7: the numbers are required; a body without them (an old client) is malformed and writes nothing.</summary>
    [Fact]
    public async Task MissingNumbers_AreMalformed()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await DeviceAsync(factory, Name());
        await GrantAsync(factory, player, gems: 300, dust: 2000);
        await OwnAsync(factory, player, "item.k1");
        var session = (await client.StartAccountSessionAsync(Ct)).Session;
        var http = factory.CreateClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", client.AccessToken);
        var key = Guid.NewGuid().ToString("D");
        var footprint = await FootprintAsync(factory, player);

        (string Path, string Body)[] calls =
        [
            ($"/api/v1/packs/{StarterPack}/buy", $$"""{"requestKey":"{{key}}","count":1}"""),
            ($"/api/v1/packs/{StarterPack}/buy", $$"""{"requestKey":"{{key}}","count":1,"session":{{session}}}"""),
            ($"/api/v1/packs/{StarterPack}/buy", $$"""{"requestKey":"{{key}}","count":1,"expectedAccountVersion":0}"""),
            ($"/api/v1/packs/{StarterPack}/open", $$"""{"requestKey":"{{key}}","expectedAccountVersion":0}"""),
            ("/api/v1/cards/item.k1/dust", $$"""{"requestKey":"{{key}}","session":{{session}}}"""),
            ("/api/v1/cards/item.e1/craft", $$"""{"requestKey":"{{key}}","session":0,"expectedAccountVersion":0}"""),
            ("/api/v1/cards/item.e1/craft", $$"""{"requestKey":"{{key}}","session":{{session}},"expectedAccountVersion":-1}"""),
            ("/api/v1/packs/refunds", "{}"),
            ($"/api/v1/runs/{Guid.NewGuid():D}/abandon", "{}"),
            ("/api/v1/runs", $$"""{"rulesetVersion":"{{ApiFactory.TestRuleset}}","runStructureId":"run.test","characterIds":["hero.a"]}"""),
        ];
        var statuses = new List<HttpStatusCode>();
        foreach (var (path, body) in calls)
        {
            using var response = await http.PostAsync(path, new StringContent(body, Encoding.UTF8, "application/json"), Ct);
            statuses.Add(response.StatusCode);
        }

        Assert.All(statuses, status => Assert.Equal(HttpStatusCode.BadRequest, status));
        Assert.Equal(footprint, await FootprintAsync(factory, player));
    }

    // ---- the account version (2.4) -----------------------------------------------------------------------------------

    /// <summary>
    /// Row 8: every writer of what the collection shows raises the account version, so no change can slip past the expected
    /// version: buy, open, dust, craft, a refund payout, and (added by this slice) a refund hold.
    /// </summary>
    [Fact]
    public async Task EveryAccountWriter_RaisesTheVersion()
    {
        await using var factory = await FactoryAsync();
        var (admin, _) = await DeviceAsync(factory, "designer");
        var (client, player) = await DeviceAsync(factory, Name());
        await GrantAsync(factory, player, gems: 1000, dust: 50_000);   // enough to craft any rarity
        await OwnAsync(factory, player, "item.k1");
        var commons = new Dictionary<string, int> { [CardRarities.Common] = 10_000 };
        await admin.PutPackTypeAsync(Pack("paid", 10, 5, commons), Ct);
        await admin.PutPackTypeAsync(Pack("held", 10, 5, commons), Ct);
        var session = (await client.StartAccountSessionAsync(Ct)).Session;

        var raised = new Dictionary<string, bool>();
        async Task StepAsync(string name, Func<long, Task> step)
        {
            var before = await VersionAsync(client);
            await step(before);
            raised[name] = await VersionAsync(client) > before;
        }

        await StepAsync("buy", v => client.BuyPackAsync(StarterPack, new PackBuyRequest(Guid.NewGuid(), 1, session, v), Ct));
        await StepAsync("open", v => client.OpenPackAsync(StarterPack, new AccountActionRequest(Guid.NewGuid(), session, v), Ct));
        await StepAsync("dust", v => client.DustCardAsync("item.k1", new AccountActionRequest(Guid.NewGuid(), session, v), Ct));
        // The open above drew five cards at random: craft one the account does not own now.
        var owned = (await client.GetCollectionAsync(Ct)).Owned.Select(o => o.CardId).ToHashSet();
        var missing = (await client.GetCardCatalogAsync(Ct)).Cards.First(c => !c.Core && !c.Retired && !owned.Contains(c.Id)).Id;
        await StepAsync("craft", v => client.CraftCardAsync(missing, new AccountActionRequest(Guid.NewGuid(), session, v), Ct));

        await client.BuyPackAsync("paid", new PackBuyRequest(Guid.NewGuid(), 2, session, await VersionAsync(client)), Ct);
        await admin.PutPackTypeAsync(Pack("paid", 10, 5, commons, retired: true) with { RefundUnopened = true }, Ct);
        PackRefundsResponse? paid = null;
        await StepAsync("refund", async _ => paid = await client.RefundPacksAsync(new PackRefundsRequest(session), Ct));

        // A hold: the buy row no longer names a version with a price (a damaged ledger), so nothing is paid and the packs are held.
        await client.BuyPackAsync("held", new PackBuyRequest(Guid.NewGuid(), 1, session, await VersionAsync(client)), Ct);
        await using (var damage = factory.Services.GetRequiredService<NpgsqlDataSource>().CreateCommand(
                         $"UPDATE pack_ledger SET pack_version = 99 WHERE player_id = '{player}' AND pack_id = 'held'"))
        {
            await damage.ExecuteNonQueryAsync(Ct);
        }

        await admin.PutPackTypeAsync(Pack("held", 10, 5, commons, retired: true) with { RefundUnopened = true }, Ct);
        await StepAsync("refund hold", _ => client.RefundPacksAsync(new PackRefundsRequest(session), Ct));

        Assert.All(raised, step => Assert.True(step.Value, $"{step.Key} raises the account version"));
        Assert.Equal([new PackRefundDto("paid", 2, 20)], paid!.Refunded);
        Assert.Equal([new OwnedPackDto("held", 1, RefundHeld: true)], (await client.GetCollectionAsync(Ct)).OwnedPacks
            .Where(p => p.PackId == "held"));
    }

    /// <summary>Spec account-session 5: the session counter and the two refusal reasons reach /metrics.</summary>
    [Fact]
    public async Task Metrics_CountSessions_AndTheTwoRefusals()
    {
        await using var factory = await FactoryAsync();
        var (client, player) = await DeviceAsync(factory, Name());
        await GrantAsync(factory, player, gems: 300);
        var first = (await client.StartAccountSessionAsync(Ct)).Session;
        var second = (await client.StartAccountSessionAsync(Ct)).Session;
        await RefusedAsync(() => client.BuyPackAsync(StarterPack, new PackBuyRequest(Guid.NewGuid(), 1, first, 0), Ct));
        await RefusedAsync(() => client.BuyPackAsync(StarterPack, new PackBuyRequest(Guid.NewGuid(), 1, second, 99), Ct));

        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_account_sessions_started_total")
            && text.Contains("reason=\"AccountVersionStale\""));

        Assert.Matches(@"(?m)^rpg_account_sessions_started_total(\{[^}]*\})? [2-9]", metrics);
        Assert.Matches(@"(?m)^rpg_card_actions_refused_total\{[^}]*reason=""SessionReplaced""[^}]*\} 1", metrics);
        Assert.Matches(@"(?m)^rpg_card_actions_refused_total\{[^}]*reason=""AccountVersionStale""[^}]*\} 1", metrics);
    }
}
