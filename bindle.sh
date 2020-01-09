#!/usr/bin/env bash
# shellcheck disable=2215
cd "$(realpath "$(dirname "$0")")" || exit 1
if ! source project.sh;then
	exit 1
fi

## lint:
## lints and formats project files
lint () {
	-lint
}

script-invoke "$@"
