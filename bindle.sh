#!/usr/bin/env bash
# shellcheck disable=2215,2181
cd "$(realpath "$(dirname "$0")")" &&
	source project.sh
if [ $? -ne 0 ]; then
	exit 1
fi

## lint:
## lints and formats project files
lint() {
	-lint
}

script-invoke "$@"
