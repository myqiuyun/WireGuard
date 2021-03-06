#!/usr/local/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (C) 2015-2018 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
#

# The shebang is in /usr/local because this requires bash 4.

set -e -o pipefail
shopt -s extglob
export LC_ALL=C

SELF="${BASH_SOURCE[0]}"
SELF="$(cd "${SELF%/*}" && pwd -P)/${SELF##*/}"
export PATH="${SELF%/*}:$PATH"

WG_CONFIG=""
INTERFACE=""
ADDRESSES=( )
MTU=""
DNS=( )
TABLE=""
PRE_UP=( )
POST_UP=( )
PRE_DOWN=( )
POST_DOWN=( )
SAVE_CONFIG=0
CONFIG_FILE=""
PROGRAM="${0##*/}"
ARGS=( "$@" )

parse_options() {
	local interface_section=0 line key value stripped
	CONFIG_FILE="$1"
	[[ $CONFIG_FILE =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] && CONFIG_FILE="/etc/wireguard/$CONFIG_FILE.conf"
	[[ -e $CONFIG_FILE ]] || die "\`$CONFIG_FILE' does not exist"
	[[ $CONFIG_FILE =~ (^|/)([a-zA-Z0-9_=+.-]{1,15})\.conf$ ]] || die "The config file must be a valid interface name, followed by .conf"
	CONFIG_FILE="$(cd "${CONFIG_FILE%/*}" && pwd -P)/${CONFIG_FILE##*/}"
	((($(stat -f '0%#p' "$CONFIG_FILE") & $(stat -f '0%#p' "${CONFIG_FILE%/*}") & 0007) == 0)) || echo "Warning: \`$CONFIG_FILE' is world accessible" >&2
	INTERFACE="${BASH_REMATCH[2]}"
	shopt -s nocasematch
	while read -r line || [[ -n $line ]]; do
		stripped="${line%%\#*}"
		key="${stripped%%=*}"; key="${key##*([[:space:]])}"; key="${key%%*([[:space:]])}"
		value="${stripped#*=}"; value="${value##*([[:space:]])}"; value="${value%%*([[:space:]])}"
		[[ $key == "["* ]] && interface_section=0
		[[ $key == "[Interface]" ]] && interface_section=1
		if [[ $interface_section -eq 1 ]]; then
			case "$key" in
			Address) ADDRESSES+=( ${value//,/ } ); continue ;;
			MTU) MTU="$value"; continue ;;
			DNS) DNS+=( ${value//,/ } ); continue ;;
			Table) TABLE="$value"; continue ;;
			PreUp) PRE_UP+=( "$value" ); continue ;;
			PreDown) PRE_DOWN+=( "$value" ); continue ;;
			PostUp) POST_UP+=( "$value" ); continue ;;
			PostDown) POST_DOWN+=( "$value" ); continue ;;
			SaveConfig) read_bool SAVE_CONFIG "$value"; continue ;;
			esac
		fi
		WG_CONFIG+="$line"$'\n'
	done < "$CONFIG_FILE"
	shopt -u nocasematch
}

read_bool() {
	case "$2" in
	true) printf -v "$1" 1 ;;
	false) printf -v "$1" 0 ;;
	*) die "\`$2' is neither true nor false"
	esac
}

cmd() {
	echo "[#] $*" >&2
	"$@"
}

die() {
	echo "$PROGRAM: $*" >&2
	exit 1
}

auto_su() {
	[[ $UID == 0 ]] || exec sudo -p "$PROGRAM must be run as root. Please enter the password for %u to continue: " "$SELF" "${ARGS[@]}"
}

get_real_interface() {
	local interface diff
	wg show interfaces >/dev/null
	[[ -f "/var/run/wireguard/$INTERFACE.name" ]] || return 1
	interface="$(< "/var/run/wireguard/$INTERFACE.name")"
	[[ -n $interface && -S "/var/run/wireguard/$interface.sock" ]] || return 1
	diff=$(( $(stat -f %m "/var/run/wireguard/$interface.sock" 2>/dev/null || echo 200) - $(stat -f %m "/var/run/wireguard/$INTERFACE.name" 2>/dev/null || echo 100) ))
	[[ $diff -ge 2 || $diff -le -2 ]] && return 1
	REAL_INTERFACE="$interface"
	echo "[+] Interface for $INTERFACE is $REAL_INTERFACE" >&2
	return 0
}

add_if() {
	export WG_DARWIN_UTUN_NAME_FILE="/var/run/wireguard/$INTERFACE.name"
	cmd wireguard-go utun
	local i
	for i in {1..30}; do
		[[ -f "/var/run/wireguard/$INTERFACE.name" ]] && break
		sleep 0.1
	done
	get_real_interface
}

