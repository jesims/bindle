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
	#shellcheck disable=2181
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

require-file () {
	local file=$1
	if ! file-exists "$file";then
		echo-error "File not found: $file"
		exit 1
	fi
}

require-file-not-empty () {
	local file=$1
	require-var file
	require-file "$file"
	if [ "$(wc -c < "$file")" -eq 0 ];then
		echo-error "file is empty $file"
		exit 1
	fi
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
	elif (grep -q "^$1\ (" "$script_name");then
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
	lein with-profile +dev "$@"
}

lein-install () {
	lein with-profile +install "$@"
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

lein-clean () {
	echo-message 'Cleaning'
	rm tests.edn
	lein clean
	abort-on-error 'cleaning'
}

script-dir () {
	realpath "$(dirname "${BASH_SOURCE[0]}")"
}

copy-to-project () {
	for file in "$@";do
		if ! file-exists "$file";then
			local script_dir
			script_dir=$(script-dir)
			abort-on-error "$script_dir"
			cp "$script_dir/$file" .
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
	for file in "${files[@]}";do
		local sc='shellcheck --external-sources --exclude=2039,2215,2181'

		local script_dir
		#shellcheck disable=2016
		if ag --literal 'cd "$(realpath "$(dirname "$0")")"' "$file" >/dev/null;then
			script_dir=$(realpath "$(dirname "$file")")
			file=$(basename "$file")
			cd "$script_dir" || exit 1
		fi

		local diff="$sc --format=diff $file"
		if [ -n "$($diff)" ];then
			$diff | git apply
		fi

		local failed=0
		echo-message "Linting $file"
		$sc "$file"
		abort-on-error "lint failed for $file"
		if [ -n "$script_dir" ];then
			cd - >/dev/null || exit 1
		fi
	done
}

lein-lint () {
	if is-lein;then
		echo-message 'Linting Clojure'
		local focus
		focus=$(ag --literal ' ^:focus ' --file-search-regex '\.clj[cs]?' test/)
		if [ -n "$focus" ];then
			echo-error 'Focus metadata found:'
			echo "$focus"
			exit 1
		fi
		# shellcheck disable=1010
		lein-dev do check, lint
	fi
}

npm-cmd () {
	if is-npm;then
		npm "$@"
	elif is-dry;then
		dry "$@"
	fi
}

-lint () {
	lein-lint &&
	lint-circle-config &&
	format-markdown &&
	lint-bash
	abort-on-error 'linting'
	if is-ci;then
		require-committed .
	fi
}

-outdated () {
	if is-lein;then
		lein-dev ancient check :all 2>/dev/null &&
		lein-dev pom
	fi
	if is-java;then
		mvn versions:display-dependency-updates &&
		mvn versions:display-plugin-updates
	fi
	npm-cmd oudated
}

-snapshot () {
	require-no-snapshot
	local version
	version="$(get-version)"
	abort-on-error "$version"
	require-var version
	local snapshot="$version-SNAPSHOT"
	local reset_cmd="set-version $version"
	trap '${reset_cmd}' EXIT
	echo-message "Snapshotting $snapshot"
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
	if ! is-ci && cmd-exists clean;then
		clean
	fi
}

-release () {
	require-cmd deploy
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
				lein deps :tree 2>/dev/null
			elif is-java;then
				mvn dependency:tree -Dverbose
			fi
			npm-cmd ls "${@:2}"
			;;
		*)
			echo-message 'Installing dependencies'
			if is-lein;then
				allow-snapshots
				# shellcheck disable=1010
				lein do -U deps, pom
				abort-on-error
			fi
			if is-java;then
				mvn --update-snapshots dependency:go-offline -Dverbose
				abort-on-error
			fi
			local cmd
			if [ -n "$cmd" ];then
				if is-ci;then
					cmd='ci'
				else
					cmd='install'
				fi
				npm-cmd $cmd
				abort-on-error
			fi
			;;
	esac
}

-test-clj () {
	allow-snapshots
	case $1 in
		-r)
			lein-test --watch clj "${@:2}";;
		*)
			lein-test clj "$@";;
	esac
}

-test-cljs () {
	allow-snapshots
	case $1 in
		-b)
			lein-test cljs-browser "${@:2}";;
		-r)
			lein-test --watch cljs-node "${@:2}";;
		*)
			lein-test cljs-node "$@";;
	esac
}
