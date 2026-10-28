namespace Rpg.Contracts.Presence;

/// <summary>POST /api/v1/presence: the heartbeat (every 30 s and on changes). A hint for live monitoring only.</summary>
public sealed record PresenceRequest(PresenceActivity Activity);

public enum PresenceActivity { Menu, Map, Battle }
