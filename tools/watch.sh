#!/usr/bin/env bash
# Run a command with a liveness signal and a hard stop (spec dev-tools, "Headless safeguards and parallel runs").
#   tools/watch.sh [--idle S] [--timeout S] [--log FILE] [--name LABEL] -- <command> [args...]
# The command's output goes to --log (a temp file by default). Every 30 s: "[watch:LABEL] <s>, <KB>: <last line>".
# When the log stays silent for --idle seconds (default 180) or the run passes --timeout (default 3600), the whole
# process tree is killed and the exit code is 124; otherwise the command's own exit code.
set -uo pipefail
idle=180; total=3600; log=""; name=job
while [[ $# -gt 0 && $1 != "--" ]]; do
	case $1 in
		--idle) idle=$2; shift 2 ;;
		--timeout) total=$2; shift 2 ;;
		--log) log=$2; shift 2 ;;
		--name) name=$2; shift 2 ;;
		*) echo "watch.sh: unknown option $1" >&2; exit 2 ;;
	esac
done
[[ ${1:-} == "--" ]] && shift
[[ $# -eq 0 ]] && { echo "watch.sh: no command" >&2; exit 2; }
[[ -z $log ]] && log=$(mktemp)
: > "$log"
"$@" > "$log" 2>&1 &
pid=$!

kill_tree() {
	local winpid
	winpid=$(cat "/proc/$pid/winpid" 2>/dev/null || true)
	if [[ -n $winpid ]] && command -v taskkill > /dev/null; then
		taskkill //F //T //PID "$winpid" > /dev/null 2>&1 || true
	else
		pkill -TERM -P "$pid" 2>/dev/null || true
		kill -TERM "$pid" 2>/dev/null || true
	fi
}

start=$(date +%s); last_size=-1; last_change=$start; last_note=$start; reason=""
while kill -0 "$pid" 2> /dev/null; do
	sleep 2
	now=$(date +%s)
	size=$(stat -c %s "$log" 2> /dev/null || echo 0)
	if [[ $size != "$last_size" ]]; then last_size=$size; last_change=$now; fi
	if (( now - last_change >= idle )); then reason="no output for ${idle}s"; break; fi
	if (( now - start >= total )); then reason="running over ${total}s"; break; fi
	if (( now - last_note >= 30 )); then
		line=$(tail -c 2000 "$log" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-110)
		echo "[watch:$name] $(( now - start ))s, $(( size / 1024 )) KB: $line"
		last_note=$now
	fi
done
if [[ -n $reason ]]; then
	kill_tree
	echo "[watch:$name] STOPPED after $(( $(date +%s) - start ))s: $reason. Last lines of $log:"
	tail -15 "$log" | tr -d '\r'
	exit 124
fi
wait "$pid"
exit $?
