#!/usr/bin/env bash
# The whole local backend for playing the game in server mode, started and stopped in one command:
#   docker infra (Postgres, Redis, RabbitMQ, Redpanda)  +  Rpg.GameServerApi on :5000  +  the verifier worker on :5100
#
#   tools/dev_stack.sh start [--no-worker] [--observability] [--no-build]
#   tools/dev_stack.sh stop  [--keep-infra]
#   tools/dev_stack.sh restart [same options as start]
#   tools/dev_stack.sh status
#   tools/dev_stack.sh logs [api|worker]        (the last lines, then follows; Ctrl+C leaves the stack running)
#
# start: brings the docker infra up and waits until it is healthy, builds the server and the worker (unless
# --no-build), starts both hidden in the background (they outlive this terminal), and waits until they answer. The server
# runs in Development (accepts any ruleset version, dev tokens on) with the secrets from `dotnet user-secrets`; the worker
# replays steps in the real headless Godot on the real content, so a run played in the game reaches Verified. The game
# needs no setting changes (its Settings server url is http://localhost:5000).
# stop: stops the worker and the server (the whole process trees), then `docker compose stop` on the infra (the data is
# kept); --keep-infra leaves the containers running. Safe to run when nothing is up.
#
# The worker only verifies a build whose ruleset version is its own: the version is computed from the project's source, so
# re-export the full build (tools/build_tools/build_full.bat) after any source change before testing server mode with it.
# State and logs: build/dev-stack/ (api.log, worker.log, *.pid). Secrets come from infra/.env and user-secrets and are never
# printed. Never touches the e2e harness's throwaway databases.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
state="$root/build/dev-stack"
godot=${GODOT:-/h/Godot/Godot_v4.7.2-stable_mono_win64_console.exe}
compose=(docker compose -f "$root/infra/docker-compose.yml")
api_url="http://localhost:5000"
worker_url="http://127.0.0.1:5100"
server_dir="$root/src/Rpg.GameServerApi/bin/Debug/net10.0"
worker_dir="$root/src/Rpg.VerifierWorker/bin/Debug/net10.0"

win() { cygpath -m "$1" 2> /dev/null || echo "$1"; }  # Windows form of a path (env values are not converted by Git Bash)
say() { echo "dev_stack: $*"; }
die() { echo "dev_stack: $*" >&2; exit 1; }

alive() {  # <pid file>: the process of that Windows pid is running
	local pid
	[[ -s $1 ]] || return 1
	pid=$(tr -d '\r\n ' < "$1")
	tasklist //FI "PID eq $pid" //NH 2> /dev/null | tr -d '\r' | grep -q " $pid "
}
healthy() { curl -sf -m 2 "$1" > /dev/null 2>&1; }  # <url>
wait_for() {  # <what> <url> <seconds>
	local tries
	for tries in $(seq 1 $(($3 * 2))); do
		healthy "$2" && return 0
		sleep 0.5
	done
	say "$1 did not answer at $2 within $3 s: see $state/"
	return 1
}

spawn() {  # <name> <workdir> <executable> <argument>: starts it hidden and detached, logs to $state/<name>.log, records the pid
	# The pid goes to a file written by PowerShell, and PowerShell's own output is discarded: the started process inherits
	# PowerShell's stdout, so reading it through a pipe would block until the server exits.
	local name=$1 dir=$2 exe=$3 args=$4 tries pid=""
	rm -f "$state/$name.pid"
	powershell.exe -NoProfile -NonInteractive -Command "\$p = Start-Process -FilePath '$exe' -ArgumentList '$args' -WorkingDirectory '$(win "$dir")' -WindowStyle Hidden -PassThru -RedirectStandardOutput '$(win "$state/$name.log")' -RedirectStandardError '$(win "$state/$name.err.log")'; Set-Content -Path '$(win "$state/$name.pid")' -Value \$p.Id -Encoding ascii" > /dev/null 2>&1
	for tries in $(seq 1 20); do
		[[ -s $state/$name.pid ]] && pid=$(tr -d '\r\n ' < "$state/$name.pid")
		[[ $pid =~ ^[0-9]+$ ]] && return 0
		sleep 0.25
	done
	die "could not start $name"
}

