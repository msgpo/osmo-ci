#!/bin/sh -e
# Environment variables:
# * PARALLEL_MAKE: -jN argument for make (default: -j5).
# * SKIP_MASTER: don't build REPOS_MASTER (assume that they were just built and keep _temp).
#
# Latest result:
# https://jenkins.osmocom.org/jenkins/job/Osmocom-build-tags-against-master/lastBuild/console

cd "$(dirname "$0")"
. ./common.sh
ERROR_LOGS=""
PARALLEL_MAKE="${PARALLEL_MAKE:--j5}"

REPOS_MASTER="
	libosmocore
	libosmo-abis
	libosmo-netif
	libosmo-sccp
	libsmpp34
	libasn1c
	osmo-ggsn
	osmo-iuh
	osmo-hlr
	osmo-mgw
"

REPOS_TAGS="
	libosmo-abis
	libosmocore
	libosmo-netif
	libosmo-sccp
	openbsc
	osmo-bsc
	osmo-bts
	osmo-ggsn
	osmo-hlr
	osmo-iuh
	osmo-mgw
	osmo-msc
	osmo-pcu
	osmo-sgsn
	osmo-sip-connector
	osmo-trx
"

# Print tags, which should be built, but where errors are expected and should be ignored.
# This function is part of the configuration, do not insert functions above.
# $1: repository
# output format: one tag per line
tags_to_ignore() {
	case "$1" in
		openbsc)
			echo "1.0.0" # testsuite
			;;
		osmo-bsc)
			echo "1.2.1" # depends on libosmo-legacy-mgcp
			echo "1.4.0" # testsuite
			;;
		osmo-bts)
			echo "1.0.0" # missing gsm0808.h include, fixed in 1.0.1
			;;
		osmo-mgw)
			echo "1.3.0" # testsuite
			echo "1.4.0" # testsuite
			;;
		osmo-msc)
			echo "1.3.0" # -Werror and deprecated gsm0480_create_ussd_release_complete(), fixed in 1.3.1
			;;
		osmo-pcu)
			echo "0.5.0" # testsuite
			;;
		osmo-sgsn)
			echo "1.2.0" # sgsn_test.c: gtp.h: No such file or directory
			echo "1.3.0" # testsuite
			echo "1.4.0" # testsuite
			;;
	esac
}

# Print which tags should be built for a specific repository.
# This function is part of the configuration.
# $1: repository
# output format: one tag per line
tags_to_build() {
	case "$1" in
		# Add repository specific tag listings here:
		# libosmocore)
		#	echo "0.1.0"
		#	osmo_git_last_tags "$1" 3
		#	;;
		*)
			osmo_git_last_tags "$1" 3
			;;
	esac
}

# Delete existing temp dir and create a new one, output the path.
prepare_temp_dir() {
	TEMP="$(cd ..; pwd)/_temp"
	if [ -n "$SKIP_MASTER" ]; then
		if ! [ -d "$TEMP" ]; then
			echo "ERROR: SKIP_MASTER is set, but temp dir not found: $TEMP"
			exit 1
		fi
	else
		if [ -d "$TEMP" ]; then
			rm -r "$TEMP"
		fi
	fi
	mkdir -p "$TEMP/log"
	echo "Temp dir: $TEMP"
}

# When builds have failed, print the last lines of each failing log and exit with 1.
show_errors_exit() {
	local log

	if [ -z "$ERROR_LOGS" ]; then
		return 0
	fi

	for log in $ERROR_LOGS; do
		echo "---"
		echo "BUILD FAILED: $(basename "$log")"
		echo "Showing last lines of build log below (full log in temp dir/jenkins artifacts):"
		echo "---"
		tail -n 20 "$log"
	done

	echo "---"
	exit 1
}

# Build a repository either from master or from a specific tag against master.
# The build output is redirected to a file, and partially shown on error.
# $1: installation path (either $TEMP/inst_master or $TEMP/inst)
# $2: repository
# $3: branch, tag or commit
# returns: 0 on sucessful build, 1 on error
build_repo() {
	local log="$TEMP/log/$2-$3.txt"

	if ! PATH="$PWD:$PATH"\
		PKG_CONFIG_PATH="$TEMP/inst_master/lib/pkgconfig:$PKG_CONFIG_PATH" \
		LD_LIBRARY_PATH="$TEMP/inst_master/lib:$LD_LIBRARY_PATH" \
		MAKE="make" \
		PARALLEL_MAKE="$PARALLEL_MAKE" \
		CHECK="1" \
		deps="../_deps" \
		inst="$1" \
		./osmo-build-dep.sh "$2" "$3" \
		> "$log" 2>&1
	then
		return 1
	fi
}

# Build all configured repositories from master and install to $TEMP/inst_master.
build_repos_master() {
	local repo_master

	echo "Building libraries from current master..."

	if [ -n "$SKIP_MASTER" ]; then
		echo "=> SKIPPED (SKIP_MASTER is set)"
		return
	fi

	for repo_master in $REPOS_MASTER; do
		local commit="$(osmo_git_head_commit "$repo_master")"
		if [ -z "$commit" ]; then
			echo "ERROR: failed to get head commit for repository: $repo_master"
			exit 1
		fi

		printf "%-21s %s" " * $repo_master" "$commit"
		if ! build_repo "$TEMP/inst_master" "$repo_master" "$commit"; then
			printf "\n"
			ERROR_LOGS="$TEMP/log/$repo_master-$commit.txt"
			show_errors_exit
		fi
		printf "\n"
	done
}

# $1: repository
# $2: tag
# returns: 0 when the error should be ignored, 1 otherwise
ignore_error() {
	local tag
	for tag in $(tags_to_ignore "$1"); do
		if [ "$2" = "$tag" ]; then
			return 0
		fi
	done
	return 1
}

# Build all configured repositories on specific tags against master. The result is installed to $TEMP/inst, but deleted
# after each build.
build_repos_tags() {
	local repo

	echo "Building old tags against libraries from current master... (ERR: new error, err: known error)"
	for repo in $REPOS_TAGS; do
		local tags="$(tags_to_build "$repo" | sort -V | tr '\n' ' ')"
		if [ -z "$tags" ]; then
			printf "%-21s %s\n" " * $repo" "(no tags configured)"
			continue
		fi
		printf "%-21s" " * $repo"

		local tag
		for tag in $tags; do
			printf "%10s" " $tag"
			if [ -d "$TEMP/inst" ]; then
				rm -r "$TEMP/inst"
			fi
			if build_repo "$TEMP/inst" "$repo" "$tag"; then
				printf "      "
			elif ignore_error "$repo" "$tag"; then
				printf " (err)"
			else
				printf " (ERR)"
				ERROR_LOGS="$ERROR_LOGS $TEMP/log/$repo-$tag.txt"
			fi
		done
		printf "\n"
	done
}

prepare_temp_dir
build_repos_master
build_repos_tags
show_errors_exit
