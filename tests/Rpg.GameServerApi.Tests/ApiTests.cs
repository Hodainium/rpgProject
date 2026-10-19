using System.Diagnostics;
using System.Net;
using Rpg.Client;
using Rpg.GameServerApi.Tests.Infrastructure;

namespace Rpg.GameServerApi.Tests;

/// <summary>The real Rpg.Client against the real server, plus error shape and metrics.</summary>
[Collection(StackCollection.Name)]
public class ApiTests(StackFixture stack)
{
    [Fact]
    public async Task Client_GetInfo_ReturnsServerInfo()
    {
        await using var factory = ApiFactory.AllUp(stack);
        var client = new GameServerClient(factory.CreateClient());

        var info = await client.GetInfoAsync(TestContext.Current.CancellationToken);

        Assert.Equal("rpg-game-server-api", info.Service);
        Assert.StartsWith("0.1.0", info.BuildVersion);
        Assert.InRange(info.ServerTimeUtc, DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddMinutes(1));
        Assert.Equal(TimeSpan.Zero, info.ServerTimeUtc.Offset);
    }

    [Fact]
    public async Task Client_Throws_WithProblemDetails_OnErrorStatus()
    {
        await using var factory = ApiFactory.AllUp(stack);
        var http = factory.CreateClient();
        // A base address under a path the server doesn't serve turns every route into a 404.
        http.BaseAddress = new Uri(http.BaseAddress!, "no-such-prefix/");
        var client = new GameServerClient(http);

        var ex = await Assert.ThrowsAsync<GameServerApiException>(
            () => client.GetInfoAsync(TestContext.Current.CancellationToken));

        Assert.Equal(HttpStatusCode.NotFound, ex.StatusCode);
        Assert.NotNull(ex.Problem);
        Assert.Equal(404, ex.Problem.Status);
    }

    [Fact]
    public async Task UnknownRoute_Returns404ProblemDetails()
    {
        await using var factory = ApiFactory.AllUp(stack);
        var client = factory.CreateClient();

        var response = await client.GetAsync("/api/v1/does-not-exist", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
    }

    [Fact]
    public async Task Metrics_ExposesBuildInfoAndHttpHistogram()
    {
        await using var factory = ApiFactory.AllUp(stack);
        var client = factory.CreateClient();
        var ct = TestContext.Current.CancellationToken;
        await client.GetAsync("/api/v1/info", ct);
        await client.GetAsync("/health/ready", ct);

        // The HTTP histogram is recorded after the response completes, and the dependency gauge after the first
        // health publish (2 s), so poll briefly.
        var deadline = Stopwatch.StartNew();
        string metrics;
        do
        {
            await Task.Delay(500, ct);
            metrics = await client.GetStringAsync("/metrics", ct);
        } while (!(metrics.Contains("http_server_request_duration_seconds") && metrics.Contains("rpg_dependency_health"))
                 && deadline.Elapsed < TimeSpan.FromSeconds(20));

        var histogram = metrics.Split('\n')
            .Where(line => line.StartsWith("http_server_request_duration_seconds", StringComparison.Ordinal))
            .ToList();

        Assert.Contains("rpg_build_info{", metrics);
        Assert.Contains("service=\"rpg-game-server-api\"", metrics);
        Assert.Contains("rpg_dependency_health{", metrics);
        Assert.Contains(histogram, line => line.Contains("http_route=\"/api/v1/info\""));
        // Probes and scrapes are excluded from the HTTP histogram (other routing metrics may still name them).
        Assert.DoesNotContain(histogram, line => line.Contains("http_route=\"/health/"));
        Assert.DoesNotContain(histogram, line => line.Contains("http_route=\"/metrics\""));
    }
}
