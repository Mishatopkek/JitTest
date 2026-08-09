var builder = WebApplication.CreateBuilder(args);

var app = builder.Build();

// Two endpoints demonstrating why a loop flag shared between threads needs
// volatile semantics.
//
// /problem reads a plain bool in a tight loop. The JIT is free to hoist that
// read out of the loop, because nothing in the loop body writes it -- so the
// thread can spin forever on a stale register even after the flag is set false.
// Whether it actually does depends on the JIT and the memory model: x86 is
// strongly ordered and often gets away with it, ARM is weaker and does not.
//
// /noproblem reads the same flag through Volatile.Read, which forbids that
// hoisting, so the thread observes the write and exits.
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

static void JustRunning(ref bool running)
{
    while (running) { }
}

static void RunWithVolatile(ref bool running)
{
    while (Volatile.Read(ref running)) { }
}
