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

install: build-release
    install -d {{PREFIX}}/bin
    install bin/krikri-playbook {{PREFIX}}/bin/krikri-playbook
    install bin/krikri {{PREFIX}}/bin/krikri
    cp -a bin/plugins {{PREFIX}}/bin/plugins

uninstall:
    rm -f {{PREFIX}}/bin/krikri-playbook {{PREFIX}}/bin/krikri
    rm -rf {{PREFIX}}/bin/plugins
