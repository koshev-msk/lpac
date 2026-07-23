#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

UCODE_BIN=${UCODE_BIN:-ucode}
UCODE_MODULE_DIR=${UCODE_MODULE_DIR:-}
UCODE_RUNTIME_LIB_DIR=${UCODE_RUNTIME_LIB_DIR:-}
SETSID_PATH=${SETSID_PATH:-/usr/bin/setsid}
FLOCK_PATH=${FLOCK_PATH:-/usr/bin/flock}
SHELL_PATH=${SHELL_PATH:-/bin/sh}
KILL_PATH=${KILL_PATH:-/bin/kill}

case $UCODE_BIN in
	*/*) ;;
	*) UCODE_BIN=$(command -v "$UCODE_BIN") || exit 1 ;;
esac

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ucode_test=${test_dir}/supervisor-integration.uc
supervisor_file=${test_dir}/../root/usr/libexec/luci-lpac-supervisor
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/luci-lpac-supervisor.XXXXXX")
raw_pid_file=${work_dir}/raw-group.pids
lock_pid_file=${work_dir}/lock-group.pids
oneshot_pid_file=${work_dir}/oneshot-group.pids
lock_file=${work_dir}/operation.lock
fake_uci=${work_dir}/uci

valid_pid() {
	case $1 in
		''|*[!0-9]*) return 1 ;;
		*) [ "$1" -gt 1 ] ;;
	esac
}

kill_group() {
	group=$1

	"$KILL_PATH" -KILL -- "-$group" 2>/dev/null && return 0
	"$KILL_PATH" -KILL "-$group" 2>/dev/null
}

cleanup_group() {
	pid_file=$1

	[ -s "$pid_file" ] || return 0
	read -r leader _child < "$pid_file" || return 0
	valid_pid "$leader" || return 0
	kill_group "$leader" || true
}

cleanup() {
	cleanup_group "$raw_pid_file"
	cleanup_group "$lock_pid_file"
	cleanup_group "$oneshot_pid_file"
	rm -rf "$work_dir"
}

trap cleanup EXIT HUP INT TERM

for executable in "$UCODE_BIN" "$SETSID_PATH" "$FLOCK_PATH" \
	"$SHELL_PATH" "$KILL_PATH" "$supervisor_file"; do
	if [ ! -x "$executable" ]; then
		echo "Required executable is unavailable: $executable" >&2
		exit 1
	fi
done

if [ -z "$UCODE_MODULE_DIR" ] || [ ! -r "$UCODE_MODULE_DIR/uloop.so" ] ||
	[ ! -r "$UCODE_MODULE_DIR/fs.so" ]; then
	echo 'UCODE_MODULE_DIR must contain the real fs.so and uloop.so modules' >&2
	exit 1
fi

if [ -n "$UCODE_RUNTIME_LIB_DIR" ]; then
	LD_LIBRARY_PATH=${UCODE_RUNTIME_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
	export LD_LIBRARY_PATH
fi

run_ucode() {
	test_mode=$1
	shift
	"$UCODE_BIN" -S -L "$UCODE_MODULE_DIR" "$ucode_test" \
		"$test_mode" "$SETSID_PATH" "$SHELL_PATH" "$supervisor_file" "$@"
}

group_has_live_process() {
	group=$1

	for stat_file in /proc/[0-9]*/stat; do
		[ -r "$stat_file" ] || continue
		IFS= read -r stat_line < "$stat_file" || continue
		stat_fields=${stat_line##*) }
		# Split the fixed procfs record into state, PPID, and process group.
		# shellcheck disable=SC2086
		set -- $stat_fields

		[ "$#" -ge 3 ] || continue
		[ "$3" = "$group" ] || continue

		case $1 in
			Z|X) ;;
			*) return 0 ;;
		esac
	done

	return 1
}

wait_for_group_exit() {
	group=$1
	attempt=0

	while group_has_live_process "$group"; do
		attempt=$((attempt + 1))

		if [ "$attempt" -ge 100 ]; then
			echo "Process group $group still has live members" >&2
			return 1
		fi

		sleep 0.05
	done
}

read_group() {
	pid_file=$1

	if ! read -r leader child < "$pid_file" ||
		! valid_pid "$leader" || ! valid_pid "$child" ||
		[ "$leader" -eq "$child" ]; then
		echo "Invalid process-group record in $pid_file" >&2
		exit 1
	fi
}

try_lock() {
	"$FLOCK_PATH" -n "$lock_file" "$SHELL_PATH" -c 'exit 0'
}

cat > "$fake_uci" <<'EOF'
#!/bin/sh

