using Npgsql;

namespace Rpg.VerifierWorker;

public static class WorkerServices
{
    /// <summary>
    /// Registers the worker (spec battle-verify 2.3). Tests call this and then replace <see cref="IReplayRunner"/> with a
    /// fake; Program adds the host around it.
    /// </summary>
    public static IServiceCollection AddVerifierWorker(this IServiceCollection services)
    {
        services.AddOptions<VerifierOptions>().BindConfiguration(VerifierOptions.Section);
        services.AddOptions<SettlementOptions>().BindConfiguration(SettlementOptions.Section);
        services.AddSingleton(TimeProvider.System);
        services.AddSingleton(sp => NpgsqlDataSource.Create(
            sp.GetRequiredService<IConfiguration>().GetConnectionString("Postgres")
            ?? throw new InvalidOperationException("ConnectionStrings:Postgres is not configured.")));
        services.AddSingleton<VerdictStore>();
        services.AddSingleton<VerifierRedis>();
        services.AddSingleton<WorkerMetrics>();
        services.AddSingleton<WorkerState>();
        services.AddSingleton<IReplayRunner, GodotReplayRunner>();
        services.AddSingleton<VerifyProcessor>();
        services.AddSingleton<VerifyConsumer>();
        services.AddHostedService(sp => sp.GetRequiredService<VerifyConsumer>());
        return services;
    }
}
