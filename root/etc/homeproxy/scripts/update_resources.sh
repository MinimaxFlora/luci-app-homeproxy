#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2025 ImmortalWrt.org

. /usr/share/libubox/jshn.sh

NAME="homeproxy"

RESOURCES_DIR="/etc/$NAME/resources"
mkdir -p "$RESOURCES_DIR"

RUN_DIR="/var/run/$NAME"
LOG_PATH="$RUN_DIR/$NAME.log"
mkdir -p "$RUN_DIR"

log() {
	echo -e "$(date "+%Y-%m-%d %H:%M:%S") $*" >> "$LOG_PATH"
}

to_upper() {
	echo -e "$1" | tr "[a-z]" "[A-Z]"
}

check_list_update() {
	local listtype="$1"
	local listrepo="$2"
	local listref="$3"
	local listname="$4"
	local lock="$RUN_DIR/update_resources-$listtype.lock"
	local github_token="$(uci -q get homeproxy.config.github_token)"
	local wget="wget --timeout=10 -q"

	exec 200>"$lock"
	if ! flock -n 200 &> "/dev/null"; then
		log "[$(to_upper "$listtype")] A task is already running."
		return 2
	fi

	[ -z "$github_token" ] || github_token="--header=Authorization: Bearer $github_token"
	local list_info="$($wget "${github_token:--q}" -O- "https://api.github.com/repos/$listrepo/commits?sha=$listref&path=$listname&per_page=1")"
	local list_sha="$(echo -e "$list_info" | jsonfilter -qe "@[0].sha")"
	local list_ver="$(echo -e "$list_info" | jsonfilter -qe "@[0].commit.message" | grep -Eo "[0-9-]+" | tr -d '-')"
	if [ -z "$list_sha" ] || [ -z "$list_ver" ]; then
		log "[$(to_upper "$listtype")] Failed to get the latest version, please retry later."
		return 1
	fi

	local local_list_ver="$(cat "$RESOURCES_DIR/$listtype.ver" 2>"/dev/null" || echo "NOT FOUND")"
	if [ "$local_list_ver" = "$list_ver" ]; then
		log "[$(to_upper "$listtype")] Current version: $list_ver."
		log "[$(to_upper "$listtype")] You're already at the latest version."
		return 3
	else
		log "[$(to_upper "$listtype")] Local version: $local_list_ver, latest version: $list_ver."
	fi

	if ! $wget "https://fastly.jsdelivr.net/gh/$listrepo@$list_sha/$listname" -O "$RUN_DIR/$listname" || [ ! -s "$RUN_DIR/$listname" ]; then
		rm -f "$RUN_DIR/$listname"
		log "[$(to_upper "$listtype")] Update failed."
		return 1
	fi

	mv -f "$RUN_DIR/$listname" "$RESOURCES_DIR/$listtype.${listname##*.}"
	echo -e "$list_ver" > "$RESOURCES_DIR/$listtype.ver"
	log "[$(to_upper "$listtype")] Successfully updated."

	return 0
}

get_local_vers() {
	local ver_file="$1"
	local repoid="$2"

	local ver="$(eval "jsonfilter -qi \"$ver_file\" -e '@[\"$repoid\"].version'")"
	[ -n "$ver" ] && echo "$ver" || return 1
}

check_clash_dashboard_update() {
	local dashtype="$1"
	local dashrepo="$2"
	local dashrepoid="$(echo -n "$dashrepo" | md5sum | cut -f1 -d' ')"
	local lock="$RUN_DIR/update_resources-$dashtype.lock"
	local github_token="$(uci -q get homeproxy.config.github_token)"
	local wget="wget --timeout=10 -q"

	exec 201>"$lock"
	if ! flock -n 201 &> "/dev/null"; then
		log "[$(to_upper "$dashtype")] A task is already running."
		return 2
	fi

	[ -z "$github_token" ] || github_token="--header=Authorization: Bearer $github_token"
	local dashdata_ver="$($wget "${github_token:--q}" -O- "https://api.github.com/repos/$dashrepo/releases/latest" | jsonfilter -e "@.tag_name")"
	if [ -z "$dashdata_ver" ]; then
		log "[$(to_upper "$dashtype")] [$dashrepo] Failed to get the latest version, please retry later."
		return 1
	fi

	local local_dashdata_ver="$(get_local_vers "$RESOURCES_DIR/$dashtype.ver" "$dashrepoid" || echo "NOT FOUND")"
	if [ "$local_dashdata_ver" = "$dashdata_ver" ]; then
		log "[$(to_upper "$dashtype")] [$dashrepo] Current version: $dashdata_ver."
		log "[$(to_upper "$dashtype")] [$dashrepo] You're already at the latest version."
		return 3
	else
		log "[$(to_upper "$dashtype")] [$dashrepo] Local version: $local_dashdata_ver, latest version: $dashdata_ver."
	fi

	if ! $wget "https://github.com/$dashrepo/archive/gh-pages.zip" -O "$RUN_DIR/$dashtype.zip" || [ ! -s "$RUN_DIR/$dashtype.zip" ]; then
		rm -f "$RUN_DIR/$dashtype.zip"
		log "[$(to_upper "$dashtype")] [$dashrepo] Update failed."
		return 1
	fi

	mv -f "$RUN_DIR/$dashtype.zip" "$RESOURCES_DIR/${dashrepo//\//_}.zip"
	touch "$RESOURCES_DIR/$dashtype.ver"
	json_init
	[ ! -s "$RESOURCES_DIR/$dashtype.ver" ] || json_load_file "$RESOURCES_DIR/$dashtype.ver"
	json_add_object "$dashrepoid"
	json_add_string repo "$dashrepo"
	json_add_string version "$dashdata_ver"
	json_close_object
	json_dump > "$RESOURCES_DIR/$dashtype.ver"
	log "[$(to_upper "$dashtype")] [$dashrepo] Successfully updated."

	return 0
}

case "$1" in
"clash_dashboard")
	check_clash_dashboard_update "$1" "$2"
	;;
"china_ip4")
	check_list_update "$1" "1715173329/IPCIDR-CHINA" "master" "ipv4.txt"
	;;
"china_ip6")
	check_list_update "$1" "1715173329/IPCIDR-CHINA" "master" "ipv6.txt"
	;;
"gfw_list")
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "gfw.txt"
	;;
"china_list")
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "direct-list.txt" && \
		sed -i -e "s/full://g" -e "/:/d" "$RESOURCES_DIR/china_list.txt"
	;;
*)
	echo -e "Usage: $0 <clash_dashboard / china_ip4 / china_ip6 / gfw_list / china_list>"
	exit 1
	;;
esac
