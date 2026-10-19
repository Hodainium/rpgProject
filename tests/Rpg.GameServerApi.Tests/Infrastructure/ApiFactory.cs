using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Rpg.Contracts.Serialization;

namespace Rpg.GameServerApi.Tests.Infrastructure;

/// <summary>Hosts the real server in-process with the dependency addresses a test chooses.</summary>
public sealed class ApiFactory(string postgres, string redis, string rabbitMq) : WebApplicationFactory<Program>
{
    public static ApiFactory AllUp(StackFixture stack) =>
        new(stack.PostgresConnectionString, stack.RedisConnectionString, stack.RabbitMqUri);

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        // "Testing" skips appsettings.Development.json and user secrets, so only these addresses apply.
        builder.UseEnvironment("Testing");
        builder.ConfigureAppConfiguration(config => config.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["ConnectionStrings:Postgres"] = postgres,
            ["ConnectionStrings:Redis"] = redis,
            ["RabbitMq:Uri"] = rabbitMq,
        }));
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
