using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;

namespace Rpg.VerifierWorker.Tests;

/// <summary>
/// Spec run-verify 3.6, the real step runner's adapter: the command line, the exit-code mapping (0 Verified, 2 Rejected, 3
/// Malformed, 1 runner error) and the temp folder. The stub script stands in for godot; the real engine is exercised by the
/// e2e scenarios. Windows only, like the stub.
/// </summary>
[Collection("godot-stub")]
public class GodotStepRunnerTests : IDisposable
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
    public async Task ExitZero_WithAVerifiedResult_IsCompleted()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");

        var run = await Runner("step-verified").RunAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.Completed, run.Status);
        Assert.Equal((ReplayVerdict.Verified, "s", "e"), (run.Verdict!.Status, run.Verdict.StartHash, run.Verdict.EndHash));
    }

    [Fact]
    public async Task ExitTwo_WithARejectedResult_IsCompletedAs2002()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");

        var run = await Runner("step-rejected").RunAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.Completed, run.Status);
        Assert.Equal((ReplayVerdict.Rejected, 2002, StepMismatchReason.StateHashMismatch, 3),
            (run.Verdict!.Status, run.Verdict.ErrorCode, run.Verdict.Mismatch!.Reason, run.Verdict.Mismatch.Seq));
    }

    [Fact]
    public async Task ExitThree_WithAMalformedRequestResult_IsARejection_NeverARetry()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");

        var run = await Runner("malformed-step-result").RunAsync(Request, Ct);   // F7

        Assert.Equal(ReplayRunStatus.Completed, run.Status);
        Assert.Equal(ReplayVerdict.Rejected, run.Verdict!.Status);
        Assert.Equal(2002, run.Verdict.ErrorCode);
        Assert.Equal(StepMismatchReason.MalformedRequest, run.Verdict.Mismatch!.Reason);
    }

    [Theory]
    [InlineData("malformed")]               // a bare 3 with no result file: something else exited
    [InlineData("malformed-with-result")]   // a 3 whose result is some other rejection
    public async Task ExitThree_WithoutAMalformedRequestResult_IsARunnerError(string mode)
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");

        var run = await Runner(mode).RunAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.RunnerError, run.Status);
        Assert.Null(run.Verdict);
    }

    [Theory]
    [InlineData("crash", "exited with 1")]
    [InlineData("noresult", "does not match")]
    [InlineData("garbage", "unreadable result")]
    [InlineData("exit-mismatch", "unreadable result")]
    public async Task EverythingElse_IsARunnerError_NeverAVerdict(string mode, string detail)
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");

        var run = await Runner(mode).RunAsync(Request, Ct);

        Assert.Equal(ReplayRunStatus.RunnerError, run.Status);
        Assert.Null(run.Verdict);
        Assert.False(string.IsNullOrEmpty(run.Detail), detail);
    }

    [Fact]
    public async Task TheCommandLine_NamesTheStepScene_AndTheTempFolderIsRemoved()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "the stub is a Windows script");
        var log = Path.Combine(_folder, "args.txt");
        Environment.SetEnvironmentVariable("STUB_LOG", log);
        var before = TempFolders();

        await Runner("step-verified", contentRoot: "res://tests/fixtures/").RunAsync(Request, Ct);

        var line = (await File.ReadAllTextAsync(log, Ct)).Trim();
        Assert.StartsWith("--headless --path some/project --quit-after 777 res://game/verify/step_main.tscn -- --in ", line);
        Assert.EndsWith("--content-root res://tests/fixtures/", line);
        Assert.Equal(before, TempFolders());
    }

    private GodotStepRunner Runner(string mode, string contentRoot = "")
    {
        Environment.SetEnvironmentVariable("STUB_MODE", mode);
        var options = Options.Create(new VerifierOptions
        {
            GodotPath = Path.Combine(AppContext.BaseDirectory, "stubs", "godot-stub.cmd"),
            ProjectPath = "some/project",
            QuitAfterFrames = 777,
            ContentRoot = contentRoot,
        });
        return new GodotStepRunner(new GodotProcess(options, NullLogger<GodotProcess>.Instance), options);
    }

    private static int TempFolders() => Directory.GetDirectories(Path.GetTempPath(), "rpg-step-*").Length;
}
