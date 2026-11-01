using Rpg.Contracts.Battle;

namespace Rpg.Verification;

/// <summary>A battle session as stored, with the run's owner (for the 404 rule and the Redis caches).</summary>
public sealed record StoredBattle(Guid PlayerId, BattleSessionResponse Session);
