using System.Diagnostics;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Rpg.VerifierWorker.Tests;

/// <summary>
/// The Godot process host (spec battle-verify 6, kept for run-verify): the timeout that kills the process tree, the CPU and
/// memory sampling and the ruleset version lookup. A stub script stands in for godot (its mode comes from STUB_MODE); the
/// exit-code mapping is GodotStepRunnerTests, the real engine the e2e scenarios and the image check. Windows only, like the stub.
/// </summary>
[Collection("godot-stub")]
public class GodotProcessTests : IDisposable
{
    private readonly string _folder = Directory.CreateTempSubdirectory("rpg-stub-").FullName;
    private const string Request = """{"schemaVersion":1,"runId":"r","kind":"Segment"}""";

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    public void Dispose()
    {
        foreach (var name in new[] { "STUB_MODE", "STUB_LOG", "STUB_PID" })
        {
            Environment.SetEnvironmentVariable(name, null);
        }

        Directory.Delete(_folder, recursive: true);
    }

    [Fact]
    public async Task AMissingExecutable_IsARunnerError()
    {
        var options = Options.Create(new VerifierOptions { GodotPath = Path.Combine(_folder, "no-such-godot.exe") });
        var run = await new GodotStepRunner(new GodotProcess(options, NullLogger<GodotProcess>.Instance), options).RunAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.RunnerError, run.Status);
        Assert.Contains("could not start", run.Detail);
    }

    [Fact]
    public async Task AHangingProcess_IsKilledWithItsProcessTree_AtTheTimeout()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var pidFile = Path.Combine(_folder, "pid.txt");
        Environment.SetEnvironmentVariable("STUB_PID", pidFile);
        var started = Stopwatch.StartNew();

        var run = await Runner("hang", timeout: TimeSpan.FromSeconds(4)).RunAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.TimedOut, run.Status);  // F7
        Assert.True(started.Elapsed < TimeSpan.FromSeconds(30), $"took {started.Elapsed}");
        var pid = int.Parse((await File.ReadAllTextAsync(pidFile, Ct)).Trim());
        await Task.Delay(500, Ct);
        Assert.Throws<ArgumentException>(() => System.Diagnostics.Process.GetProcessById(pid));  // the child powershell is gone too
    }

    [Fact]
    public async Task TheGodotProcess_IsSampledForCpuAndMemory_EvenWhenItIsKilledAtTheTimeout()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        Environment.SetEnvironmentVariable("STUB_PID", Path.Combine(_folder, "pid.txt"));

        var run = await Runner("hang", timeout: TimeSpan.FromSeconds(2)).RunAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.TimedOut, run.Status);
        Assert.NotNull(run.Usage);
        Assert.True(run.Usage.PeakMemoryBytes > 0);
        Assert.True(run.Usage.CpuTime >= TimeSpan.Zero);
    }

    [Fact]
    public async Task AVerdict_CarriesTheProcessUsage()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var run = await Runner("step-verified").RunAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.Completed, run.Status);
        // A stub that exits within one sample interval may be missed: the usage is then null, never wrong.
        Assert.True(run.Usage is null || run.Usage.PeakMemoryBytes > 0);
    }

    [Fact]
    public async Task TheRulesetVersion_IsTheLastVersionLineGodotPrints()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var version = await HostFor("version").RulesetVersionAsync(Ct);

        Assert.Equal("4.7.2.stable.mono+0123456789abcdef", version);
    }

    [Fact]
    public async Task TheRulesetVersion_IgnoresOtherLinesThatContainAPlus()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var version = await HostFor("version-noisy").RulesetVersionAsync(Ct);

        Assert.Equal("4.7.2.stable.mono+0123456789abcdef", version);
    }

    [Fact]
    public async Task TheRulesetVersion_FailsLoudlyWhenGodotDoesNotPrintOne()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");

        await Assert.ThrowsAsync<InvalidOperationException>(() => HostFor("crash").RulesetVersionAsync(Ct));
    }

    private IOptions<VerifierOptions> Settings(string mode, TimeSpan? timeout = null)
    {
        Environment.SetEnvironmentVariable("STUB_MODE", mode);
        return Options.Create(new VerifierOptions
        {
            GodotPath = Path.Combine(AppContext.BaseDirectory, "stubs", "godot-stub.cmd"),
            ProjectPath = "some/project",
            QuitAfterFrames = 777,
            Segment = new SegmentOptions { ProcessTimeout = timeout ?? TimeSpan.FromSeconds(60) },
        });
    }

    private GodotProcess HostFor(string mode) => new(Settings(mode), NullLogger<GodotProcess>.Instance);

    private GodotStepRunner Runner(string mode, TimeSpan? timeout = null)
    {
        var options = Settings(mode, timeout);
        return new GodotStepRunner(new GodotProcess(options, NullLogger<GodotProcess>.Instance), options);
    }
}
