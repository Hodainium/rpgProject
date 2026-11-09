using Microsoft.Extensions.Options;
using Npgsql;
using Rpg.GameServerApi.Migrations;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.Presence;

namespace Rpg.GameServerApi.Cards;

/// <summary>Recomputes rpg_cards_owned from Postgres every <c>Monitors:Interval</c> (spec card-collection 5).</summary>
public sealed class CardsOwnedMonitor(NpgsqlDataSource dataSource, MigrationRunner migrations, RpgMetrics metrics,
    IOptions<MonitorOptions> options, ILogger<CardsOwnedMonitor> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(options.Value.Interval);
        do
        {
            try
            {
                await migrations.EnsureMigratedAsync(stoppingToken);
                await using var command = dataSource.CreateCommand("SELECT count(*) FROM card_holdings");
                metrics.SetCardsOwned((long)(await command.ExecuteScalarAsync(stoppingToken))!);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogDebug("Cards owned not counted: {Message}", ex.Message);
            }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
