namespace Rpg.Contracts.Economy;

/// <summary>How often a challenge's ladder can pay again (spec economy-challenges 1.1). The reset is fixed, never per challenge.</summary>
public static class RewardCycles
{
    public const string Once = "once";
    public const string Weekly = "weekly";  // the ISO 8601 week in UTC, Monday 00:00
}

/// <summary>
/// PUT /api/v1/admin/reward-rules (economy-admin): a whole new version of one challenge's ladder (spec economy-challenges 2.1).
/// A plain completion is a ladder with one tier.
/// </summary>
/// <param name="ChallengeId">The one reward key: 1–200 characters, no ':' and no whitespace. A boss's is "boss/" + its id.</param>
/// <param name="Currency">"gems".</param>
/// <param name="Tiers">The amount each tier pays (index 0 = tier 1): plain whole numbers (not x100), each 1..Economy:MaxRewardAmount. Empty retires the challenge.</param>
/// <param name="Cycle"><see cref="RewardCycles"/>.</param>
/// <param name="EndsAt">Null = never expires. Otherwise a battle submitted at or after it pays nothing; must be in the future when set.</param>
public sealed record RewardRuleRequest(string ChallengeId, string Currency,
    [property: System.Text.Json.Serialization.JsonRequired] IReadOnlyList<int> Tiers,  // required: an omitted ladder must not become "retire"
    string Cycle = RewardCycles.Once, [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] DateTimeOffset? EndsAt = null);

/// <summary>One version of a ladder; the response of PUT and each item of GET.</summary>
/// <param name="Generation">The challenge's global reset generation (0 = never reset for everyone).</param>
public sealed record RewardRuleResponse(string ChallengeId, string Currency, IReadOnlyList<int> Tiers, string Cycle,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] DateTimeOffset? EndsAt, int Generation, int Version, DateTimeOffset EffectiveFrom, string CreatedBy);

/// <summary>The latest version per challenge.</summary>
public sealed record RewardRuleListResponse(IReadOnlyList<RewardRuleResponse> Rules);

/// <summary>POST /api/v1/admin/reward-cycles/reset (economy-admin): the next clear pays the ladder again.</summary>
/// <param name="PlayerId">Null = everyone; otherwise only that player.</param>
public sealed record RewardCycleResetRequest(string ChallengeId, [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] Guid? PlayerId = null, [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] string? Reason = null);

public sealed record RewardCycleResetResponse(string ChallengeId, [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] Guid? PlayerId, int Generation, DateTimeOffset ResetAt, string ResetBy);
