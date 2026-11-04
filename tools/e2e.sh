#!/usr/bin/env bash
# End-to-end harness (spec dev-tools E1-E7): the real Rpg.GameServerApi and the real game, headless, on throwaway
# state, driven by committed scenario scripts.
#   tools/e2e.sh [scenario ...] [--keep] [-j N]      (default: every client-godot/tests/e2e/*.txt, N = 4)
#   tools/e2e.sh --check                             (no Docker: lists and validates the scenarios, finds the tools)
# Per scenario: a fresh Postgres database e2e_<stamp>_<scenario>, Redis index 1-15, a server on its own port
# (Development, so dev tokens and Run:AutoApproveWins; test seed and token secrets; only the live ruleset version
# accepted; plus the scenario's "#! env K=V" lines) and a RabbitMQ vhost of its own (so parallel scenarios never
# consume each other's verify jobs),
# then dev_run.tscn --server --player e2e-<scenario> --control <folder>, then the scenario's .sql (every line returns t),
# .metrics (every line is a regex the final server /metrics scrape matches) and .worker-metrics (the same for the verifier
# worker's /metrics). Fault steps (`e2e <action>` in a script) reach the control loop here: server-stop, server-start,
# redis-flush, worker-start, worker-stop (a kill), tamper-battle (spec battle-verify 6), redpanda-stop and
# redpanda-start (spec settlement-outbox 6: the shared Redpanda container is stopped, and started again once the outbox of
# the scenario has drained; run such a scenario alone, other scenarios share the broker), redpanda-check (every outbox row
# of the scenario marked published is on the topics: the topics are read from the start for 6 s each and the event ids
# looked up). A "#! worker" line starts the
# verifier worker (the real headless Godot per job, on the fixtures content) with the server; without it a scenario
# starts the worker itself with `e2e worker-start`. A "#! content real" line runs the game and the worker on the real
# res://content/ instead of the fixtures (the worker may load the content folders at any time).
# Output in build/e2e/<stamp>/<scenario>/; one "ok|FAIL <scenario>" line each. Exit 0 all ok, 1 any failure (incl.
# infra down), 124 a stalled Godot. Never touches the dev database, Redis index 0 or user://game_main.cfg.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
godot=${GODOT:-/h/Godot/Godot_v4.7.2-stable_mono_win64_console.exe}
scenarios_dir="$root/client-godot/tests/e2e"
compose=(docker compose -f "$root/infra/docker-compose.yml")
seed_secret="e2e-floor-seed-secret-0123456789abcdef"
signing_key="e2e-jwt-signing-key-0123456789abcdef"
jobs=4; keep=0; check=0; picked=()
while [[ $# -gt 0 ]]; do
	case $1 in
		--keep) keep=1; shift ;;
		--check) check=1; shift ;;
		-j) jobs=$2; shift 2 ;;
		-*) echo "e2e.sh: unknown option $1" >&2; exit 2 ;;
		*) picked+=("$1"); shift ;;
	esac
