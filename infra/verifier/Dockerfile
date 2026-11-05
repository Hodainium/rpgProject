# Spec battle-verify 3.7: the verifier worker image. Build context is the repo root:
#   docker build -f infra/verifier/Dockerfile -t rpg-verifier .
# Proven by tools/verifier_image_check.sh (2026-11-01): the image builds, its ruleset version equals the Windows build's,
# and all 18 committed combat goldens replay to the same final hashes (Verified / Rejected 2002) as on Windows.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY global.json Directory.Build.props Directory.Packages.props Rpg.slnx ./
COPY src/Rpg.Contracts/Rpg.Contracts.csproj src/Rpg.Contracts/
COPY src/Rpg.Economy/Rpg.Economy.csproj src/Rpg.Economy/
COPY src/Rpg.Verification/Rpg.Verification.csproj src/Rpg.Verification/
COPY src/Rpg.VerifierWorker/Rpg.VerifierWorker.csproj src/Rpg.VerifierWorker/
RUN dotnet restore src/Rpg.VerifierWorker/Rpg.VerifierWorker.csproj
COPY src/Rpg.Contracts src/Rpg.Contracts
COPY src/Rpg.Economy src/Rpg.Economy
COPY src/Rpg.Verification src/Rpg.Verification
COPY src/Rpg.VerifierWorker src/Rpg.VerifierWorker
RUN dotnet publish src/Rpg.VerifierWorker/Rpg.VerifierWorker.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
ARG GODOT_VERSION=4.7.2
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip libfontconfig1 libgl1 libasound2t64 \
 && rm -rf /var/lib/apt/lists/*

# The one pinned Godot build the client and the verifier share (root CLAUDE.md, "Battle workflow decisions").
RUN curl -fsSL -o /tmp/godot.zip \
      "https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64.zip" \
 && unzip -q /tmp/godot.zip -d /opt \
 && mv /opt/Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64 /opt/godot \
 && ln -s /opt/godot/Godot_v${GODOT_VERSION}-stable_mono_linux.x86_64 /usr/local/bin/godot \
 && rm /tmp/godot.zip

# The project the replay runs from: all of client-godot (a smaller selection is a later optimisation). Importing builds
# the global class cache a headless run needs. `--import` quits by itself (adding --quit-after made it hang here), and
# is bounded anyway; the build then FAILS unless the class cache exists, so an image that cannot replay is not built.
WORKDIR /srv
COPY client-godot ./client-godot
RUN timeout 600 godot --headless --path client-godot --import ;     test -f client-godot/.godot/global_script_class_cache.cfg

COPY --from=build /app /app
WORKDIR /app
ENV Verifier__GodotPath=/usr/local/bin/godot \
    Verifier__ProjectPath=/srv/client-godot \
    Verifier__Concurrency=2
EXPOSE 5100
ENTRYPOINT ["dotnet", "Rpg.VerifierWorker.dll"]
