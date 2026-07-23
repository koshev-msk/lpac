#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

uci_bin=${UCI_BIN:-uci}

if ! command -v "$uci_bin" >/dev/null 2>&1; then
	if [ "${REQUIRE_UCI:-0}" = 1 ]; then
		printf 'Required real OpenWrt uci executable is unavailable: %s\n' \
			"$uci_bin" >&2
		exit 1
	fi

	printf '1..0 # SKIP real OpenWrt uci executable is unavailable\n'
	exit 0
fi

test_root=$(mktemp -d "${TMPDIR:-/tmp}/luci-lpac-uci.XXXXXX")
config_dir="$test_root/config"
save_dir="$test_root/save"
config_file="$config_dir/lpac_safety"
preference_file="$config_dir/luci_lpac"
output_file="$test_root/output"
checks=0

cleanup() {
	rm -rf "$test_root"
}

trap cleanup EXIT HUP INT TERM
mkdir -p "$config_dir" "$save_dir"

notification_incident=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
notification_json="{\"9\":{\"incident\":\"$notification_incident\",\"state\":\"provider_outcome_unknown\"}}"

printf '%s\n' \
	"config safety 'state'" \
	"    option schema '1'" \
	"    option download_incident ''" \
	"    option profiles_refreshed '1'" \
	"    option notifications_refreshed '1'" \
	"    option notifications '$notification_json'" \
	> "$config_file"

printf '%s\n' \
	"config preferences 'profiles'" \
	"    option refresh_prompted '1'" \
	"    option refresh_default '0'" \
	"    option vendor_option 'keep'" \
	"config vendor 'future'" \
	"    option value 'preserve'" \
	> "$preference_file"

run_uci() {
	"$uci_bin" -c "$config_dir" -t "$save_dir" "$@"
}

option_is_missing() {
	! run_uci -q get lpac_safety.state.download_incident \
		> "$output_file" 2>&1
}

backend_section_is_missing() {
	! run_uci -q get luci_lpac.backend > "$output_file" 2>&1
}

option_equals() {
	option=$1
	expected=$2
	actual=$(run_uci get "$option")
	[ "$actual" = "$expected" ]
}

file_omits_empty_incident() {
	! grep -Eq \
		'^[[:space:]]*option[[:space:]]+download_incident([[:space:]]|$)' \
		"$config_file"
}

check() {
	description=$1
	shift
	checks=$((checks + 1))

	if "$@"; then
		printf 'ok %d - %s\n' "$checks" "$description"
	else
		printf 'not ok %d - %s\n' "$checks" "$description" >&2
		exit 1
	fi
}

check 'an empty option is absent immediately after a real UCI load' \
	option_is_missing
check 'loading an empty option preserves profile verification state' \
	option_equals lpac_safety.state.profiles_refreshed 1
check 'loading an empty option preserves notification verification state' \
	option_equals lpac_safety.state.notifications_refreshed 1
check 'loading an empty option preserves notification incidents' \
	option_equals lpac_safety.state.notifications "$notification_json"

run_uci set 'lpac_safety.state.profiles_refreshed=0'
run_uci commit lpac_safety
check 'a real UCI commit omits the empty option from canonical storage' \
	file_omits_empty_incident
run_uci set 'lpac_safety.state.profiles_refreshed=1'
run_uci commit lpac_safety
check 'canonical commit restores profile verification state' \
	option_equals lpac_safety.state.profiles_refreshed 1
check 'canonical commit preserves notification incidents' \
	option_equals lpac_safety.state.notifications "$notification_json"

download_incident=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
run_uci set "lpac_safety.state.download_incident=$download_incident"
run_uci commit lpac_safety
check 'a non-empty 32-character incident survives commit and reload' \
	option_equals lpac_safety.state.download_incident "$download_incident"

run_uci set 'lpac_safety.state.download_incident='
run_uci commit lpac_safety
check 'setting an incident to empty deletes it after commit and reload' \
	option_is_missing
check 'deleting an incident leaves no empty placeholder on disk' \
	file_omits_empty_incident
check 'deleting an incident preserves unrelated notification incidents' \
	option_equals lpac_safety.state.notifications "$notification_json"

check 'a retained legacy preference file has no backend setup section' \
	backend_section_is_missing
check 'a retained legacy preference file keeps its section type' \
	option_equals luci_lpac.profiles preferences
check 'a legacy preference value survives a real UCI load' \
	option_equals luci_lpac.profiles.refresh_prompted 1

run_uci set 'luci_lpac.backend=setup'
run_uci set 'luci_lpac.backend.confirmed_apdu_backend=mbim'
run_uci commit luci_lpac
check 'a confirmed backend marker survives commit and fresh readback' \
	option_equals luci_lpac.backend.confirmed_apdu_backend mbim
check 'backend-marker commit preserves the refresh preference' \
	option_equals luci_lpac.profiles.refresh_default 0
check 'backend-marker commit preserves unknown preference options' \
	option_equals luci_lpac.profiles.vendor_option keep
check 'backend-marker commit preserves unknown sections' \
	option_equals luci_lpac.future.value preserve

run_uci set 'luci_lpac.backend.confirmed_apdu_backend=pending'
run_uci commit luci_lpac
check 'the pending backend sentinel survives canonical UCI storage' \
	option_equals luci_lpac.backend.confirmed_apdu_backend pending

printf '1..%d\n' "$checks"