[ "$1" = -q ] && [ "$2" = get ] || exit 1

case $3 in
	lpac.global)
		printf '%s\n' "${TEST_GLOBAL_TYPE:-global}"
		;;
	lpac.global.apdu_backend)
		[ "${TEST_BACKEND:-uqmi}" != missing ] || exit 1
		printf '%s\n' "${TEST_BACKEND:-uqmi}"
		;;
	luci_lpac.backend)
		[ "${TEST_SETUP_TYPE:-setup}" != missing ] || exit 1
		printf '%s\n' "${TEST_SETUP_TYPE:-setup}"
		;;
	luci_lpac.backend.confirmed_apdu_backend)
		[ "${TEST_MARKER:-uqmi}" != missing ] || exit 1
		printf '%s\n' "${TEST_MARKER:-uqmi}"
		;;
	luci_lpac.profiles)
		printf '%s\n' "${TEST_PROFILE_TYPE:-preferences}"
		;;
	luci_lpac.profiles.refresh_prompted)
		printf '%s\n' "${TEST_REFRESH_PROMPTED:-0}"
		;;
	luci_lpac.profiles.refresh_default)
		printf '%s\n' "${TEST_REFRESH_DEFAULT:-0}"
		;;
	*)
		exit 1
		;;
esac
EOF
chmod 700 "$fake_uci"

echo 'Testing backend gate under the inherited operation lock'
LPAC_SUPERVISOR_UCI=$fake_uci TEST_BACKEND=mbim TEST_MARKER=mbim \
	"$supervisor_file" backend-gate /bin/true
LPAC_SUPERVISOR_UCI=$fake_uci TEST_BACKEND=missing TEST_MARKER=uqmi \
	"$supervisor_file" backend-gate /bin/true
LPAC_SUPERVISOR_UCI=$fake_uci TEST_SETUP_TYPE=missing \
	"$supervisor_file" backend-gate /bin/true

set +e
LPAC_SUPERVISOR_UCI=$fake_uci "$supervisor_file" backend-gate \
	"$SHELL_PATH" -c 'exit 71'
gate_child_status=$?
set -e
[ "$gate_child_status" -eq 67 ] || {
	echo 'Backend gate did not reserve its unconfirmed exit status' >&2
	exit 1
}

for rejected_state in pending mismatch malformed_legacy; do
	gate_backend=uqmi
	gate_marker=uqmi
	gate_setup_type=setup
	gate_refresh_prompted=0

	case $rejected_state in
		pending)
			gate_marker=pending
			;;
		mismatch)
			gate_backend=mbim
			;;
		malformed_legacy)
			gate_setup_type=missing
			gate_refresh_prompted=yes
			;;
	esac

	set +e
	env LPAC_SUPERVISOR_UCI="$fake_uci" \
		TEST_BACKEND="$gate_backend" TEST_MARKER="$gate_marker" \
		TEST_SETUP_TYPE="$gate_setup_type" \
		TEST_REFRESH_PROMPTED="$gate_refresh_prompted" \
		"$supervisor_file" backend-gate /bin/true
	gate_status=$?
	set -e

	if [ "$gate_status" -ne 71 ]; then
		echo "Backend gate accepted invalid state: $rejected_state" >&2
		exit 1
	fi
done

echo 'Testing real uloop.process() callbacks and reserved exit protocol'
run_ucode protocol

echo 'Testing fragmented interactive preview acceptance over high file descriptors'
run_ucode pipe-accept

echo 'Testing fail-closed interactive preview cancellation on input EOF'
run_ucode pipe-eof

echo 'Testing setsid process-group timeout kill and raw-zero callback behavior'
run_ucode raw-group "$KILL_PATH" "$raw_pid_file"
read_group "$raw_pid_file"
raw_leader=$leader
wait_for_group_exit "$raw_leader"

echo 'Testing fs.file flock lifetime through uloop process descendants'
run_ucode lock-descendant "$KILL_PATH" "$lock_file" "$lock_pid_file"
read_group "$lock_pid_file"
lock_leader=$leader

if ! try_lock; then
	echo 'The inherited lock remained held after descendant cleanup' >&2
	exit 1
fi

wait_for_group_exit "$lock_leader"

echo 'Testing one-shot deadline and descendant cleanup'
run_ucode oneshot-timeout "$KILL_PATH" "$oneshot_pid_file"
read_group "$oneshot_pid_file"
wait_for_group_exit "$leader"

echo 'Testing async supervision beyond the old 30-second RPC window'
run_ucode async-long

echo 'Supervisor integration tests passed'
