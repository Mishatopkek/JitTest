# Build context is the repository root, not this directory:
#
#   docker build -f Backlog.Web/Dockerfile -t backlog-web .
#
# The connection string is never baked in. Supply it at run time as
# ConnectionStrings__Games -- the double underscore is how ASP.NET Core maps an
# environment variable onto the "ConnectionStrings:Games" configuration key that
# Program.cs reads.
#
#   docker run -p 8081:8080 -e "ConnectionStrings__Games=Host=...;Port=...;..." backlog-web

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore against the project file alone, so editing a .razor or .cs file reuses
# this layer's populated NuGet cache instead of hitting the network again.
COPY Backlog.Web/Backlog.Web.csproj Backlog.Web/
RUN dotnet restore Backlog.Web/Backlog.Web.csproj

COPY Backlog.Web/ Backlog.Web/

# No --no-restore here, deliberately. That restore above ran with only the
# .csproj present -- no wwwroot, no Components -- and reusing its result makes
# publish emit a static-asset manifest with no framework Blazor assets in it.
# The app then serves every page as dead HTML, because /_framework/blazor.web.js
# 404s and the interactive circuit never starts. Restoring again with the full
# source present is what registers those assets, and it costs nothing on the
# network: the packages are already in this image's NuGet cache.
RUN dotnet publish Backlog.Web/Backlog.Web.csproj -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final

# Expect two stderr lines on the first database connection:
#
#   Cannot load library libgssapi_krb5.so.2
#   Error: libgssapi_krb5.so.2: cannot open shared object file: No such file...
#
# They are noise, not a fault. Npgsql probes for GSSAPI when it opens its first
# physical connection, caches the answer, and never asks again -- it is once per
# process, not per connection, and password auth is unaffected. No dotnet/aspnet
# image ships krb5 (8.0, 9.0 and 10.0 all lack it), so this is the norm for
# Npgsql on the stock base; the sdk image has it transitively, which is why the
# lines never appear during a build or a local dotnet run.
#
# Installing libgssapi-krb5-2 silences them, and is deliberately not done here:
# an apt layer and extra package surface is a poor trade for two cosmetic lines.

WORKDIR /app
COPY --from=build /app/publish .

# Plain HTTP only; terminating TLS is the reverse proxy's job. Program.cs still
# calls UseHttpsRedirection, which no-ops (with a warning) when no HTTPS port is
# configured, so nothing here needs to change on that side.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

# DataProtection keys live here and die with the container, so a restart
# invalidates the antiforgery cookies browsers are still holding ("The
# antiforgery token could not be decrypted", then a reload). Mounting a volume
# over this path persists them, and needs no code change:
#
#   docker run -v backlog-keys:/home/app/.aspnet/DataProtection-Keys ...
#
# Creating the directory here, owned by app, is what makes that mount work: a
# fresh named volume takes its ownership from the image's directory, and if that
# directory does not exist the volume lands root-owned and the non-root app user
# cannot write to it -- which fails the key ring and serves 500 on every page.
# Left as a mount rather than a VOLUME line, so runs do not litter anonymous
# volumes.
RUN mkdir -p /home/app/.aspnet/DataProtection-Keys \
    && chown -R $APP_UID:$APP_UID /home/app/.aspnet

# The aspnet image ships a non-root "app" user; $APP_UID is its uid.
USER $APP_UID

ENTRYPOINT ["dotnet", "Backlog.Web.dll"]
