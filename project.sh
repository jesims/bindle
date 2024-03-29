#shellcheck shell=bash disable=2215,2034,2039,3033
#@IgnoreInspection BashAddShebang

txtund=$(tput sgr 0 1 2>/dev/null)          # Underline
txtbld=$(tput bold 2>/dev/null)             # Bold
txtital=$(tput sitm 2>/dev/null)            # Italics
grn=$(tput setaf 2 2>/dev/null)             # Green
red=$(tput setaf 1 2>/dev/null)             # Red
bldgrn=${txtbld}$(tput setaf 2 2>/dev/null) # Bold Green
bldred=${txtbld}$(tput setaf 1 2>/dev/null) # Bold Red
txtrst=$(tput sgr0 2>/dev/null)             # Reset

script_name="$(basename "$0")"
project_name="$(basename "$script_name" .sh)"
project_root_dir="$(git rev-parse --show-toplevel)"
githooks_folder='githooks'
#TODO rename, it's confusing with $script_directory
script_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

## True if the script is running inside CircleCI
is-ci() {
	[ -n "$CIRCLECI" ]
}

## True if the script is running inside a local instance of JESI Build-Bus
is-local-build-bus() {
	[ -n "$LOCAL_BUILD_BUS" ]
}

## True if the script is running inside the JESI Docker Development Environment
is-jesi-docker-env() {
	[ -n "$JESI_DOCKER_DEV_ENV" ]
}

echo-message() {
	echo "${bldgrn}[$script_name]${txtrst} ${FUNCNAME[1]}: ${grn}$*${txtrst}"
}

