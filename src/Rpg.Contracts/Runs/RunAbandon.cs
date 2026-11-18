namespace Rpg.Contracts.Runs;

/// <summary>
/// Body of POST /api/v1/runs/{runId}/abandon (spec account-session 3.1; the dust path's cancel, spec card-collection 2.3). Session
/// is the player's current account session: an older one is refused (409 1412), so a stale device cannot cancel a run. Required;
/// nullable only so a missing one is told apart from 0.
/// </summary>
public sealed record RunAbandonRequest(long? Session);
