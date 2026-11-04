namespace Rpg.Contracts.Economy;

/// <summary>GET /api/v1/wallet (spec settlement-outbox 2.4): the player's gems and their last ledger rows.</summary>
public sealed record WalletResponse(int Gems, long Version, IReadOnlyList<LedgerEntryDto> Recent);

public sealed record LedgerEntryDto(string Currency, int Delta, string Reason, string? RefBattleId, DateTimeOffset At);
