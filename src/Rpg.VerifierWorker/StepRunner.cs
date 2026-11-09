using System.Text.Json;
using Microsoft.Extensions.Options;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;

namespace Rpg.VerifierWorker;

/// <summary>One Godot step run: a verdict (exit 0, 2 or 3), or a runner error that is retried.</summary>
public sealed record StepRun(ReplayRunStatus Status, StepVerdict? Verdict, string Detail, ReplayUsage? Usage = null);

/// <summary>Runs one step. The real one starts headless Godot; tests use a fake (spec run-verify 6).</summary>
public interface IStepRunner
{
    /// <param name="requestJson">A <c>StepRequest</c>, built from Postgres.</param>
    Task<StepRun> RunAsync(string requestJson, CancellationToken ct);
}

/// <summary>
/// <c>godot --headless --path P --quit-after N res://game/verify/step_main.tscn -- --in req.json --out res.json</c>
/// (spec run-verify 3.6). Exit 0 Verified, 2 Rejected, 3 Malformed (a Rejected verdict at once), 1 runner error. It shares
/// the process handling (timeout, process tree kill, usage sampling) with <see cref="GodotProcess"/>.
/// </summary>
public sealed class GodotStepRunner(GodotProcess process, IOptions<VerifierOptions> options) : IStepRunner
{
    public const string StepScene = "res://game/verify/step_main.tscn";
    public const int ExitMalformed = 3;

    public async Task<StepRun> RunAsync(string requestJson, CancellationToken ct)
    {
        var settings = options.Value;
        var directory = Directory.CreateTempSubdirectory("rpg-step-");
        try
        {
            var input = Path.Combine(directory.FullName, "req.json");
            var output = Path.Combine(directory.FullName, "res.json");
            await File.WriteAllTextAsync(input, requestJson, ct);

            List<string> arguments =
            [
                "--headless", "--path", settings.ProjectPath, "--quit-after", settings.QuitAfterFrames.ToString(),
                StepScene, "--", "--in", input, "--out", output,
            ];
            if (settings.ContentRoot.Length > 0)
            {
                arguments.AddRange(["--content-root", settings.ContentRoot]);
            }

            var (exitCode, status, detail, _, usage) = await process.RunWithOutputAsync(arguments, settings.Segment.ProcessTimeout, ct);
            if (status != ReplayRunStatus.Completed)
            {
                return new StepRun(status, null, detail, usage);
            }

            if (exitCode is not (0 or 2 or ExitMalformed))
            {
                return new StepRun(ReplayRunStatus.RunnerError, null, $"godot exited with {exitCode}: {detail}", usage);
            }

            StepVerdict? verdict = null;
            if (File.Exists(output))
            {
                try
                {
                    verdict = JsonSerializer.Deserialize<StepVerdict>(await File.ReadAllTextAsync(output, ct), RpgJson.Options);
                }
                catch (JsonException ex)
                {
                    return new StepRun(ReplayRunStatus.RunnerError, null, $"unreadable result: {ex.Message}", usage);
                }
            }

            var expected = exitCode == 0 ? ReplayVerdict.Verified : ReplayVerdict.Rejected;
            if (verdict is null || verdict.Status != expected)
            {
                return new StepRun(ReplayRunStatus.RunnerError, null,
                    $"exit code {exitCode} does not match the result's verdict {verdict?.Status}", usage);
            }

            // Exit 3 is a verdict only when the runner's own result says MalformedRequest (see GodotProcess): a bare 3 is
            // an infrastructure fault, retried, never a rejection of the player (closes battle-verify 8.1).
            if (exitCode == ExitMalformed && verdict.Mismatch?.Reason != StepMismatchReason.MalformedRequest)
            {
                return new StepRun(ReplayRunStatus.RunnerError, null,
                    $"godot exited with 3 but its result is not a MalformedRequest rejection ({verdict.Mismatch?.Reason})", usage);
            }

            return new StepRun(ReplayRunStatus.Completed, verdict, "", usage);
        }
        finally
        {
            try
            {
                directory.Delete(recursive: true);
            }
            catch (IOException)
            {
                // A temp folder left behind is harmless.
            }
        }
    }

}
