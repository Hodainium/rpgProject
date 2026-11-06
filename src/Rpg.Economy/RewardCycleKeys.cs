using System.Globalization;
using Rpg.Contracts.Economy;

namespace Rpg.Economy;

/// <summary>The cycle key of a mark (spec economy-challenges 1.1, 2.3): a key, never a delete, so a reset is "a new key has no mark yet".</summary>
public static class RewardCycleKeys
{
    /// <summary><c>once</c>, or <c>2026-W45</c> (ISO 8601 week in UTC, from <paramref name="at"/>), plus <c>.r&lt;global&gt;</c> and <c>.p&lt;player&gt;</c> when above 0.</summary>
    public static string Compute(string cycle, DateTimeOffset at, int globalGeneration, int playerGeneration)
    {
        var utc = at.UtcDateTime;
        var key = cycle == RewardCycles.Weekly
            ? string.Create(CultureInfo.InvariantCulture, $"{ISOWeek.GetYear(utc):D4}-W{ISOWeek.GetWeekOfYear(utc):D2}")
            : RewardCycles.Once;
        if (globalGeneration > 0)
        {
            key += string.Create(CultureInfo.InvariantCulture, $".r{globalGeneration}");
        }

        if (playerGeneration > 0)
        {
            key += string.Create(CultureInfo.InvariantCulture, $".p{playerGeneration}");
        }

        return key;
    }
}
