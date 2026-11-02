using System.Diagnostics;
using System.Text.Json;
using Microsoft.Extensions.Options;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Serialization;

namespace Rpg.VerifierWorker;

public enum ReplayRunStatus
{
    /// <summary>A verdict: exit 0 (Verified) or 2 (Rejected, 2002) with a readable result.</summary>
    Completed,

    /// <summary>Exit 1, a crash, or no usable result: never a verdict, so the job is retried.</summary>
    RunnerError,

    TimedOut,
}

/// <summary>What one Godot process cost: its CPU time and its peak working set, sampled while it ran.</summary>
public sealed record ReplayUsage(TimeSpan CpuTime, long PeakMemoryBytes);

public sealed record ReplayRun(ReplayRunStatus Status, ReplayResult? Result, string Detail, ReplayUsage? Usage = null);

/// <summary>Runs one replay. The real one starts headless Godot; tests use a fake (spec battle-verify 6).</summary>
public interface IReplayRunner
{
    /// <param name="requestJson">A <c>ReplayRequest</c>: the battle's conditions and action log.</param>
    Task<ReplayRun> ReplayAsync(string requestJson, CancellationToken ct);

    /// <summary>The ruleset version of the project this runner replays with (asked once, at startup).</summary>
    Task<string> RulesetVersionAsync(CancellationToken ct);
}

/// <summary>
/// <c>godot --headless --path P --quit-after N res://combat/headless/replay_main.tscn -- --in req.json --out res.json</c>
/// (client-godot/CLAUDE.md section 4). Exit 0 Verified, 2 Rejected, 1 runner error. The process tree is killed at the
/// timeout.
/// </summary>
public sealed partial class GodotReplayRunner(IOptions<VerifierOptions> options, ILogger<GodotReplayRunner> logger) : IReplayRunner
{
    private const string ReplayScene = "res://combat/headless/replay_main.tscn";
    private const string RulesetScene = "res://game/tools/print_ruleset_version.tscn";

    public async Task<ReplayRun> ReplayAsync(string requestJson, CancellationToken ct)
    {
        var settings = options.Value;
        var directory = Directory.CreateTempSubdirectory("rpg-verify-");
        try
        {
            var input = Path.Combine(directory.FullName, "req.json");
            var output = Path.Combine(directory.FullName, "res.json");
            await File.WriteAllTextAsync(input, requestJson, ct);

            List<string> arguments =
            [
                "--headless", "--path", settings.ProjectPath, "--quit-after", settings.QuitAfterFrames.ToString(),
                ReplayScene, "--", "--in", input, "--out", output,
            ];
            if (settings.ContentRoot.Length > 0)
            {
                arguments.AddRange(["--content-root", settings.ContentRoot]);
            }

            var (exitCode, status, detail, _, usage) = await RunWithOutputAsync(arguments, settings.ProcessTimeout, ct);
            if (status != ReplayRunStatus.Completed)
            {
                return new ReplayRun(status, null, detail, usage);
            }

            if (exitCode is not (0 or 2))
            {
                return new ReplayRun(ReplayRunStatus.RunnerError, null, $"godot exited with {exitCode}: {detail}", usage);
            }

            if (!File.Exists(output))
            {
                return new ReplayRun(ReplayRunStatus.RunnerError, null, $"godot exited with {exitCode} and wrote no result", usage);
            }

            ReplayResult? result;
            try
            {
                result = JsonSerializer.Deserialize<ReplayResult>(await File.ReadAllTextAsync(output, ct), RpgJson.Options);
            }
            catch (JsonException ex)
            {
                return new ReplayRun(ReplayRunStatus.RunnerError, null, $"unreadable result: {ex.Message}", usage);
            }

            var expected = exitCode == 0 ? ReplayVerdict.Verified : ReplayVerdict.Rejected;
            return result is null || result.Verdict != expected
                ? new ReplayRun(ReplayRunStatus.RunnerError, null,
                    $"exit code {exitCode} does not match the result's verdict {result?.Verdict}", usage)
                : new ReplayRun(ReplayRunStatus.Completed, result, "", usage);
        }
        finally
        {
            try
            {
                directory.Delete(recursive: true);
            }
            catch (IOException ex)
            {
                logger.LogDebug("Temp folder {Path} not removed: {Message}", directory.FullName, ex.Message);
            }
        }
    }