del_routes() {
	local todelete=( ) destination netif
	while read -r destination _ _ _ _ netif _; do
		[[ $netif == "$REAL_INTERFACE" ]] && todelete+=( "$destination" )
	done < <(netstat -nr -f inet)
	for destination in "${todelete[@]}"; do
		cmd route -q delete -inet "$destination" >/dev/null || true
	done
	todelete=( )
	while read -r destination _ _ netif; do
		[[ $netif == "$REAL_INTERFACE" ]] && todelete+=( "$destination" )
	done < <(netstat -nr -f inet6)
	for destination in "${todelete[@]}"; do
		cmd route -q delete -inet6 "$destination" >/dev/null || true
	done
	for destination in "${ENDPOINTS[@]}"; do
		if [[ $destination == *:* ]]; then
			cmd route -q delete -inet6 "$destination" >/dev/null || true
		else
			cmd route -q delete -inet "$destination" >/dev/null || true
		fi
	done
}

del_if() {
	[[ -z $REAL_INTERFACE ]] || cmd rm -f "/var/run/wireguard/$REAL_INTERFACE.sock"
	cmd rm -f "/var/run/wireguard/$INTERFACE.name"
}

up_if() {
	cmd ifconfig "$REAL_INTERFACE" up
}

add_addr() {
	if [[ $1 == *:* ]]; then
		cmd ifconfig "$REAL_INTERFACE" inet6 "$1"
	else
		cmd ifconfig "$REAL_INTERFACE" inet "$1" "${1%%/*}"
	fi
}

set_mtu() {
	local mtu=0 current_mtu=-1 destination netif defaultif
	if [[ -n $MTU ]]; then
		cmd ifconfig "$REAL_INTERFACE" mtu "$MTU"
		return
	fi
	while read -r destination _ _ _ _ netif _; do
		if [[ $destination == default ]]; then
			defaultif="$netif"
			break
		fi
	done < <(netstat -nr -f inet)
	[[ -n $defaultif &&  $(ifconfig "$defaultif") =~ mtu\ ([0-9]+) ]] && mtu="${BASH_REMATCH[1]}"
	[[ $mtu -gt 0 ]] || mtu=1500
	mtu=$(( mtu - 80 ))
	[[ $(ifconfig "$REAL_INTERFACE") =~ mtu\ ([0-9]+) ]] && current_mtu="${BASH_REMATCH[1]}"
	[[ $mtu -eq $current_mtu ]] || cmd ifconfig "$REAL_INTERFACE" mtu "$mtu"
}

collect_gateways() {
	local destination gateway

	GATEWAY4=""
	while read -r destination gateway _; do
		[[ $destination == default ]] || continue
		GATEWAY4="$gateway"
		break
	done < <(netstat -nr -f inet)

	GATEWAY6=""
	while read -r destination gateway _; do
		[[ $destination == default ]] || continue
		[[ $gateway == fe80:* ]] && continue
		GATEWAY6="$gateway"
		break
	done < <(netstat -nr -f inet6)
}

collect_endpoints() {
	ENDPOINTS=( )
	while read -r _ endpoint; do
		[[ $endpoint =~ ^\[?([a-z0-9:.]+)\]?:[0-9]+$ ]] || continue
		ENDPOINTS+=( "${BASH_REMATCH[1]}" )
	done < <(wg show "$REAL_INTERFACE" endpoints)
}

set_endpoint_direct_route() {
	local old_endpoints endpoint old_gateway4 old_gateway6 remove_all_old=0 added=( )
	old_endpoints=( "${ENDPOINTS[@]}" )
	old_gateway4="$GATEWAY4"
	old_gateway6="$GATEWAY6"
	collect_gateways
	collect_endpoints

	[[ $old_gateway4 != "$GATEWAY4" || $old_gateway6 != "$GATEWAY6" ]] && remove_all_old=1

	if [[ $remove_all_old -eq 1 ]]; then
		for endpoint in "${ENDPOINTS[@]}"; do
			[[ " ${old_endpoints[*]} " == *"$endpoint"* ]] || old_endpoints+=( "$endpoint" )
		done
	fi

	for endpoint in "${old_endpoints[@]}"; do
		[[ $remove_all_old -eq 0 && " ${ENDPOINTS[*]} " == *"$endpoint"* ]] && continue
		if [[ $endpoint == *:* ]]; then
			cmd route -q delete -inet6 "$endpoint" >/dev/null 2>&1 || true
		else
			cmd route -q delete -inet "$endpoint" >/dev/null 2>&1 || true
		fi
	done

	for endpoint in "${ENDPOINTS[@]}"; do
		if [[ $remove_all_old -eq 0 && " ${old_endpoints[*]} " == *"$endpoint"* ]]; then
			added+=( "$endpoint" )
			continue
		fi
		if [[ $endpoint == *:* && -n $GATEWAY6 ]]; then
			cmd route -q add -inet6 "$endpoint" -gateway "$GATEWAY6" >/dev/null || true
			added+=( "$endpoint" )
		elif [[ -n $GATEWAY4 ]]; then
			cmd route -q add -inet "$endpoint" -gateway "$GATEWAY4" >/dev/null || true
			added+=( "$endpoint" )
		fi
	done
	ENDPOINTS=( "${added[@]}" )
}