if ! is-ci && [ -d "$githooks_folder" ] && [ "$(git config core.hooksPath)" != "$githooks_folder" ]; then
	echo-message 'Setting up GitHooks'
	git config core.hooksPath "$githooks_folder"
	chmod u+x ${githooks_folder}/*
fi

echo-red() {
	echo "${bldred}[$script_name]${txtrst} ${FUNCNAME[1]}: ${red}$*${txtrst}"
}

echo-error() {
	echo-red "ERROR: $*"
}

abort-on-error() {
	local status=$?
	if [ $status -ne 0 ]; then
		#TODO print out call stack https://gist.github.com/ahendrix/7030300
		echo-error "$*"
		exit $status
	fi
}

var-set() {
	local val
	val=$(eval "echo \$$1")
	[ -n "$val" ]
}

require-var() {
	local var
	for var in "$@"; do
		if ! var-set "$var"; then
			echo-error "$var not defined"
			exit 1
		fi
	done
}

cmd-exists() {
	type "$1" &>/dev/null
}

require-cmd() {
	local cmd
	for cmd in "$@"; do
		if ! cmd-exists "$cmd"; then
			echo-error "$cmd not installed"
			exit 1
		fi
	done
}

file-exists() {
	# `test -r file` when running on Alpine and ECS/Fargate is failing for an unknown reason.
	# Running the exact Docker Image locally however does not exhibit the same issues.
	# The `head -n 1 file` is a hack to ensure we have read permissions
	[ -r "$1" ] || ([ -f "$1" ] && head -n 1 "$1" >/dev/null 2>&1)
}

dir-exists() {
	[ -d "$1" ]
}

require-file() {
	local file
	for file in "$@"; do
		if ! file-exists "$file"; then
			echo-error "File not found: $file"
			exit 1
		fi
	done
}

require-file-not-empty() {
	local file
	for file in "$@"; do
		require-file "$file"
		if [ ! -s "$file" ]; then
			echo-error "file is empty $file"
			exit 1
		fi
	done
}

require-committed() {
	local file=$1
	if file-exists "$file"; then
		git diff --quiet --exit-code "$file"
		if [ $? -ne 0 ]; then
			echo-error "uncommitted changes in $file"
			git diff --compact-summary "$file"
			exit 1
		fi
	fi
}

usage() {
	local doc desc line synopsis fun args
	doc=$(grep '^##' "${script_name}" | sed -e 's/^##//')
	desc=''
	synopsis=''
	while read -r line; do
		if [[ $line == *: ]]; then
			fun=${line::-1}
			synopsis+="\n\t${script_name} ${txtbld}${fun}${txtrst}"
			desc+="\n\t${txtbld}$fun${txtrst}"
		elif [[ $line == args:* ]]; then
			args="$(cut -d ':' -f 2- <<<"$line")"
			synopsis+="$args"
		elif [[ $line =~ ^(<[{)* ]]; then
			desc+="\n\t\t\t${line}"
		else
			desc+="\n\t\t${line}"
		fi
	done <<<"$doc"
	echo -e "${txtbld}SYNOPSIS${txtrst}${synopsis}\n\n${txtbld}DESCRIPTION${txtrst}${desc}"
}

script-invoke() {
	if [ "$#" -eq 0 ]; then
		usage
		exit 1
	elif [[ $1 =~ ^(help|-h|--help)$ ]]; then
		usage
		exit 0
	elif (grep -qE -e "^$1[\\t ]*?\\([\\t ]*?\\)" "$script_name"); then
		"$@"
	else
		echo-error "Unknown function $1 ($script_name $*)"
		exit 1
	fi
}

confirm() {
	local msg=$1
	local expected=$2
	read -r -p "$msg ($expected): " response
	if [ "$response" != "$expected" ]; then
		echo-message 'Aborted'
		exit 0
	fi
}

pause() {
	read -r -n1 -p 'Press any key to continue...'
}

get-version() {
	local file=VERSION
	require-file "$file"
	cat "$file"
}

set-version() {
	echo "$1" >VERSION
}

is-snapshot() {
	[[ "$(get-version)" == *SNAPSHOT ]]
}

lein-dev() {
	local profile='+dev'
	if [ -n "$LEIN_DEV_PROFILE" ]; then
		profile="$profile,$LEIN_DEV_PROFILE"
	fi
	lein -U with-profile "$profile" "$@"
}

lein-install() {
	local cmd="lein -U with-profile +install,-dev $*"
	$cmd
	abort-on-error "running $cmd"
}

lein-jar() {
	echo-message 'Building'
	allow-snapshots
	lein -U with-profile -dev jar "$@"
	abort-on-error 'building'
}

lein-uberjar() {
	echo-message 'Building'
	allow-snapshots
	lein -U with-profile -dev,+uberjar uberjar "$@"
	abort-on-error 'building'
}

deploy-clojars() {
	echo-message "Deploying $(get-version) to Clojars"
	if is-ci; then
		lein-install deploy clojars &>/dev/null
	else
		lein-install deploy clojars
	fi
	abort-on-error
}

deps-ci() {
	if is-ci; then
		# shellcheck disable=2215
		-deps "$@"
	fi
}

lein-test() {
	deps-ci "$@"
	local test_cmd="lein-dev test $*"
	echo-message "Running test $*"
	copy-to-project 'tests.edn'
	$test_cmd
	abort-on-error 'running tests'
}

shadow-cljs() {
	lein-dev shadow-cljs "$@"
}

lein-clean() {
	echo-message 'Cleaning'
	lein clean
	abort-on-error 'cleaning'
}

copy-to-project() {
	local file_path
	for file_path in "$@"; do
		if ! file-exists "$file_path"; then
			local dir
			dir=$(dirname "$file_path")
			abort-on-error "$dir"
			if [ -n "$dir" ]; then
				mkdir -p "$dir"
			fi
			cp -r "$script_dir/template/$file_path" "$file_path"
			abort-on-error 'copying file to project'
		fi
	done
}

npm-install-missing() {
	#TODO speed up detecting installed packages
	npm list --depth=0 --parseable=true "$@" >/dev/null 2>&1 || npm install "$@"
	abort-on-error "installing $*"
}

format-markdown() {
	local dir='.bindle/markdown'
	echo-message 'Installing Remark Tools'
	trap-exit rm -f "$project_root_dir/.remarkignore"
	trap-exit rm -f "$project_root_dir/.remarkrc.js"
	trap-exit rm -rf "$project_root_dir/$dir"
	mkdir -p "$dir"
	(
		cd "$dir" || exit 1
		copy-to-project 'remark'
		cd remark || exit 1
		cp '.remarkignore' "$project_root_dir/" && cp '.remarkrc.js' "$project_root_dir/" || exit 1
		npm ci --no-audit --no-fund
		abort-on-error 'installing Remark'
		npx --prefix . remark "$project_root_dir" --output
		abort-on-error 'running remark'
	)
}

lint-circle-config() {
	local file='.circleci/config.yml'
	if file-exists "$file"; then
		if is-ci; then
			require-committed .circleci
		else
			echo-message "Checking $file"
			circleci config validate --org-slug github/jesims
			abort-on-error 'validating CircleCI'
		fi
	fi
}

checksum() {
	local file="$1"
	file=$(file-exists "$file" && cat "$file")
	echo "$file" | cksum | awk '{print $1}'
}

checksum-different() {
	local target="$1.cksum"
	[ "$(file-exists "$target" && cat "$target")" != "$(checksum "$1")" ]
}

on-files-changed() {
	local cmd=$1
	local files=${*:2}
	local changed=0
	local file
	for file in $files; do
		if ! file-exists "$file" || checksum-different "$file"; then
			changed=1
			break
		fi
	done
	if [ $changed -eq 1 ]; then
		$cmd
		for file in $files; do
			checksum "$file" >"${file}.cksum"
		done
	fi
}

branch-name() {
	git rev-parse --abbrev-ref HEAD
}

# Invoked during `wait-for` executions to pause invocations.
# To use, override inside the executing function before `wait-for` invocation
#
# do-thing(){
#		-wait-for-sleep() {
#			sleep 15s
#		}
#		wait-for 'Waiting for Something Amazing' 1200 _bash-predicated-function "$arg1" "$arg2"
# }
-wait-for-sleep() {
	sleep 1
}

wait-for() {
	require-var -wait-for-sleep
	local name timeout test_commands
	name="$1"
	timeout="$2"
	test_commands="${*:3}"
	require-var name timeout test_commands
	# since we need this to work on bash 4.0:
	# shellcheck disable=2003
	timeout="$(expr "$(date +%s)" + "$timeout")"
	until $test_commands; do
		if [ "$(date +%s)" -le "$timeout" ]; then
			echo-message "Waiting for $name"
			-wait-for-sleep
		else
			echo-error 'Timeout'
			exit 1
		fi
	done
}

allow-snapshots() {
	if [ "$(branch-name)" != "master" ]; then
		export LEIN_SNAPSHOTS_IN_RELEASE=1
	fi
}

require-no-snapshot-use() {
	local project_file=$1
	allow-snapshots
	if [ -z "$LEIN_SNAPSHOTS_IN_RELEASE" ]; then
		local matches
		matches=$(grep "\-SNAPSHOT" "$project_file")
		if [ -n "$matches" ]; then
			echo-error "SNAPSHOT dependencies found in $project_file."
			echo-error "$matches"
			exit 1
		fi
	fi
}

require-no-snapshot() {
	if is-snapshot; then
		echo-error 'SNAPSHOT suffix already defined'
		exit 1
	fi
}

just-die() {
	local cmd pids
	for cmd in "$@"; do
		#shellcheck disable=2009 #not going to use pgrep since `pgrep -f` errors
		pids=$(ps -A | grep "$cmd" | grep -v grep | awk '{ print $1; }')
		if [ -n "$pids" ]; then
			for pid in $pids; do
				echo-message "Killing $pid ($cmd)"
				kill "$pid"
			done
		fi
	done
}

is-lein() {
	file-exists 'project.clj'
}

is-java() {
	file-exists 'pom.xml'
}

is-dry() {
	file-exists 'package-dry.json'
}

is-npm() {
	file-exists 'package.json'
}

is-alpine() {
	file-exists '/etc/os-release' && grep -q 'Alpine Linux' '/etc/os-release'
}

lein-docs() {
	echo-message 'Generating API documentation'
	rm -rf docs
	lein-dev codox
	abort-on-error 'creating docs'
}

format-bash() {
	echo-message 'Formatting bash'
	#check shfmt is installed
	shfmt -version >/dev/null
	abort-on-error 'shfmt not installed'
	#only format files tracked by git
	(
		set -euo pipefail
		shfmt -f . | xargs git ls-files -- | xargs shfmt -w
	)
	abort-on-error 'formatting bash'
}

lint-bash() {
	echo-message 'Linting Bash'
	readarray -t files < <(git ls-files '**.sh')
	abort-on-error
	local file
	for file in "${files[@]}"; do
		local script_dir=''
		#shellcheck disable=2016
		if ag --literal 'cd "$(realpath "$(dirname "$0")")"' "$file" >/dev/null; then
			script_dir="$(realpath "$(dirname "$file")")"
			file="$(basename "$file")"
			cd "$script_dir" || exit 1
		fi

		local diff="shellcheck --exclude=2039,2215,2181 --format=diff $file"
		if [ -n "$($diff 2>/dev/null)" ]; then
			$diff | git apply
			abort-on-error "applying git diff for $file"
		fi

		shellcheck --external-sources --exclude=2039,2215,2181 --wiki-link-count=100 "$file"
		abort-on-error "lint failed for $file"
		if [ -n "$script_dir" ]; then
			cd - >/dev/null || exit 1
		fi
	done
}

require-no-focus() {
	if dir-exists test; then
		local focus
		focus=$(ag --literal ' ^:focus ' --file-search-regex '\.clj[cs]?' test/)
		if [ -n "$focus" ]; then
			echo-error 'Focus metadata found:'
			echo "$focus"
			exit 1
		fi
	fi
}

lein-lint() {
	local cmd
	cmd="$1"
	require-var cmd
	if is-lein; then
		copy-to-project '.clj-kondo/config.edn'
		echo-message "Linting Clojure using '$cmd'"
		lein-dev "$cmd"
		require-no-focus
	fi
}

npm-cmd() {
	if is-dry; then
		dry "$@"
	elif is-npm; then
		npm "$@"
	fi
}

local-clean() {
	if ! is-ci && cmd-exists clean; then
		clean
	fi
}

-lint() {
	format-bash &&
		lint-bash &&
		lint-circle-config
	abort-on-error 'linting'
	lein-lint lint || true
	lein-lint lint-test-kondo || true
	if is-ci; then
		require-committed .
	fi
}

-outdated() {
	if is-lein; then
		#shellcheck disable=1010
		lein-dev ancient check :all 2>/dev/null
		trap-exit rm -f pom.xml
		lein-dev pom
	fi
	if is-java; then
		local reporting_output_directory
		echo-message 'Checking for outdated dependencies'
		mvn --update-snapshots --quiet \
			versions:property-updates-report \
			versions:dependency-updates-report \
			versions:plugin-updates-report
		abort-on-error 'error checking for updates'
		reporting_output_directory=$(mvn -q help:evaluate -DforceStdout -Dexpression=project.reporting.outputDirectory)
		abort-on-error "$reporting_output_directory"
		echo-message "Generated reports:"
		find "$reporting_output_directory" -name '*.html'
	fi
	npm-cmd outdated
}

## args: [-l|--local|install] [-d|--develop]
## Creates and deploy a snapshot version.
## Requires commands:
##  -`get-version`
##  -`set-version`
##  -`deploy-snapshot`
## [-l|--local|install] Installs the snapshot to the local repository
## [-d|--develop] Sets the version to "develop" so a `develop-SNAPSHOT` version is created
-snapshot() {
	require-cmd get-version set-version deploy-snapshot
	require-no-snapshot
	local version
	version="$(get-version)"
	abort-on-error "$version"
	require-var version
	local reset_cmd="set-version $version"
	local install
	while [ -n "$1" ]; do
		case "$1" in
		-d | --develop)
			version='develop'
			;;
		-l | --local | install)
			install=1
			;;
		esac
		shift
	done
	local snapshot="$version-SNAPSHOT"
	trap '${reset_cmd}' EXIT
	echo-message "Snapshotting $project_name $version"
	set-version "$snapshot"
	if [ -n "$install" ]; then
		#shellcheck disable=SC2215
		-install
	else
		deploy-snapshot
		abort-on-error 'snapshotting'
		local-clean
	fi
	$reset_cmd
	abort-on-error 'resetting version'
}

-install() {
	echo-message 'Installing'
	if is-lein; then
		lein-install install
	elif is-java; then
		mvn --update-snapshots install
	else
		echo-error "can't install this project"
		exit 1
	fi
	local-clean
}

-release() {
	require-cmd deploy get-version
	local version
	version=$(get-version)
	abort-on-error "$version"
	require-var version
	require-no-snapshot
	echo-message "Releasing $version"
	deploy
	abort-on-error 'deploying'
}

-deps() {
	case $1 in
	-t | --tree | ls)
		echo-message 'Listing dependencies'
		if is-lein; then
			lein -U deps :tree 2>/dev/null
			trap-exit rm -f pom.xml
			lein pom
		fi
		if is-java; then
			mvn --update-snapshots dependency:tree -Dverbose
		fi
		npm-cmd ls "${@:2}"
		;;
	*)
		echo-message 'Installing dependencies'
		if is-lein; then
			allow-snapshots
			trap-exit rm -f pom.xml
			# shellcheck disable=1010
			lein -U do deps, pom
			abort-on-error 'downloading Leiningen dependencies'
		fi
		if is-java; then
			local mvn_threads=5C
			mvn --threads $mvn_threads --update-snapshots dependency:go-offline -Dverbose
			abort-on-error 'downloading Maven dependencies'
			if ! is-ci && [ -z "$JESI_DISABLE_MVN_SOURCE_DOWNLOAD" ]; then
				echo-message 'Downloading sources and JavaDocs'
				for classifier in sources javadoc; do
					mvn --threads $mvn_threads dependency:resolve -Dclassifier=$classifier >/dev/null 2>&1
				done
			fi
		fi
		npm-cmd ci
		abort-on-error 'installing NPM dependencies'
		;;
	esac
}

trim() {
	echo "$@" | xargs
}

-lein-test() {
	allow-snapshots
	local type cmd remaining
	type="$1"
	shift
	while [ -n "$1" ]; do
		case "$1" in
		-r | --refresh | --watch)
			cmd="$cmd --watch"
			;;
		-ff | --fail-fast)
			cmd="$cmd --fail-fast"
			;;
		*)
			remaining="$remaining $1"
			;;
		esac
		shift
	done
	cmd=$(trim "$cmd")
	remaining=$(trim "$remaining")
	if [ -n "$remaining" ]; then
		cmd="$cmd --focus $remaining"
	fi
	export JVM_OPTS="$JVM_OPTS -Duser.timezone=UTC -Duser.language=english"
	lein-test "$type" "$cmd"
}

## args: [-r|--refresh|--watch] [-ff|--fail-fast] <focus>
## Runs the Clojure unit tests using Kaocha
## [-r|--refresh|--watch] Watches tests and source files for changes, and subsequently re-evaluates
## [-ff|--fail-fast] Stop tests as soon as a single failure or error has occurred
## <focus> Suite/namespace/var to focus on
-test-clj() {
	#shellcheck disable=SC2215
	-lein-test clj "$@"
}

js-dev-deps() {
	if ! is-ci; then #CI will have package-lock.json
		local file='package-dry.json'
		if ! file-exists $file; then
			copy-to-project $file
			echo-message 'Installing dev JS dependencies'
			dry install
			abort-on-error 'installing dev JS dependencies'
		fi
	fi
}

## args: [-r|--refresh|--watch] [-n|--node|-b|--browser] <focus>
## Runs the ClojureScript unit tests using Kaocha
## [-r|--refresh|--watch] Watches tests and source files for changes, and subsequently re-evaluates
## [-n|--node] Executes the tests targeting Node.js (default)
## [-b|--browser] Compiles the tests for execution within a browser
## <focus> Suite/namespace/var to focus on
-test-cljs() {
	allow-snapshots
	local type cmd remaining
	type='node'
	while [ -n "$1" ]; do
		case $1 in
		-n | --node)
			type='node'
			;;
		-b | --browser)
			type='browser'
			;;
		-r | --refresh | --watch)
			cmd='--watch'
			;;
		*)
			remaining="$remaining $1"
			;;
		esac
		shift
	done
	if [ -n "$remaining" ]; then
		cmd="$cmd --focus $remaining"
	fi
	lein-test "cljs-$type" "$cmd"
}

## args: [-r|--refresh|--watch] [-k|--karma|-n|--node|-b|--browser]
## Runs the ClojureScript unit tests using shadow-cljs
## [-r|--refresh|--watch] Watches tests and source files for changes, and subsequently re-evaluates
## [-k|--karma] Executes the tests targeting the browser running in karma (default)
## [-n|--node] Executes the tests targeting Node.js
## [-b|--browser] Watches and compiles tests for execution within a browser
-test-shadow-cljs() {
	allow-snapshots
	js-dev-deps
	copy-to-project 'shadow-cljs.edn' 'karma.conf.js'
	local cmd='shadow-cljs'
	local watch
	case $1 in
	-r | --refresh | --watch)
		cmd="$cmd watch"
		watch=1
		shift
		;;
	*)
		cmd="$cmd compile"
		;;
	esac
	case $1 in
	-b | --browser)
		echo-message 'Running browser tests'
		shadow-cljs compile browser "${@:2}"
		abort-on-error 'compiling test'
		shadow-cljs watch browser "${@:2}"
		;;
	-n | --node)
		echo-message 'Running Node.js tests'
		$cmd node "${@:2}"
		;;
	*)
		echo-message 'Running Karma tests'
		if [ -n "$watch" ]; then
			shadow-cljs compile karma "${@:2}"
			abort-on-error 'compiling test'
			npx karma start --no-single-run --browsers=JesiChromiumHeadless &
			shadow-cljs watch karma "${@:2}"
		else
			shadow-cljs compile karma "${@:2}"
			abort-on-error 'compiling test'
			npx karma start --single-run --browsers=JesiChromiumHeadless
		fi
		;;
	esac
}

declare -a _trapped_exit_fns=()
_run-exit-traps() {
	for cmd in "${_trapped_exit_fns[@]}"; do
		$cmd
	done
}

# Registers a function to be called on script exit
# Usage:
# trap-exit echo-message 'Function exited'
# trap-exit db-disconnect "$env"
trap-exit() {
	local command_to_run
	# shellcheck disable=SC2124
	command_to_run="$@"
	if [ -n "$command_to_run" ]; then
		_trapped_exit_fns+=("$command_to_run")
	fi
}

if [ -z "$(trap -p EXIT)" ]; then
	trap _run-exit-traps EXIT
else
	echo-message "WARNING: EXIT Trap is already defined. Please use 'trap-exit'"
fi
