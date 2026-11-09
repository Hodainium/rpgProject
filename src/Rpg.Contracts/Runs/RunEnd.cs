using System.Text.Json;

namespace Rpg.Contracts.Runs;

/// <summary>POST /api/v1/runs/{runId}/end (spec server-authority 2.3). Seq is the end's own seq (last_seq + 1).
/// A Lost run may also travel as a queued <c>end</c> action.</summary>
/// <param name="RunHash">The client's final run hash.</param>
/// <param name="Snapshot">The RunSnapshot JSON at the end (an object with <c>schemaVersion</c> 1).</param>
/// <param name="Epoch">Spec run-verify 3.1: the epoch the client last saw; stale = 409 1108. Omitted when 0.</param>
public sealed record RunEndRequest(int Seq, RunEndStatus Status, string RunHash, JsonElement Snapshot,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingDefault)] int Epoch = 0);

public enum RunEndStatus { Won, Lost }

/// <summary>202 while the run is Verifying; 200 once its status is final (Lost, or Won).</summary>
public sealed record RunEndResponse(string RunId, RunStatus Status);