set_dns() {
	# TODO: this should use scutil and be slightly more clever. But for now
	# we simply overwrite any _manually set_ DNS servers for all network
	# services. This means we get into trouble if the user doesn't actually
	# want DNS via DHCP when setting this back to "empty". Because macOS is
	# so horrible to deal with here, we'll simply wait for irate users to
	# provide a patch themselves.

	local service response

	{ read -r _; while read -r service; do
		[[ $service == "*"* ]] && service="${service:1}"
		while read -r response; do
			[[ $response == *Error* ]] && echo "$response" >&2
		done < <(cmd networksetup -setdnsservers "$service" "${DNS[@]}")
	done; } < <(networksetup -listallnetworkservices)
}

del_dns() {
	{ read -r _; while read -r service; do
		[[ $service == "*"* ]] && service="${service:1}"
		while read -r response; do
			[[ $response == *Error* ]] && echo "$response" >&2
		done < <(cmd networksetup -setdnsservers "$service" Empty)
	done; } < <(networksetup -listallnetworkservices)
}

monitor_daemon() {
	echo "[+] Backgrounding route monitor" >&2
	(trap 'del_routes; del_dns; exit 0' INT TERM EXIT
	exec 1>&- 2>&-
	local event
	# TODO: this should also check to see if the endpoint actually changes
	# in response to incoming packets, and then call set_endpoint_direct_route
	# then too. That function should be able to gracefully cleanup if the
	# endpoints change.
	while read -r event; do
		[[ $event == RTM_* ]] || continue
		ifconfig "$REAL_INTERFACE" >/dev/null 2>&1 || break
		[[ $AUTO_ROUTE4 -eq 1 || $AUTO_ROUTE6 -eq 1 ]] && set_endpoint_direct_route
		[[ -z $MTU ]] && set_mtu
		[[ ${#DNS[@]} -gt 0 ]] && set_dns
	done < <(route -n monitor)) & disown
}

add_route() {
	[[ $TABLE != off ]] || return 0

	local family=inet
	[[ $1 == *:* ]] && family=inet6

	if [[ $1 == */0 && ( -z $TABLE || $TABLE == auto ) ]]; then
		if [[ $1 == *:* ]]; then
			AUTO_ROUTE6=1
			cmd route -q add -inet6 ::/1 -interface "$REAL_INTERFACE" >/dev/null
			cmd route -q add -inet6 8000::/1 -interface "$REAL_INTERFACE" >/dev/null
		else
			AUTO_ROUTE4=1
			cmd route -q add -inet 0.0.0.0/1 -interface "$REAL_INTERFACE" >/dev/null
			cmd route -q add -inet 128.0.0.0/1 -interface "$REAL_INTERFACE" >/dev/null
		fi
	else
		[[ $TABLE == main || $TABLE == auto || -z $TABLE ]] || die "Darwin only supports TABLE=auto|main|off"
		cmd route -q add "-$family" "$1" -interface "$REAL_INTERFACE" >/dev/null
	fi
}

set_config() {
	cmd wg setconf "$REAL_INTERFACE" <(echo "$WG_CONFIG")
}

save_config() {
	local old_umask new_config current_config address cmd
	new_config=$'[Interface]\n'
	for address in "${ADDRESSES[@]}"; do
		new_config+="Address = $address"$'\n'
	done
	for address in "${DNS[@]}"; do
		new_config+="DNS = $address"$'\n'
	done
	[[ -n $MTU ]] && new_config+="MTU = $MTU"$'\n'
	[[ -n $TABLE ]] && new_config+="Table = $TABLE"$'\n'
	[[ $SAVE_CONFIG -eq 0 ]] || new_config+=$'SaveConfig = true\n'
	for cmd in "${PRE_UP[@]}"; do
		new_config+="PreUp = $cmd"$'\n'
	done
	for cmd in "${POST_UP[@]}"; do
		new_config+="PostUp = $cmd"$'\n'
	done
	for cmd in "${PRE_DOWN[@]}"; do
		new_config+="PreDown = $cmd"$'\n'
	done
	for cmd in "${POST_DOWN[@]}"; do
		new_config+="PostDown = $cmd"$'\n'
	done
	old_umask="$(umask)"
	umask 077
	current_config="$(cmd wg showconf "$REAL_INTERFACE")"
	trap 'rm -f "$CONFIG_FILE.tmp"; exit' INT TERM EXIT
	echo "${current_config/\[Interface\]$'\n'/$new_config}" > "$CONFIG_FILE.tmp" || die "Could not write configuration file"
	sync "$CONFIG_FILE.tmp"
	mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" || die "Could not move configuration file"
	trap - INT TERM EXIT
	umask "$old_umask"
}

execute_hooks() {
	local hook
	for hook in "$@"; do
		hook="${hook//%i/$REAL_INTERFACE}"
		hook="${hook//%I/$INTERFACE}"
		echo "[#] $hook" >&2
		(eval "$hook")
	done
}

cmd_usage() {
	cat >&2 <<-_EOF
	Usage: $PROGRAM [ up | down | save ] [ CONFIG_FILE | INTERFACE ]

	  CONFIG_FILE is a configuration file, whose filename is the interface name
	  followed by \`.conf'. Otherwise, INTERFACE is an interface name, with
	  configuration found at /etc/wireguard/INTERFACE.conf. It is to be readable
	  by wg(8)'s \`setconf' sub-command, with the exception of the following additions
	  to the [Interface] section, which are handled by $PROGRAM:

	  - Address: may be specified one or more times and contains one or more
	    IP addresses (with an optional CIDR mask) to be set for the interface.
	  - DNS: an optional DNS server to use while the device is up.
	  - MTU: an optional MTU for the interface; if unspecified, auto-calculated.
	  - Table: an optional routing table to which routes will be added; if
	    unspecified or \`auto', the default table is used. If \`off', no routes
	    are added. Besides \`auto' and \`off', only \`main' is supported on
	    this platform.
	  - PreUp, PostUp, PreDown, PostDown: script snippets which will be executed
	    by bash(1) at the corresponding phases of the link, most commonly used
	    to configure DNS. The string \`%i' is expanded to INTERFACE.
	  - SaveConfig: if set to \`true', the configuration is saved from the current
	    state of the interface upon shutdown.

	See wg-quick(8) for more info and examples.
	_EOF
}

cmd_up() {
	local i
	get_real_interface && die "\`$INTERFACE' already exists as \`$REAL_INTERFACE'"
	trap 'del_if; del_routes; exit' INT TERM EXIT
	execute_hooks "${PRE_UP[@]}"
	add_if
	set_config
	for i in "${ADDRESSES[@]}"; do
		add_addr "$i"
	done
	set_mtu
	up_if
	for i in $(while read -r _ i; do for i in $i; do [[ $i =~ ^[0-9a-z:.]+/[0-9]+$ ]] && echo "$i"; done; done < <(wg show "$REAL_INTERFACE" allowed-ips)); do
		add_route "$i"
	done
	[[ $AUTO_ROUTE4 -eq 1 || $AUTO_ROUTE6 -eq 1 ]] && set_endpoint_direct_route
	[[ ${#DNS[@]} -gt 0 ]] && set_dns
	monitor_daemon
	execute_hooks "${POST_UP[@]}"
	trap - INT TERM EXIT
}

cmd_down() {
	if ! get_real_interface || [[ " $(wg show interfaces) " != *" $REAL_INTERFACE "* ]]; then
		die "\`$INTERFACE' is not a WireGuard interface"
	fi
	execute_hooks "${PRE_DOWN[@]}"
	[[ $SAVE_CONFIG -eq 0 ]] || save_config
	del_if
	execute_hooks "${POST_DOWN[@]}"
}

cmd_save() {
	if ! get_real_interface || [[ " $(wg show interfaces) " != *" $REAL_INTERFACE "* ]]; then
		die "\`$INTERFACE' is not a WireGuard interface"
	fi
	save_config
}

# ~~ function override insertion point ~~

if [[ $# -eq 1 && ( $1 == --help || $1 == -h || $1 == help ) ]]; then
	cmd_usage
elif [[ $# -eq 2 && $1 == up ]]; then
	auto_su
	parse_options "$2"
	cmd_up
elif [[ $# -eq 2 && $1 == down ]]; then
	auto_su
	parse_options "$2"
	cmd_down
elif [[ $# -eq 2 && $1 == save ]]; then
	auto_su
	parse_options "$2"
	cmd_save
else
	cmd_usage
	exit 1
fi

exit 0
