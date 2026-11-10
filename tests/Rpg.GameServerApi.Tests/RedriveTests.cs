using System.Net;
using System.Net.Http.Json;
using Microsoft.Extensions.DependencyInjection;
using Rpg.GameServerApi.Ops;
using Rpg.GameServerApi.Outbox;
using Rpg.GameServerApi.Tests.Infrastructure;
using static Rpg.GameServerApi.Tests.RunTests;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Review fix (2026-11-09): the operator's way back from a dead letter. Dead-lettered outbox rows (a Redpanda outage longer
/// than MaxAttempts allows) and dead-lettered verification steps (F8, F24) go back to work; only with the ops-admin role.
/// </summary>
[Collection(StackCollection.Name)]
public class RedriveTests(StackFixture stack)
{
    private static readonly Dictionary<string, string?> Ops = new()
    {
        ["Outbox:Enabled"] = "false",
        ["Monitors:Interval"] = "01:00:00",
        ["Auth:DevAdmins:0"] = "operator",
    };

    private static readonly Rpg.Contracts.Runs.RunStartRequest Start =
        new(ApiFactory.TestRuleset, "descent", ["warrior", "cleric", "ranger"]);

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static HttpClient Http(ApiFactory factory, string player)
    {
        var http = factory.CreateClient();
        http.DefaultRequestHeaders.Authorization = new("Bearer", Token(factory, player));
        return http;
    }

    [Fact]
    public async Task Redrive_NeedsTheOpsAdminRole()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Ops);

        using var outbox = await Http(factory, "alice").PostAsJsonAsync("/api/v1/admin/outbox/redrive", new RedriveRequest(), Ct);
        using var steps = await Http(factory, "alice").PostAsJsonAsync("/api/v1/admin/steps/redrive", new RedriveRequest(), Ct);

        Assert.Equal(HttpStatusCode.Forbidden, outbox.StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, steps.StatusCode);
    }

    [Fact]
    public async Task OutboxRedrive_MakesDeadLetteredRowsLeasableAgain_OfOneDestination()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Ops);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartRunAsync(Start, Ct);   // writes the genesis job (rabbit) to the outbox
        await ExecuteAsync(factory,
            "UPDATE outbox SET dead_lettered_at = now(), dead_letter_reason = 'attempts', attempts = 20 WHERE published_at IS NULL");

        using var redpanda = await Http(factory, "operator").PostAsJsonAsync("/api/v1/admin/outbox/redrive",
            new RedriveRequest(Destination: "redpanda"), Ct);
        using var rabbit = await Http(factory, "operator").PostAsJsonAsync("/api/v1/admin/outbox/redrive",
            new RedriveRequest(Destination: "rabbit"), Ct);

        Assert.Equal(0, (await redpanda.Content.ReadFromJsonAsync<RedriveResponse>(Ct))!.Rows);   // none of that destination
        Assert.Equal(1, (await rabbit.Content.ReadFromJsonAsync<RedriveResponse>(Ct))!.Rows);
        Assert.Equal(0L, await ScalarAsync(factory, "SELECT count(*) FROM outbox WHERE dead_lettered_at IS NOT NULL"));
        var leased = await factory.Services.GetRequiredService<OutboxStore>().LeaseAsync(10, TimeSpan.FromSeconds(30),
            DateTimeOffset.UtcNow, Ct);
        Assert.Equal($"{run.RunId}/0/0", Assert.Single(leased).Key);
        Assert.Equal(1, leased[0].Attempts);   // counted from zero again
    }

    [Fact]
    public async Task StepRedrive_ClearsTheDeadLetter_AndWritesAFreshJob_ButNeverForAnEndedRun()
    {
        await using var factory = await ApiFactory.RunsAsync(stack, settings: Ops);
        var alice = await ClientAsync(factory, "alice");
        var bob = await ClientAsync(factory, "bob");
        var live = await alice.StartRunAsync(Start, Ct);
        var ended = await bob.StartRunAsync(Start, Ct);
        await ExecuteAsync(factory,
            "UPDATE run_steps SET dead_lettered_at = now(), dead_letter_reason = 'attempts', attempts = 5");
        await ExecuteAsync(factory, $"UPDATE runs SET status = 'Lost' WHERE run_id = '{ended.RunId}'");

        using var response = await Http(factory, "operator").PostAsJsonAsync("/api/v1/admin/steps/redrive",
            new RedriveRequest(), Ct);

        Assert.Equal(1, (await response.Content.ReadFromJsonAsync<RedriveResponse>(Ct))!.Rows);
        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(*) FROM run_steps WHERE run_id = '{live.RunId}' AND dead_lettered_at IS NULL AND attempts = 0"));
        Assert.Equal(2L, await ScalarAsync(factory,
            $"SELECT count(*) FROM outbox WHERE type = 'VerifyStepJob' AND key = '{live.RunId}/0/0'"));   // the original and the fresh job
        Assert.Equal(1L, await ScalarAsync(factory,
            $"SELECT count(*) FROM run_steps WHERE run_id = '{ended.RunId}' AND dead_lettered_at IS NOT NULL"));
    }

    private static async Task ExecuteAsync(ApiFactory factory, string sql)
    {
        await using var command = factory.Services.GetRequiredService<Npgsql.NpgsqlDataSource>().CreateCommand(sql);
        await command.ExecuteNonQueryAsync(Ct);
    }
}
