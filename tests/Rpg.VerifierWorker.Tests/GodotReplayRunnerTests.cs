using System.Diagnostics;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Rpg.Contracts.Battle;

namespace Rpg.VerifierWorker.Tests;

/// <summary>
/// Spec battle-verify 6, the real-runner adapter: the command line, the exit-code mapping (0 Verified, 2 Rejected, 1
/// runner error), the timeout that kills the process tree, and the temp folder. A stub script stands in for godot (its
/// mode comes from STUB_MODE); the real engine is exercised by the e2e scenarios and the image check. Windows only, like
/// the stub.
/// </summary>
[Collection("godot-stub")]
public class GodotReplayRunnerTests : IDisposable
{
    private readonly string _folder = Directory.CreateTempSubdirectory("rpg-stub-").FullName;
    private const string Request = """{"snapshot":{"battleId":"run-1/f0/c5"},"actionLog":{"entries":[]}}""";

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
    public async Task ExitZero_WithAVerifiedResult_IsCompleted()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var run = await Runner("verified").ReplayAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.Completed, run.Status);
        Assert.Equal(ReplayVerdict.Verified, run.Result!.Verdict);
        Assert.Equal("run-1/f0/c5", run.Result.BattleId);
    }

    [Fact]
    public async Task ExitTwo_WithARejectedResult_IsCompletedAs2002()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var run = await Runner("rejected").ReplayAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.Completed, run.Status);
        Assert.Equal(ReplayVerdict.Rejected, run.Result!.Verdict);
        Assert.Equal(2002, run.Result.ErrorCode);
        Assert.Equal(MismatchReason.TurnMismatch, run.Result.Mismatch!.Reason);
    }

    [Theory]
    [InlineData("crash", "exited with 1")]
    [InlineData("noresult", "wrote no result")]
    [InlineData("garbage", "unreadable result")]
    [InlineData("exit-mismatch", "does not match")]
    public async Task EverythingElse_IsARunnerError_NeverAVerdict(string mode, string detail)
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var run = await Runner(mode).ReplayAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.RunnerError, run.Status);
        Assert.Null(run.Result);
        Assert.Contains(detail, run.Detail);
    }

    [Fact]
    public async Task AMissingExecutable_IsARunnerError()
    {
        var run = await new GodotReplayRunner(
            Options.Create(new VerifierOptions { GodotPath = Path.Combine(_folder, "no-such-godot.exe") }),
            NullLogger<GodotReplayRunner>.Instance).ReplayAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.RunnerError, run.Status);
        Assert.Contains("could not start", run.Detail);
    }

    [Fact]
    public async Task AHangingReplay_IsKilledWithItsProcessTree_AtTheTimeout()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var pidFile = Path.Combine(_folder, "pid.txt");
        Environment.SetEnvironmentVariable("STUB_PID", pidFile);
        var started = Stopwatch.StartNew();

        var run = await Runner("hang", timeout: TimeSpan.FromSeconds(4)).ReplayAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.TimedOut, run.Status);  // F7
        Assert.True(started.Elapsed < TimeSpan.FromSeconds(30), $"took {started.Elapsed}");
        var pid = int.Parse((await File.ReadAllTextAsync(pidFile, Ct)).Trim());
        await Task.Delay(500, Ct);
        Assert.Throws<ArgumentException>(() => Process.GetProcessById(pid));  // the child powershell is gone too
    }

    [Fact]
    public async Task TheGodotProcess_IsSampledForCpuAndMemory_EvenWhenItIsKilledAtTheTimeout()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        Environment.SetEnvironmentVariable("STUB_PID", Path.Combine(_folder, "pid.txt"));

        var run = await Runner("hang", timeout: TimeSpan.FromSeconds(2)).ReplayAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.TimedOut, run.Status);
        Assert.NotNull(run.Usage);
        Assert.True(run.Usage.PeakMemoryBytes > 0);
        Assert.True(run.Usage.CpuTime >= TimeSpan.Zero);
    }

    [Fact]
    public async Task AVerdict_CarriesTheProcessUsage()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var run = await Runner("verified").ReplayAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.Completed, run.Status);
        // A stub that exits within one sample interval may be missed: the usage is then null, never wrong.
        Assert.True(run.Usage is null || run.Usage.PeakMemoryBytes > 0);
    }

    [Fact]
    public async Task TheCommandLine_FollowsTheClientGodotClaudeMd_AndTheTempFolderIsRemoved()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var log = Path.Combine(_folder, "args.txt");
        Environment.SetEnvironmentVariable("STUB_LOG", log);
        var before = TempFolders();

        await Runner("verified", contentRoot: "res://tests/fixtures/").ReplayAsync(Request, Ct);

        var line = (await File.ReadAllTextAsync(log, Ct)).Trim();
        Assert.StartsWith("--headless --path some/project --quit-after 777 res://combat/headless/replay_main.tscn -- --in ", line);
        Assert.Contains(" --out ", line);
        Assert.EndsWith("--content-root res://tests/fixtures/", line);
        Assert.Equal(before, TempFolders());
    }

    [Fact]
    public async Task TheRulesetVersion_IsTheLastVersionLineGodotPrints()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var version = await Runner("version").RulesetVersionAsync(Ct);

        Assert.Equal("4.7.2.stable.mono+0123456789abcdef", version);
    }

    [Fact]
    public async Task TheRulesetVersion_IgnoresOtherLinesThatContainAPlus()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var version = await Runner("version-noisy").RulesetVersionAsync(Ct);

        Assert.Equal("4.7.2.stable.mono+0123456789abcdef", version);
    }

    [Fact]
    public async Task TheRulesetVersion_FailsLoudlyWhenGodotDoesNotPrintOne()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");

        await Assert.ThrowsAsync<InvalidOperationException>(() => Runner("crash").RulesetVersionAsync(Ct));
    }

    private GodotReplayRunner Runner(string mode, TimeSpan? timeout = null, string contentRoot = "")
    {
        Environment.SetEnvironmentVariable("STUB_MODE", mode);
        return new GodotReplayRunner(Options.Create(new VerifierOptions
        {
            GodotPath = Path.Combine(AppContext.BaseDirectory, "stubs", "godot-stub.cmd"),
            ProjectPath = "some/project",
            QuitAfterFrames = 777,
            ProcessTimeout = timeout ?? TimeSpan.FromSeconds(60),
            ContentRoot = contentRoot,
        }), NullLogger<GodotReplayRunner>.Instance);
    }

    private static int TempFolders() => Directory.GetDirectories(Path.GetTempPath(), "rpg-verify-*").Length;
}
