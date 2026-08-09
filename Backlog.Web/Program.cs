using Backlog.Web.Components;
using Backlog.Web.Data;
using MudBlazor.Services;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

builder.Services.AddMudServices();

// The connection string is deliberately not in the repo -- neither the secret
// nor the host it points at. Set it with:
//   dotnet user-secrets set "ConnectionStrings:Games" "Host=<host>;Database=<database>;..." --project Backlog.Web
var connectionString = builder.Configuration.GetConnectionString("Games")
    ?? throw new InvalidOperationException(
        "ConnectionStrings:Games is not set. Run: dotnet user-secrets set " +
        "\"ConnectionStrings:Games\" \"Host=<host>;Port=<port>;Database=<database>;" +
        "Username=<user>;Password=<password>\" --project Backlog.Web");

builder.Services.AddSingleton(NpgsqlDataSource.Create(connectionString));
builder.Services.AddScoped<BacklogRepository>();
builder.Services.AddScoped<UiState>();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
    app.UseHsts();
}

app.UseStatusCodePagesWithReExecute("/not-found", createScopeForStatusCodePages: true);
app.UseHttpsRedirection();
app.UseAntiforgery();

app.MapStaticAssets();
app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();

app.Run();