stop_one() {  # <name>
	local file="$state/$1.pid" pid
	if alive "$file"; then
		pid=$(tr -d '\r\n ' < "$file")
		taskkill //F //T //PID "$pid" > /dev/null 2>&1 || true
		say "stopped $1 (pid $pid)"
	fi
	rm -f "$file"
}

infra_up() {
	docker info > /dev/null 2>&1 || die "docker is not running: start Docker Desktop first"
	say "starting the docker infra"
	"${compose[@]}" up -d postgres redis rabbitmq redpanda > "$state/docker.log" 2>&1 || die "docker compose up failed, see $state/docker.log"
	local service tries status
	for service in postgres redis rabbitmq redpanda; do
		for tries in $(seq 1 90); do
			status=$(docker inspect -f '{{.State.Health.Status}}' "rpg-$service-1" 2> /dev/null | tr -d '
')
			[[ $status == healthy ]] && break
			sleep 1
		done
		[[ $status == healthy ]] || die "$service is not healthy (status: ${status:-unknown}): docker compose logs $service"
	done
	if (( observability )); then
		"${compose[@]}" --profile observability up -d prometheus grafana >> "$state/docker.log" 2>&1 || say "prometheus/grafana did not start, see $state/docker.log"
	fi
}

build() {
	say "building the server and the worker (about a minute the first time)"
	"$root/tools/watch.sh" --name dev-build-api --timeout 600 --log "$state/build-api.log" -- \
		dotnet build "$root/src/Rpg.GameServerApi/Rpg.GameServerApi.csproj" -v q \
		|| die "the server build failed, see $state/build-api.log"
	(( want_worker )) && { "$root/tools/watch.sh" --name dev-build-worker --timeout 600 --log "$state/build-worker.log" -- \
		dotnet build "$root/src/Rpg.VerifierWorker/Rpg.VerifierWorker.csproj" -v q \
		|| die "the worker build failed, see $state/build-worker.log"; }
	return 0
}

start_api() {
	if alive "$state/api.pid" && healthy "$api_url/health/live"; then say "the server is already running"; return 0; fi
	stop_one api
	healthy "$api_url/health/live" && die "something else already answers on $api_url (another server?): stop it first"
	: > "$state/api.log"
	# The same environment as launchSettings.json's http profile, with absolute seed-file paths (the secrets are user-secrets).
	(
		export ASPNETCORE_ENVIRONMENT=Development "ASPNETCORE_URLS=$api_url" 			"Economy__SeedFile=$(win "$root/infra/economy/reward_rules.json")" 			"Cards__CatalogFile=$(win "$root/infra/economy/card_catalog.json")" 			"Cards__SeedFile=$(win "$root/infra/economy/card_economy.json")"
		spawn api "$server_dir" dotnet Rpg.GameServerApi.dll
	)
	say "starting the server"
	wait_for "the server" "$api_url/health/ready" 90 || { tail -5 "$state/api.err.log" 2> /dev/null; return 1; }
	say "the server is up: $api_url"
}

start_worker() {
	if alive "$state/worker.pid" && healthy "$worker_url/health/ready"; then say "the worker is already running"; return 0; fi
	stop_one worker
	[[ -x $godot ]] || die "godot not found at $godot (set GODOT to its console exe)"
	: > "$state/worker.log"
	# Same Postgres database, Redis and RabbitMQ as the server; the real headless Godot on the real content (ContentRoot empty).
	(
		export "ConnectionStrings__Postgres=Host=127.0.0.1;Port=5432;Database=$POSTGRES_DB;Username=$POSTGRES_USER;Password=$POSTGRES_PASSWORD" 			"ConnectionStrings__Redis=127.0.0.1:6379,abortConnect=false" 			"RabbitMq__Uri=amqp://$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS@127.0.0.1:5672/" 			"Urls=$worker_url" "Verifier__GodotPath=$(win "$godot")" "Verifier__ProjectPath=$(win "$root/client-godot")" 			Verifier__ContentRoot= Verifier__Concurrency=2 Settlement__Enabled=true
		spawn worker "$worker_dir" dotnet Rpg.VerifierWorker.dll
	)
	say "starting the verifier worker (it asks Godot for the ruleset version first)"
	wait_for "the worker" "$worker_url/health/ready" 120 || { tail -5 "$state/worker.err.log" 2> /dev/null; return 1; }
	say "the worker is up: $worker_url"
}

do_start() {
	infra_up
	(( no_build )) || build
	start_api || exit 1
	(( want_worker )) && { start_worker || exit 1; }
	echo
	say "everything is up. Play in server mode (the game's Settings url is $api_url)."
	say "status: tools/dev_stack.sh status   logs: tools/dev_stack.sh logs   stop: tools/dev_stack.sh stop"
}

do_stop() {
	stop_one worker
	stop_one api
	if (( keep_infra )); then
		say "the docker infra keeps running (--keep-infra)"
	elif docker info > /dev/null 2>&1; then
		"${compose[@]}" stop > "$state/docker.log" 2>&1 && say "stopped the docker infra (data kept)" || say "docker compose stop failed, see $state/docker.log"
	fi
	say "stopped"
}

do_status() {
	local line service
	if alive "$state/api.pid"; then
		healthy "$api_url/health/ready" && line="up, ready" || line="running, not ready"
		echo "server   $api_url  pid $(tr -d '\r\n' < "$state/api.pid")  $line"
	else
		healthy "$api_url/health/live" && echo "server   $api_url  answers, but not started by dev_stack.sh" || echo "server   $api_url  DOWN"
	fi
	if alive "$state/worker.pid"; then
		healthy "$worker_url/health/ready" && line="up, ready" || line="running, not ready"
		echo "worker   $worker_url  pid $(tr -d '\r\n' < "$state/worker.pid")  $line"
	else
		echo "worker   $worker_url  DOWN"
	fi
	if docker info > /dev/null 2>&1; then
		for service in postgres redis rabbitmq redpanda; do
			echo "docker   $service  $(docker inspect -f '{{.State.Status}} / {{.State.Health.Status}}' "rpg-$service-1" 2> /dev/null | tr -d '\r' || echo missing)"
		done
	else
		echo "docker   not running"
	fi
	echo "logs     $state/"
}

do_logs() {
	local which=${1:-api}
	[[ -f $state/$which.log ]] || die "no log for '$which' (api or worker)"
	tail -n 40 -f "$state/$which.log"
}

# --- Main ------------------------------------------------------------------------------------------------------------
command=${1:-}
shift || true
want_worker=1 no_build=0 keep_infra=0 observability=0
for arg in "$@"; do
	case $arg in
		--no-worker) want_worker=0 ;;
		--no-build) no_build=1 ;;
		--keep-infra) keep_infra=1 ;;
		--observability) observability=1 ;;
		api | worker) log_which=$arg ;;
		*) die "unknown option $arg" ;;
	esac
done
mkdir -p "$state"
case $command in
	start | restart)
		[[ $command == restart ]] && do_stop
		# infra/.env: the database and broker credentials for the worker (the server reads its own from user-secrets).
		[[ -f $root/infra/.env ]] || die "infra/.env is missing (copy infra/.env.example)"
		set -a; source <(tr -d '\r' < "$root/infra/.env"); set +a
		do_start ;;
	stop) do_stop ;;
	status) do_status ;;
	logs) do_logs "${log_which:-api}" ;;
	*) sed -n 2,12p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
