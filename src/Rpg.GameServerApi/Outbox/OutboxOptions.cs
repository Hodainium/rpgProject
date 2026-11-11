namespace Rpg.GameServerApi.Outbox;

/// <summary>Configuration section <c>Outbox</c> (spec settlement-outbox 3.7).</summary>
public sealed class OutboxOptions
{
    public const string Section = "Outbox";

    /// <summary>False pauses the relay (tests that need rows to stay unpublished); rows still accumulate.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>How long the relay sleeps when a poll found nothing.</summary>
    public TimeSpan PollInterval { get; set; } = TimeSpan.FromMilliseconds(250);

    public int BatchSize { get; set; } = 50;

    /// <summary>A leased row is invisible to other relays for this long (a crashed relay's rows come back after it).</summary>
    public TimeSpan Lease { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Transient failures after which a Redpanda row is dead-lettered. RabbitMQ rows are never dead-lettered for
    /// transient failures: a verify job must not be lost to a long broker outage. 0 = unlimited, the default since the review
    /// fix of 2026-11-09: with 20 the backoff dead-lettered every pending event after about 15 minutes of Redpanda being down,
    /// against acceptance scenario 3 ("no lost events once it's back"). A row still never overtakes an earlier one of its key,
    /// a permanent error still dead-letters at once, and POST /api/v1/admin/outbox/redrive brings dead-lettered rows back.
    /// </summary>
    public int MaxAttempts { get; set; }

    public TimeSpan BackoffBase { get; set; } = TimeSpan.FromSeconds(1);

    public TimeSpan BackoffCap { get; set; } = TimeSpan.FromSeconds(60);

    /// <summary>How long a Redpanda produce may take before it counts as a transient failure.</summary>
    public TimeSpan KafkaMessageTimeout { get; set; } = TimeSpan.FromSeconds(10);

    public TimeSpan Backoff(int attempts)
    {
        var exponent = Math.Clamp(attempts - 1, 0, 20);
        var seconds = BackoffBase.TotalSeconds * Math.Pow(2, exponent);
        return TimeSpan.FromSeconds(Math.Min(seconds, BackoffCap.TotalSeconds));
    }
}

/// <summary>Configuration section <c>Kafka</c>: where Redpanda listens.</summary>
public sealed class KafkaOptions
{
    public const string Section = "Kafka";

    public string BootstrapServers { get; set; } = "localhost:19092";
}
