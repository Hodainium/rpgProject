using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Rpg.Contracts.Serialization;

namespace Rpg.GameServerApi.Tests.Infrastructure;

/// <summary>
/// Hosts the real server in-process with the dependency addresses a test chooses. The environment defaults to
/// "Testing" (skips appsettings.Development.json and user secrets, so only these settings apply); run tests use
/// "Development", where dev tokens are issued, with every setting they rely on given here (rate limits far above
/// what a test does, unless the test sets its own).
/// </summary>
public sealed class ApiFactory(string postgres, string redis, string rabbitMq, string environment = "Testing",
    IReadOnlyDictionary<string, string?>? settings = null) : WebApplicationFactory<Program>
{
    public const string TestSeedSecret = "test-floor-seed-secret-0123456789abcdef";
    public const string TestRuleset = "4.7.2.stable.mono+0123456789abcdef";
    public const string TestSigningKey = "test-jwt-signing-key-0123456789abcdef";

    public static ApiFactory AllUp(StackFixture stack) =>
        new(stack.PostgresConnectionString, stack.RedisConnectionString, stack.RabbitMqUri);

    /// <summary>The whole stack, a database of its own, Development, accepting only <see cref="TestRuleset"/>.</summary>
    public static async Task<ApiFactory> RunsAsync(StackFixture stack, string? redis = null,
        string environment = "Development", IReadOnlyDictionary<string, string?>? settings = null) =>
        new(await stack.NewDatabaseAsync(), redis ?? stack.RedisConnectionString, stack.RabbitMqUri, environment,
            settings);

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment(environment);
        builder.ConfigureAppConfiguration(config =>
        {
            var values = new Dictionary<string, string?>
            {
                ["ConnectionStrings:Postgres"] = postgres,
                ["ConnectionStrings:Redis"] = redis,
                ["RabbitMq:Uri"] = rabbitMq,
                ["Seeds:Secret"] = TestSeedSecret,
                ["Ruleset:AcceptAny"] = "false",
                ["Ruleset:Accepted:0"] = TestRuleset,
                ["Auth:SigningKey"] = TestSigningKey,
                ["Auth:DevTokens"] = "true",
                ["Cards:Enabled"] = "false",   // spec card-collection: the card tests turn it on over their own fixtures

            };
            foreach (var bucket in new[] { "actions", "runs", "floors" })
            {
                values[$"RateLimit:Buckets:{bucket}:Capacity"] = "100000";
                values[$"RateLimit:Buckets:{bucket}:RefillPerSecond"] = "100000";
            }

            foreach (var (key, value) in settings ?? new Dictionary<string, string?>())
            {
                values[key] = value;
            }

            config.AddInMemoryCollection(values);
        });
    }
}

public sealed record ReadyReport(string Status, List<ReadyCheck> Checks)
{
    public string StatusOf(string check) => Checks.Single(c => c.Name == check).Status;
}

public sealed record ReadyCheck(string Name, string Status, string? Description);

public static class ReadyProbe
{
    public static async Task<(HttpStatusCode Code, ReadyReport Report)> GetAsync(HttpClient client)
    {
        using var response = await client.GetAsync("/health/ready", TestContext.Current.CancellationToken);
        var report = await response.Content.ReadFromJsonAsync<ReadyReport>(RpgJson.Options,
            TestContext.Current.CancellationToken);
        return (response.StatusCode, report!);
    }

    /// <summary>Polls /health/ready until the condition holds (connections are made in the background).</summary>
    public static async Task<(HttpStatusCode Code, ReadyReport Report)> WaitUntilAsync(
        HttpClient client, Func<ReadyReport, bool> condition, TimeSpan? timeout = null)
    {
        var deadline = Stopwatch.StartNew();
        var limit = timeout ?? TimeSpan.FromSeconds(30);
        while (true)
        {
            var result = await GetAsync(client);
            if (condition(result.Report))
            {
                return result;
            }

            if (deadline.Elapsed > limit)
            {
                Assert.Fail($"Readiness condition not met within {limit}. Last report: {result.Report}");
            }

            await Task.Delay(250, TestContext.Current.CancellationToken);
        }
    }
}
