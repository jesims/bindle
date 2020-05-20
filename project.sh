#n @IgnoreInspection BashAddShebang
# shellcheck shell=bash disable=2034

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
githooks_folder='githooks'
script_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

is-ci () {
	[ -n "$CIRCLECI" ]
}

echo-message () {
	echo "${bldgrn}[$script_name]${txtrst} ${FUNCNAME[1]}: ${grn}$*${txtrst}"
}

if ! is-ci && [ -d "$githooks_folder" ] && [ "$(git config core.hooksPath)" != "$githooks_folder" ];then
	echo-message 'Setting up GitHooks'
	git config core.hooksPath "$githooks_folder"
	chmod u+x ${githooks_folder}/*
fi

echo-red () {
	echo "${bldred}[$script_name]${txtrst} ${FUNCNAME[1]}: ${red}$*${txtrst}"
}

echo-error () {
	echo-red "ERROR: $*"
}

abort-on-error () {
	if [ $? -ne 0 ]; then
		echo-error "$@"
		exit 1
	fi
}

var-set () {
	local val
	val=$(eval "echo \$$1")
	[ -n "$val" ]
}

require-var () {
	local var
	for var in "$@";do
		if ! var-set "$var";then
			echo-error "$var not defined"
			exit 1
		fi
	done
}

cmd-exists () {
	hash "$1" 2>/dev/null
}

require-cmd () {
	local cmd
	for cmd in "$@";do
		if ! cmd-exists "$cmd" ;then
			echo-error "$cmd not installed"
			exit 1
		fi
	done
}

file-exists () {
	[ -r "$1" ]
}

dir-exists () {
	[ -d "$1" ]
}

require-file () {
	local file
	for file in "$@";do
		if ! file-exists "$file";then
			echo-error "File not found: $file"
			exit 1
		fi
	done
}

require-file-not-empty () {
	local file
	for file in "$@";do
		require-file "$file"
		if [ ! -s "$file" ];then
			echo-error "file is empty $file"
			exit 1
		fi
	done
}

require-committed () {
	local file=$1
	if file-exists "$file";then
		git diff --quiet --exit-code "$file"
		abort-on-error "uncommitted changes in $file"
	fi
}

usage () {
	doc=$(grep '^##' "${script_name}" | sed -e 's/^##//')
	desc=''
	synopsis=''
	while read -r line; do
		if [[ "$line" == *: ]];then
			fun=${line::-1}
			synopsis+="\n\t${script_name} ${txtbld}${fun}${txtrst}"
			desc+="\n\t${txtbld}$fun${txtrst}"
		elif [[ "$line" == args:* ]];then
			args="$( cut -d ':' -f 2- <<< "$line" )"
			synopsis+="$args"
		elif [[ "$line" =~ ^(<[{)* ]];then
			desc+="\n\t\t\t${line}"
		else
			desc+="\n\t\t${line}"
		fi
	done <<< "$doc"
	echo -e "${txtbld}SYNOPSIS${txtrst}${synopsis}\n\n${txtbld}DESCRIPTION${txtrst}${desc}"
}

script-invoke () {
	if [ "$#" -eq 0 ];then
		usage
		exit 1
	elif [[ "$1" =~ ^(help|-h|--help)$ ]];then
		usage
		exit 0
	elif (grep -qE -e "^$1[\\t ]*?\\([\\t ]*?\\)" "$script_name");then
		"$@"
	else
		echo-error "Unknown function $1 ($script_name $*)"
		exit 1
	fi
}

confirm () {
	local msg=$1
	local expected=$2
	read -r -p "$msg ($expected): " response
	if [ "$response" != "$expected" ];then
		echo-message 'Aborted'
		exit 0
	fi
}

pause () {
	read -r -n1 -p 'Press any key to continue...'
}

get-version () {
	local file=VERSION
	require-file "$file"
	cat "$file"
}

set-version () {
	echo "$1" > VERSION
}

is-snapshot () {
	[[ "$(get-version)" == *SNAPSHOT ]]
}

lein-dev () {
	local profile='+dev'
	if [ -n "$LEIN_DEV_PROFILE" ];then
		profile="$profile,$LEIN_DEV_PROFILE"
	fi
	lein -U with-profile "$profile" "$@"
}

lein-install () {
	lein with-profile +install,-dev "$@"
}

lein-jar(){
	echo-message 'Building'
	allow-snapshots
	lein with-profile -dev jar "$@"
	abort-on-error 'building'
}

lein-uberjar(){
	echo-message 'Building'
	allow-snapshots
	lein with-profile -dev uberjar "$@"
	abort-on-error 'building'
}

deploy-clojars () {
	echo-message "Deploying $(get-version) to Clojars"
	if is-ci;then
		lein-install deploy clojars &>/dev/null
	else
		lein-install deploy clojars
	fi
	abort-on-error
}

deps-ci () {
	if is-ci;then
		# shellcheck disable=2215
		-deps "$@"
	fi
}

lein-test () {
	deps-ci "$@"
	local test_cmd="lein-dev test $*"
	echo-message "Running test $*"
	copy-to-project 'tests.edn'
	$test_cmd
	abort-on-error 'running tests'
}

shadow-cljs () {
	lein-dev shadow-cljs "$@"
}

lein-clean () {
	echo-message 'Cleaning'
	lein clean
	abort-on-error 'cleaning'
}

copy-to-project () {
	local file_path
	for file_path in "$@";do
		if ! file-exists "$file_path";then
			local dir
			dir=$(dirname "$file_path")
			abort-on-error "$dir"
			if [ -n "$dir" ];then
				mkdir -p "$dir"
			fi
			cp -r "$script_dir/template/$file_path" "$file_path"
			abort-on-error 'copying file to project'
		fi
	done
}

format-markdown () {
	copy-to-project '.remarkrc.js'
	echo-message 'Formatting Markdown'
	remark . --output
	abort-on-error 'running remark'
}

lint-circle-config () {
	local file='.circleci/config.yml'
	if file-exists "$file";then
		if is-ci;then
			require-committed .circleci
		else
			echo-message "Checking $file"
			circleci config validate
			abort-on-error 'validating CircleCI'
		fi
	fi
}

checksum () {
	local file="$1"
	file=$(file-exists "$file" && cat "$file")
	echo "$file" | cksum | awk '{print $1}'
}

checksum-different () {
	local target="$1.cksum"
	[ "$(file-exists "$target" && cat "$target")" != "$(checksum "$1")" ]
}

on-files-changed () {
	local cmd=$1
	local files=${*:2}
	local changed=0
	local file
	for file in $files;do
		if ! file-exists "$file" || checksum-different "$file";then
			changed=1
			break
		fi
	done
	if [ $changed -eq 1 ];then
		$cmd
		for file in $files;do
			checksum "$file" > "${file}.cksum"
		done
	fi
}

branch-name () {
	git rev-parse --abbrev-ref HEAD
}

wait-for () {
	local name=$1
	local timeout=$2
	local test_commands="${*:3}"
	require-var name timeout test_commands
	timeout="$(("$(date +%s)" + "$timeout"))"
	until $test_commands;do
		if [ "$(date +%s)" -le "$timeout" ];then
			echo-message "Waiting for $name"
			sleep 1
		else
			echo-error 'Timeout'
			exit 1
		fi
	done
}

allow-snapshots () {
	if [ "$(branch-name)" != "master" ];then
		echo-message "Allowing SNAPSHOT dependencies"
		export LEIN_SNAPSHOTS_IN_RELEASE=1
	fi
}

require-no-snapshot-use () {
	local project_file=$1
	allow-snapshots
	if [ -z "$LEIN_SNAPSHOTS_IN_RELEASE" ];then
		local matches
		matches=$(grep "\-SNAPSHOT" "$project_file")
		if [ -n "$matches" ];then
			echo-error "SNAPSHOT dependencies found in $project_file."
			echo-error "$matches"
			exit 1
		fi
	fi
}

require-no-snapshot () {
	if is-snapshot;then
		echo-error 'SNAPSHOT suffix already defined'
		exit 1
	fi
}

just-die () {
	local pid
	local cmd
	for cmd in "$@";do
		pid=$(ps -A | ag --only-matching --nocolor "^\s*?\d+(?=\s.*\Q$cmd\E.*$)(?!\s.*\Qgrep\E.*$)")
		if [ -n "$pid" ];then
			echo-message "Killing $pid ($cmd)"
			kill "$pid"
		fi
	done
}

is-lein () {
	file-exists 'project.clj'
}

is-java () {
	file-exists 'pom.xml'
}

is-dry () {
	file-exists 'package-dry.json'
}

is-npm () {
	file-exists 'package.json'
}

lein-docs () {
	echo-message 'Generating API documentation'
	rm -rf docs
	lein-dev codox
	abort-on-error 'creating docs'
}

lint-bash () {
	echo-message 'Linting Bash'
	readarray -t files < <(git ls-files '**.sh')
	abort-on-error
	local file
	for file in "${files[@]}";do
		local sc='shellcheck --external-sources --exclude=2039,2215,2181 --wiki-link-count=100'

		local script_dir=''
		#shellcheck disable=2016
		if ag --literal 'cd "$(realpath "$(dirname "$0")")"' "$file" >/dev/null;then
			script_dir=$(realpath "$(dirname "$file")")
			file=$(basename "$file")
			cd "$script_dir" || exit 1
		fi

		local diff="$sc --format=diff $file"
		if [ -n "$($diff 2>/dev/null)" ];then
			$diff | git apply
			abort-on-error "applying git diff for $file"
		fi

		local failed=0
		$sc "$file"
		abort-on-error "lint failed for $file"
		if [ -n "$script_dir" ];then
			cd - >/dev/null || exit 1
		fi
	done
}

require-no-focus () {
	local focus
	focus=$(ag --literal ' ^:focus ' --file-search-regex '\.clj[cs]?' test/)
	if [ -n "$focus" ];then
		echo-error 'Focus metadata found:'
		echo "$focus"
		exit 1
	fi
}

lein-lint () {
	if is-lein;then
		require-no-focus
		copy-to-project '.clj-kondo/config.edn'
		echo-message 'Linting Clojure'
		lein-dev lint
	fi
}

npm-cmd () {
	if is-npm;then
		npm "$@"
	elif is-dry;then
		dry "$@"
	fi
}

local-clean(){
	if ! is-ci && cmd-exists clean;then
		clean
	fi
}

-lint () {
	format-markdown &&
	lint-bash &&
	lint-circle-config
	abort-on-error 'linting'
	lein-lint || true
	if is-ci;then
		require-committed .
	fi
}

-outdated () {
	if is-lein;then
		#shellcheck disable=1010
		lein-dev ancient check :all 2>/dev/null
		lein-dev pom
	fi
	if is-java;then
		mvn versions:display-dependency-updates &&
		mvn versions:display-plugin-updates
	fi
	npm-cmd outdated
}

-snapshot () {
	require-no-snapshot
	require-cmd get-version set-version
	local version
	version="$(get-version)"
	abort-on-error "$version"
	require-var version
	local snapshot="$version-SNAPSHOT"
	local reset_cmd="set-version $version"
	trap '${reset_cmd}' EXIT
	echo-message "Snapshotting $project_name $snapshot"
	set-version "$snapshot"
	case $1 in
		-l|--local)
			allow-snapshots
			lein-install install
			abort-on-error 'installing';;
		*)
			require-cmd deploy-snapshot
			deploy-snapshot
			abort-on-error 'deploying';;
	esac
	abort-on-error 'snapshotting'
	$reset_cmd
	abort-on-error 'resetting version'
	local-clean
}

-install () {
	if is-lein;then
		lein-install install
	fi
	local-clean
}

-release () {
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

-deps () {
	case  $1 in
		-t|--tree|ls)
			echo-message 'Listing dependencies'
			if is-lein;then
				lein -U deps :tree 2>/dev/null
				lein pom
			fi
			if is-java;then
				mvn dependency:tree -Dverbose
				if ! is-ci;then
					mvn dependency:sources 2>/dev/null
					mvn dependency:resolve -Dclassifier=javadoc 2>/dev/null
				fi
			fi
			npm-cmd ls "${@:2}"
			;;
		*)
			echo-message 'Installing dependencies'
			if is-lein;then
				allow-snapshots
				# shellcheck disable=1010
				lein -U do deps, pom
				abort-on-error
			fi
			if is-java;then
				mvn --update-snapshots dependency:go-offline -Dverbose
				abort-on-error
			fi
			local cmd=''
			if is-ci;then
				cmd='ci'
			else
				cmd='install'
			fi
			npm-cmd $cmd
			abort-on-error
			;;
	esac
}

trim(){
	echo "$@" | xargs
}

## args: [-r|--refresh|--watch] [-ff|--fail-fast] <focus>
## Runs the Clojure unit tests using Kaocha
## [-r|--refresh|--watch] Watches tests and source files for changes, and subsequently re-evaluates
## [-ff|--fail-fast] Stop tests as soon as a single failure or error has occurred
## <focus> Suite/namespace/var to focus on
-test-clj () {
	allow-snapshots
	local cmd
	local remaining
	while [ -n "$1" ];do
		case "$1" in
			-r|--refresh|--watch)
				cmd="$cmd --watch";;
			-ff|--fail-fast)
				cmd="$cmd --fail-fast";;
			*)
				remaining="$remaining $1";;
		esac
		shift
	done
	cmd=$(trim "$cmd")
	remaining=$(trim "$remaining")
	if [ -n "$remaining" ];then
		cmd="$cmd --focus $remaining"
	fi
	export JVM_OPTS="$JVM_OPTS -Duser.timezone=UTC"
	lein-test clj "$cmd"
}

js-dev-deps(){
	if ! is-ci;then #CI will have package-lock.json
		local file='package-dry.json'
		if ! file-exists $file;then
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
-test-cljs () {
	allow-snapshots
	local cmd
	case $1 in
		-r|--refresh|--watch)
			cmd='--watch'
			shift;;
	esac
	if [ -n "$1" ];then
		cmd="$cmd --focus $*"
	fi
	case $1 in
		-b|--browser)
			lein-test cljs-browser "$cmd";;
		*)
			lein-test cljs-node "$cmd";;
	esac
}

## args: [-r|--refresh|--watch] [-k|--karma|-n|--node|-b|--browser]
## Runs the ClojureScript unit tests using shadow-cljs
## [-r|--refresh|--watch] Watches tests and source files for changes, and subsequently re-evaluates
## [-k|--karma] Executes the tests targeting the browser running in karma (default)
## [-n|--node] Executes the tests targeting Node.js
## [-b|--browser] Watches and compiles tests for execution within a browser
-test-shadow-cljs () {
	allow-snapshots
	js-dev-deps
	copy-to-project 'shadow-cljs.edn' 'karma.conf.js'
	local cmd='shadow-cljs'
	local watch
	case $1 in
		-r|--refresh|--watch)
			cmd="$cmd watch"
			watch=1
			shift;;
		*)
			cmd="$cmd compile";;
	esac
	case $1 in
		-b|--browser)
			echo-message 'Running browser tests'
			shadow-cljs compile browser "${@:2}"
			abort-on-error 'compiling test'
			shadow-cljs watch browser "${@:2}";;
		-n|--node)
			echo-message 'Running Node.js tests'
			$cmd node "${@:2}";;
		*)
			echo-message 'Running Karma tests'
			if [ -n "$watch" ];then
				shadow-cljs compile karma "${@:2}"
				abort-on-error 'compiling test'
				npx karma start --no-single-run --browsers=JesiChromiumHeadless &
				shadow-cljs watch karma "${@:2}"
			else
				shadow-cljs compile karma "${@:2}"
				abort-on-error 'compiling test'
				npx karma start --single-run --browsers=JesiChromiumHeadless
			fi;;
	esac
}