done
(( jobs >= 1 && jobs <= 15 )) || { echo "e2e.sh: -j takes 1 to 15 (Redis indexes 1-15)" >&2; exit 2; }
if (( ${#picked[@]} == 0 )); then
	for file in "$scenarios_dir"/*.txt; do picked+=("$(basename "$file" .txt)"); done
fi

# --- Validation (also --check) ---------------------------------------------------------------------------------------
problems=0
validate() {  # <scenario>
	local name=$1 file="$scenarios_dir/$1.txt" line
	[[ -f $file ]] || { echo "e2e.sh: no scenario $file"; problems=$((problems + 1)); return; }
	[[ $name =~ ^[a-z0-9_]+$ ]] || { echo "e2e.sh: $name: scenario names are lower case, digits and _"; problems=$((problems + 1)); }
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		if [[ $line == "#! "* && ! $line =~ ^#!\ env\ [A-Za-z_][A-Za-z0-9_]*=.*$ && $line != "#! worker" && $line != "#! content real" ]]; then
			echo "e2e.sh: $name: bad directive '$line' (only '#! env KEY=VALUE', '#! worker' and '#! content real')"; problems=$((problems + 1))
		fi
	done < "$file"
	if [[ -f $scenarios_dir/$name.sql ]]; then
		while IFS= read -r line || [[ -n $line ]]; do
			line=${line%$'\r'}
			[[ -z $line ]] && continue
			[[ $line == *";"* ]] && { echo "e2e.sh: $name.sql: one statement per line, no ';': $line"; problems=$((problems + 1)); }
			[[ ${line,,} == select* ]] || { echo "e2e.sh: $name.sql: only select queries: $line"; problems=$((problems + 1)); }
		done < "$scenarios_dir/$name.sql"
	fi
	if [[ -f $scenarios_dir/$name.worker-metrics ]] && ! grep -qE '^#! worker$|e2e worker-start' "$file"; then
		echo "e2e.sh: $name: has .worker-metrics but never starts the worker"; problems=$((problems + 1))
	fi
}
for name in "${picked[@]}"; do validate "$name"; done
if (( ! check )) && [[ " ${picked[*]} " == *" outbox_redpanda_down "* ]] && (( ${#picked[@]} > 1 )); then
	echo "e2e.sh: outbox_redpanda_down stops the shared Redpanda: run it alone"; problems=$((problems + 1))
fi
for tool in "$godot" dotnet docker curl; do
	command -v "$tool" > /dev/null 2>&1 || [[ -x $tool ]] || { echo "e2e.sh: $tool not found"; problems=$((problems + 1)); }
done
if (( check )); then
	echo "e2e.sh: scenarios: ${picked[*]}"
	(( problems == 0 )) && echo "e2e.sh: check ok" || echo "e2e.sh: check found $problems problem(s)"
	exit $(( problems == 0 ? 0 : 1 ))
fi
(( problems == 0 )) || exit 1

# --- Infra and shared builds -----------------------------------------------------------------------------------------
[[ -f $root/infra/.env ]] || { echo "e2e.sh: infra/.env missing (copy infra/.env.example)"; exit 1; }
set -a; source <(tr -d '\r' < "$root/infra/.env"); set +a
for service in postgres redis rabbitmq; do
	case $service in
		postgres) probe=(pg_isready -U "$POSTGRES_USER") ;;
		redis) probe=(redis-cli ping) ;;
		rabbitmq) probe=(rabbitmq-diagnostics -q ping) ;;
	esac
	"${compose[@]}" exec -T "$service" "${probe[@]}" > /dev/null 2>&1 \
		|| { echo "e2e.sh: $service is not running: cd infra && docker compose up -d"; exit 1; }
done
# stdin from /dev/null: `docker compose exec` reads stdin and would swallow the rest of a file being read in a loop.
psql() { "${compose[@]}" exec -T postgres psql -U "$POSTGRES_USER" -v ON_ERROR_STOP=1 -tA "$@" < /dev/null; }
redis() { "${compose[@]}" exec -T redis redis-cli "$@" < /dev/null; }
stamp=$(date +%Y%m%d_%H%M%S)
out="$root/build/e2e/$stamp"
mkdir -p "$out"
echo "e2e.sh: building the server, the verifier worker and the Godot C# assembly"
"$root/tools/watch.sh" --name e2e-build --timeout 600 --log "$out/build.log" -- \
	dotnet build "$root/src/Rpg.GameServerApi/Rpg.GameServerApi.csproj" -v q \
	&& "$root/tools/watch.sh" --name e2e-build-worker --timeout 600 --log "$out/build-worker.log" -- \
		dotnet build "$root/src/Rpg.VerifierWorker/Rpg.VerifierWorker.csproj" -v q \
	&& "$root/tools/watch.sh" --name e2e-build-godot --timeout 600 --log "$out/build-godot.log" -- \
		dotnet build "$root/client-godot/rpgDemo.csproj" -v q \
	|| { echo "e2e.sh: build failed, see $out/build*.log"; exit 1; }
server_dir="$root/src/Rpg.GameServerApi/bin/Debug/net10.0"
worker_dir="$root/src/Rpg.VerifierWorker/bin/Debug/net10.0"
"$root/tools/watch.sh" --name e2e-ruleset --timeout 300 --log "$out/ruleset.log" -- \
	"$godot" --headless --path "$root/client-godot" --quit-after 100000 res://game/tools/print_ruleset_version.tscn
ruleset=$(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+\.[a-z0-9.]+\+[0-9a-f]{16}' "$out/ruleset.log")
[[ -n $ruleset ]] || { echo "e2e.sh: no ruleset version, see $out/ruleset.log"; exit 1; }
echo "e2e.sh: ruleset $ruleset"

# --- Processes -------------------------------------------------------------------------------------------------------
win() { cygpath -m "$1" 2> /dev/null || echo "$1"; }  # env values are not path-converted by Git Bash
rabbit() { "${compose[@]}" exec -T rabbitmq rabbitmqctl "$@" < /dev/null; }

kill_tree() {  # <bash pid>: the whole Windows process tree when there is one
	local winpid
	winpid=$(cat "/proc/$1/winpid" 2>/dev/null || true)
	if [[ -n $winpid ]] && command -v taskkill > /dev/null 2>&1; then
		taskkill //F //T //PID "$winpid" > /dev/null 2>&1 || true
	fi
	kill "$1" 2>/dev/null || true
	wait "$1" 2>/dev/null || true
}

# --- One scenario ----------------------------------------------------------------------------------------------------
run_scenario() {  # <name> <index 1-15>
	local name=$1 index=$2 dir="$out/$1" port=$((5100 + $2)) db="e2e_${stamp}_$1" started=$SECONDS
	local control="$dir/control" result="$dir/result" pid_file="$dir/server.pid" loop_pid="" code=0
	local wport=$((5200 + $2)) worker_pid_file="$dir/worker.pid" vhost="e2e_${stamp}_$1" want_worker=0
	local content_root="res://tests/fixtures/"
	mkdir -p "$control"
	local -a env=(ASPNETCORE_ENVIRONMENT=Development "ASPNETCORE_URLS=http://127.0.0.1:$port"
		"ConnectionStrings__Postgres=Host=127.0.0.1;Port=5432;Database=$db;Username=$POSTGRES_USER;Password=$POSTGRES_PASSWORD"
		"ConnectionStrings__Redis=127.0.0.1:6379,abortConnect=false,defaultDatabase=$index"
		"RabbitMq__Uri=amqp://$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS@127.0.0.1:5672/$vhost"
		"Seeds__Secret=$seed_secret" "Auth__SigningKey=$signing_key" Ruleset__AcceptAny=false
		"Ruleset__Accepted__0=$ruleset")
	local line
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		[[ $line == "#! env "* ]] && env+=("${line#\#! env }")
		[[ $line == "#! worker" ]] && want_worker=1
		[[ $line == "#! content real" ]] && content_root=""
	done < "$scenarios_dir/$name.txt"
	# The verifier worker (spec battle-verify): the same databases and broker, the fixtures content like the game, the
	# ruleset version the server accepts, and the real headless Godot for every job.
	local -a worker_env=("ConnectionStrings__Postgres=Host=127.0.0.1;Port=5432;Database=$db;Username=$POSTGRES_USER;Password=$POSTGRES_PASSWORD"
		"ConnectionStrings__Redis=127.0.0.1:6379,abortConnect=false,defaultDatabase=$index"
		"RabbitMq__Uri=amqp://$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS@127.0.0.1:5672/$vhost"
		"Urls=http://127.0.0.1:$wport" "Verifier__GodotPath=$(win "$godot")" "Verifier__ProjectPath=$(win "$root/client-godot")"
		"Verifier__ContentRoot=$content_root" "Verifier__RulesetVersion=$ruleset" Verifier__Concurrency=2
		Settlement__Enabled=true Settlement__GemsPerBossMark=10)
	start_worker() {
		(cd "$worker_dir" && exec env "${worker_env[@]}" dotnet Rpg.VerifierWorker.dll >> "$dir/worker.log" 2>&1) &
		echo $! > "$worker_pid_file"
		local tries
		for tries in $(seq 1 120); do
			curl -sf -m 2 "http://127.0.0.1:$wport/health/ready" > /dev/null 2>&1 && return 0
			sleep 0.5
		done
		return 1
	}
	stop_worker() { [[ -s $worker_pid_file ]] && kill_tree "$(cat "$worker_pid_file")"; : > "$worker_pid_file"; }

	start_server() {
		(cd "$server_dir" && exec env "${env[@]}" dotnet Rpg.GameServerApi.dll >> "$dir/server.log" 2>&1) &
		echo $! > "$pid_file"  # a file: the control loop (a subshell) stops and starts the server too
		local tries
		for tries in $(seq 1 60); do
			curl -sf -m 2 "http://127.0.0.1:$port/health/ready" > /dev/null 2>&1 && return 0
			sleep 0.5
		done
		return 1
	}
	stop_server() { [[ -s $pid_file ]] && kill_tree "$(cat "$pid_file")"; : > "$pid_file"; }
	control_loop() {
		local action answer
		while true; do
			if [[ -f $control/request ]]; then
				action=$(tr -d '\r\n' < "$control/request"); rm -f "$control/request"
				answer=ok
				case $action in
					server-stop) stop_server ;;
					server-start) start_server || answer="server not ready" ;;
					redis-flush) redis -n "$index" FLUSHDB > /dev/null || answer="flush failed" ;;
					worker-start) start_worker || answer="worker not ready" ;;
					worker-stop)  # a kill, but only once a job is in flight (unacked), so the scenario proves a redelivery
						local tries=0 unacked=0
						while (( tries < 120 )); do
							unacked=$(rabbit list_queues -p "$vhost" name messages_unacknowledged -q 2> /dev/null | tr -d '\r' | awk '$1 == "verify.battle" {print $2}')
							(( ${unacked:-0} >= 1 )) && break
							tries=$((tries + 1)); sleep 0.25
						done
						if (( ${unacked:-0} >= 1 )); then stop_worker; else answer="no job was in flight to interrupt"; fi ;;
					redpanda-stop) : > "$dir/redpanda-stopped"; "${compose[@]}" stop redpanda > /dev/null 2>&1 || answer="redpanda did not stop" ;;
					redpanda-start)  # up again, then wait until this scenario's outbox has drained into it
						# the moment before the broker returns, kept in the scenario's database for its .sql to compare with
						psql -d "$db" -c "CREATE TABLE IF NOT EXISTS e2e_marks (name text PRIMARY KEY, at timestamptz NOT NULL); INSERT INTO e2e_marks VALUES ('redpanda-start', clock_timestamp()) ON CONFLICT (name) DO UPDATE SET at = excluded.at" > /dev/null 2>&1 || answer="could not record the restart time"
						"${compose[@]}" start redpanda > /dev/null 2>&1 || answer="redpanda did not start"
						if [[ $answer == ok ]]; then
							local drained=0 tries=0 left
							while (( tries < 240 )); do
								left=$(psql -d "$db" -c "SELECT count(*) FROM outbox WHERE destination = 'redpanda' AND published_at IS NULL" 2>/dev/null | tr -d '')
								[[ $left == 0 ]] && { drained=1; break; }
								tries=$((tries + 1)); sleep 0.5
							done
							(( drained )) || answer="the outbox did not drain (${left:-?} redpanda rows left)"
						fi ;;
					redpanda-check)  # read the topics back: every published event of this scenario's outbox must be on them
						local want=0 tries=0 left ids dump missing=0 id
						while (( tries < 60 )); do  # the relay may still be sending the last rows
							left=$(psql -d "$db" -c "SELECT count(*) FROM outbox WHERE destination = 'redpanda' AND published_at IS NULL" 2>/dev/null | tr -d '')
							[[ $left == 0 ]] && break
							tries=$((tries + 1)); sleep 0.5
						done
						ids=$(psql -d "$db" -c "SELECT id FROM outbox WHERE destination = 'redpanda' AND published_at IS NOT NULL" 2>/dev/null | tr -d '')
						dump=$(for topic in rpg.battle.events rpg.economy.events; do
							"${compose[@]}" exec -T redpanda timeout 6 rpk topic consume "$topic" -o start -f '%v
' < /dev/null 2>/dev/null
						done)
						for id in $ids; do want=$((want + 1)); grep -q "$id" <<< "$dump" || missing=$((missing + 1)); done
						if [[ $left != 0 ]]; then answer="${left:-?} redpanda rows were still unpublished"
						elif (( want == 0 )); then answer="no published events to read back"
						elif (( missing > 0 )); then answer="$missing of $want published events are not on the topics"
						fi ;;
					tamper-battle)  # the first battle's claimed final hash is replaced, as a cheating client would
						[[ $(psql -d "$db" -c "UPDATE battle_sessions SET action_log = jsonb_set(action_log, '{claimedFinalHash}', to_jsonb(repeat('0', 64))) WHERE run_seq = (SELECT min(run_seq) FROM battle_sessions) RETURNING 1" 2>&1 | head -1 | tr -d '\r') == 1 ]] \
							|| answer="no battle to tamper with" ;;
					*) answer="unknown action $action" ;;
				esac
				echo "[e2e] $action: $answer" >> "$dir/control.log"
				printf '%s' "$answer" > "$control/done"
			fi
			sleep 0.2
		done
	}

	{
		# A failed setup still falls through to the cleanup below (the database may exist already).
		if ! psql -c "CREATE DATABASE $db" > /dev/null || ! redis -n "$index" FLUSHDB > /dev/null \
			|| ! rabbit add_vhost "$vhost" > /dev/null || ! rabbit set_permissions -p "$vhost" "$RABBITMQ_DEFAULT_USER" ".*" ".*" ".*" > /dev/null; then
			echo "setup failed (database, Redis or RabbitMQ vhost)" > "$result"
		elif ! start_server; then
			echo "server never ready: $(tail -40 "$dir/server.log" | tr '\n' ' ')" > "$result"
		elif (( want_worker )) && ! start_worker; then
			echo "worker never ready: $(tail -40 "$dir/worker.log" | tr '\n' ' ')" > "$result"
		else
			control_loop & loop_pid=$!
			"$root/tools/watch.sh" --name "e2e-$name" --timeout 600 --log "$dir/godot.log" -- \
				"$godot" --headless --path "$root/client-godot" --quit-after 2000000000 res://game/tools/dev_run.tscn -- \
				--script "$scenarios_dir/$name.txt" --out "$dir/state.json" ${content_root:+--content-root "$content_root"} \
				--server "http://127.0.0.1:$port" --player "e2e-$name" --control "$control"
			code=$?
			local failures=()
			(( code == 0 )) || failures+=("dev_run exit $code: $(grep -A3 'failed' "$dir/godot.log" | tail -4 | tr '\n' ' ')")
			if [[ -f $scenarios_dir/$name.sql ]]; then
				while IFS= read -r line || [[ -n $line ]]; do
					line=${line%$'\r'}; [[ -z $line ]] && continue
					local value
					value=$(psql -d "$db" -c "$line" 2>&1 | tr -d '\r')
					echo "$value | $line" >> "$dir/sql.txt"
					[[ $value == t ]] || failures+=("sql: $line → $value")
				done < "$scenarios_dir/$name.sql"
			fi
			if [[ -f $scenarios_dir/$name.metrics ]]; then
				[[ -s $pid_file ]] || start_server > /dev/null
				curl -s -m 5 "http://127.0.0.1:$port/metrics" > "$dir/metrics.txt" 2>&1
				while IFS= read -r line || [[ -n $line ]]; do
					line=${line%$'\r'}; [[ -z $line ]] && continue
					grep -qE "$line" "$dir/metrics.txt" || failures+=("metrics: no match for $line")
				done < "$scenarios_dir/$name.metrics"
			fi
			if [[ -f $scenarios_dir/$name.worker-metrics ]]; then
				curl -s -m 5 "http://127.0.0.1:$wport/metrics" > "$dir/worker-metrics.txt" 2>&1
				while IFS= read -r line || [[ -n $line ]]; do
					line=${line%$'\r'}; [[ -z $line ]] && continue
					grep -qE "$line" "$dir/worker-metrics.txt" || failures+=("worker metrics: no match for $line")
				done < "$scenarios_dir/$name.worker-metrics"
			fi
			if (( ${#failures[@]} == 0 )); then echo ok > "$result"
			else printf '%s\n' "${failures[@]}" > "$result"; [[ $code == 124 ]] && echo 124 > "$dir/stalled"; fi
		fi
		[[ -n $loop_pid ]] && kill "$loop_pid" 2>/dev/null
		stop_worker
		stop_server
		[[ -f $dir/redpanda-stopped ]] && "${compose[@]}" start redpanda > /dev/null 2>&1  # never leave the shared broker down
		if (( ! keep )); then psql -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" > /dev/null 2>&1; fi
		redis -n "$index" FLUSHDB > /dev/null 2>&1
		rabbit delete_vhost "$vhost" > /dev/null 2>&1
		echo "$((SECONDS - started))" > "$dir/seconds"
	}
}

# --- Run, in parallel ------------------------------------------------------------------------------------------------
pids=()
cleanup() {
	for pid in "${pids[@]}"; do kill_tree "$pid"; done
	if (( ! keep )); then
		for name in "${picked[@]}"; do psql -c "DROP DATABASE IF EXISTS e2e_${stamp}_$name WITH (FORCE)" > /dev/null 2>&1; done
	fi
}
trap 'echo "e2e.sh: interrupted"; cleanup; exit 130' INT TERM
index=0
for name in "${picked[@]}"; do
	while (( $(jobs -rp | wc -l) >= jobs )); do sleep 0.5; done
	index=$(( index % 15 + 1 ))
	run_scenario "$name" "$index" &
	pids+=($!)
done
wait
failed=0; stalled=0
for name in "${picked[@]}"; do
	result=$(cat "$out/$name/result" 2>/dev/null || echo "no result")
	seconds=$(cat "$out/$name/seconds" 2>/dev/null || echo "?")
	if [[ $result == ok ]]; then
		echo "ok   $name (${seconds}s)"
	else
		failed=$((failed + 1)); [[ -f $out/$name/stalled ]] && stalled=1
		echo "FAIL $name (${seconds}s), logs in $out/$name"
		sed 's/^/       /' <<< "$result"
	fi
done
echo "e2e.sh: $(( ${#picked[@]} - failed )) passed, $failed failed (build/e2e/$stamp)"
(( failed == 0 )) && exit 0
(( stalled )) && exit 124
exit 1
