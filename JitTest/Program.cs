using System.Runtime.CompilerServices;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/problem", () =>
{
    bool running = true;
    Thread thread = new(() => JustRunning(ref running));
    thread.Start();
    Thread.Sleep(200);
    running = false;
    bool exited = thread.Join(TimeSpan.FromSeconds(2));
    return new { exited, stuck = !exited };
});

app.MapGet("/noproblem", () =>
{
    bool running = true;
    Thread thread = new(() => RunWithVolatile(ref running));
    thread.Start();
    Thread.Sleep(200);
    Volatile.Write(ref running, false);
    bool exited = thread.Join(TimeSpan.FromSeconds(2));
    return new { exited, stuck = !exited };
});

await app.RunAsync();

[MethodImpl(MethodImplOptions.AggressiveOptimization | MethodImplOptions.NoInlining)]
static void JustRunning(ref bool running)
{
    while (running) { }
}

[MethodImpl(MethodImplOptions.AggressiveOptimization | MethodImplOptions.NoInlining)]
static void RunWithVolatile(ref bool running)
{
    while (Volatile.Read(ref running)) { }
}
