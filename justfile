# krikri - developer task runner
# `just` with no arguments lists all recipes.

PREFIX := env_var_or_default('PREFIX', '/usr/local')

default:
    @just --list

deps:
    shards install

build-dev:
    ./build.sh

build-release:
    ./build.sh --release

test:
    crystal spec

lint:
    lib/ameba/bin/ameba

format:
    crystal tool format

format-check:
    crystal tool format --check

clean:
    rm -rf bin
    rm -f plugins/.fat_plugin_generated.cr

ci: deps build-dev test lint format-check

# Runs BEFORE build-release so a permissions problem is caught up front,
# not after paying for a full release build - `install` failing at
# `install -d {{PREFIX}}/bin` used to waste the whole build.
check-install-perms:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "$(id -u)" -eq 0 ]; then
        exit 0
    fi
    # {{PREFIX}}/bin may not exist yet - walk up to the nearest existing
    # ancestor (what `install -d`/`mkdir -p` would actually need to write
    # into) rather than only checking {{PREFIX}}/bin and {{PREFIX}} themselves.
    dir="{{PREFIX}}/bin"
    while [ ! -e "$dir" ]; do
        dir="$(dirname "$dir")"
    done
    if [ -w "$dir" ]; then
        exit 0
    fi
    echo "Installing to {{PREFIX}} requires administrator privileges."
    read -rp "Continue and use sudo for the install step? [y/N] " reply
    case "$reply" in
        [Yy]*) exit 0 ;;
        *)
            echo "Aborted. Re-run with a writable PREFIX instead, e.g.:" >&2
            echo "  PREFIX=\$HOME/.local just install" >&2
            exit 1
            ;;
    esac

install: check-install-perms build-release
    #!/usr/bin/env bash
    set -euo pipefail
    dir="{{PREFIX}}/bin"
    while [ ! -e "$dir" ]; do
        dir="$(dirname "$dir")"
    done
    if [ -w "$dir" ] || [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    else
        SUDO="sudo"
    fi
    $SUDO install -d {{PREFIX}}/bin
    $SUDO install bin/krikri-playbook {{PREFIX}}/bin/krikri-playbook
    $SUDO install bin/krikri {{PREFIX}}/bin/krikri
    $SUDO install bin/krikri-lint {{PREFIX}}/bin/krikri-lint
    $SUDO rm -rf {{PREFIX}}/bin/plugins
    $SUDO cp -a bin/plugins {{PREFIX}}/bin/plugins

uninstall:
    rm -f {{PREFIX}}/bin/krikri-playbook {{PREFIX}}/bin/krikri {{PREFIX}}/bin/krikri-lint
    rm -rf {{PREFIX}}/bin/plugins
