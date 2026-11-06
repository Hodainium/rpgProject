namespace Rpg.Contracts.Economy;

/// <summary>GET /api/v1/wallet (spec settlement-outbox 2.4): the player's gems and their last ledger rows.</summary>
public sealed record WalletResponse(int Gems, long Version, IReadOnlyList<LedgerEntryDto> Recent);

public sealed record LedgerEntryDto(string Currency, int Delta, string Reason, string? RefBattleId, DateTimeOffset At,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] int? RuleVersion = null,  // null on rows written before slice 4c (spec economy-rewards 3.1)
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] string? ChallengeId = null, [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] string? CycleKey = null);  // spec economy-challenges 3.1; null on older rows
