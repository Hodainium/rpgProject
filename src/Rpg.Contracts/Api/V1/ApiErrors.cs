namespace Rpg.Contracts.Api.V1;

/// <summary>
/// Error codes carried as <c>errorCode</c> in ProblemDetails (HTTP 4xx), spec server-authority 3.1.
/// 2002 stays the replay verdict only and is never one of these.
/// </summary>
public static class ApiErrors
{
    public const int RulesetMismatch = 1001;          // 409: the client's ruleset_version isn't accepted
    public const int RunNotActive = 1101;             // 409
    public const int SequenceGap = 1102;              // 409, extension `expectedSeq`
    public const int SequenceConflict = 1103;         // 409: same seq, different body
    public const int FloorNotReachable = 1105;        // 409: not the current floor or the next one
    public const int UploadIncomplete = 1106;         // 409, extension `lastSeq`: stairs or end before the log is in
    public const int PreviousFloorUnverified = 1107;  // 409 + Retry-After: the floor just played is not verified yet (spec run-verify 2.6)
    public const int RunRolledBack = 1108;            // 409, extensions `epoch`, `rollbackSeq`, `reason`: the verifier rolled the run back (spec run-verify 2.4)
    public const int RewardRuleInvalid = 1301;        // 400: unknown kind or currency, amount out of range, bad id
    public const int AdminRequired = 1302;            // 403: the economy-admin role is missing
    public const int RewardTargetUnknown = 1303;      // 404: a cycle reset for a challenge with no rule, or a player that does not exist
    // Spec card-collection 3.1: card economy (plain request errors, not verdicts).
    public const int CardRuleInvalid = 1401;          // 400: bad odds sum, unknown rarity or set, craft cost not above dust value, amount out of range
    public const int InsufficientCurrency = 1402;     // 409: not enough gems (pack) or dust (craft)
    public const int CardLockedByRun = 1403;          // 409, extensions `runId`, `runStatus`: dust refused by the run lock
    public const int CardNotCollectible = 1404;       // 400: unknown card, or a core card (cannot be dusted or crafted)
    public const int CardAlreadyOwned = 1405;         // 409: craft of a card already held
    public const int CardNotOwned = 1406;             // 409: dust of a card not held
    public const int RequestKeyReused = 1407;         // 409: the key was used for a different action or body
    public const int PackUnavailable = 1408;          // 404: unknown or retired pack type
    public const int CharacterLocked = 1409;          // 400: run start with a character the account does not own
    public const int RunVerifying = 1410;             // 409: abandon refused, a won run is waiting for its verdict
    public const int RateLimited = 1201;              // 429 + Retry-After
}