    public async Task<string> RulesetVersionAsync(CancellationToken ct)
    {
        var settings = options.Value;
        var (exitCode, status, detail, stdout, _) = await RunWithOutputAsync(
            ["--headless", "--path", settings.ProjectPath, "--quit-after", "3000", RulesetScene],
            TimeSpan.FromSeconds(120), ct);
        var line = stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .LastOrDefault(l => VersionLine().IsMatch(l));
        return status == ReplayRunStatus.Completed && exitCode == 0 && line is not null
            ? line
            : throw new InvalidOperationException($"Could not read the ruleset version from godot (exit {exitCode}): {detail}");
    }

    /// <summary>
    /// "4.7.2.stable.mono+0123456789abcdef": the engine version, a plus, 16 hex digits (spec server-authority 3.5). Only a
    /// whole stdout line of this shape counts, so a warning that happens to contain a plus is never mistaken for it.
    /// </summary>
    [System.Text.RegularExpressions.GeneratedRegex(@"^[0-9]+(\.[0-9]+)+(\.[a-z]+)+\+[0-9a-f]{16}$")]
    private static partial System.Text.RegularExpressions.Regex VersionLine();

    /// <summary>Starts godot, returns its exit code, its output (for messages) and its stdout alone; kills the tree at the timeout.</summary>
    private async Task<(int ExitCode, ReplayRunStatus Status, string Detail, string Stdout, ReplayUsage? Usage)> RunWithOutputAsync(
        IEnumerable<string> arguments, TimeSpan timeout, CancellationToken ct)
    {
        var info = new ProcessStartInfo(options.Value.GodotPath)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments)
        {
            info.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = info };
        try
        {
            process.Start();
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return (-1, ReplayRunStatus.RunnerError, $"godot could not start: {ex.Message}", "", null);
        }

        using var sampling = new CancellationTokenSource();
        var sampler = SampleUsageAsync(process, sampling.Token);
        var output = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var errors = process.StandardError.ReadToEndAsync(CancellationToken.None);
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(timeout);
        try
        {
            await process.WaitForExitAsync(limit.Token);
        }
        catch (OperationCanceledException)
        {
            Kill(process);
            sampling.Cancel();
            var killedUsage = await sampler;
            if (ct.IsCancellationRequested)
            {
                throw;
            }

            logger.LogWarning("godot passed the {Timeout} limit and was killed", timeout);
            return (-1, ReplayRunStatus.TimedOut, $"killed after {timeout}", "", killedUsage);
        }

        // The pipes close with the process; a grandchild keeping them open must not hold the job.
        await Task.WhenAny(Task.WhenAll(output, errors), Task.Delay(TimeSpan.FromSeconds(5), CancellationToken.None));
        var stdout = output.IsCompletedSuccessfully ? output.Result : "";
        var text = stdout + (errors.IsCompletedSuccessfully ? errors.Result : "");
        sampling.Cancel();
        return (process.ExitCode, ReplayRunStatus.Completed, text.Trim(), stdout, await sampler);
    }

    /// <summary>
    /// Polls the godot process every 200 ms and keeps the highest CPU time and working set seen. The OS forgets a process's
    /// numbers when it exits (Linux at once), so they are taken while it runs: a run can be under-counted by its last
    /// 200 ms, never over-counted. Null when it ended before the first sample.
    /// </summary>
    private static async Task<ReplayUsage?> SampleUsageAsync(Process process, CancellationToken stop)
    {
        ReplayUsage? best = null;
        while (!stop.IsCancellationRequested)
        {
            try
            {
                process.Refresh();
                var cpu = process.TotalProcessorTime;
                var memory = Math.Max(process.PeakWorkingSet64, process.WorkingSet64);
                best = new ReplayUsage(
                    best is null ? cpu : TimeSpan.FromTicks(Math.Max(best.CpuTime.Ticks, cpu.Ticks)),
                    Math.Max(best?.PeakMemoryBytes ?? 0, memory));
            }
            catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException)
            {
                return best;
            }

            try
            {
                await Task.Delay(200, stop);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        return best;
    }

    private static void Kill(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit(5000);
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // Already gone.
        }
    }
}
