#!/usr/bin/env crystal

# krikri - ad-hoc CLI (equivalent of `ansible`)
#
# The `ansible` counterpart to krikri-playbook.cr's `ansible-playbook`
# reimplementation: runs exactly ONE module against a pattern of
# inventory hosts, matching ansible-core's own `ansible <pattern>
# -m <module> -a <args>` ad-hoc surface - a separate binary, not a
# krikri-playbook subcommand, for the same reason Ansible ships
# `ansible` and `ansible-playbook` as two distinct executables rather
# than folding ad-hoc mode into ansible-playbook's own CLI. Reuses the
# exact same TaskExecutor/PluginManager/InventoryParser machinery as
# the playbook engine (connection handling, become, check mode, forks,
# facts) - only the CLI surface and result-display format differ, via
# TaskExecutor's `adhoc: true` flag (see task_executor/executor.cr and
# task_executor/result_display.cr's display_adhoc_result).
#
# The option surface mirrors `Ansible`'s own --help (verified
# against ansible-core 2.19.4): playbook-only flags (tags, --syntax-check,
# --list-tasks, ...) are deliberately absent, while everything real
# ad-hoc mode accepts is accepted here. Where krikri-playbook.cr
# implements an equivalent flag, the exact same wiring is reused
# (CliOptions for the ssh-invocation flags, host vars for the
# "set this connection variable for every host" flags, VaultCli for the
# password prompts, Vault for the vault sources).

# Same Crystal 1.22 broken-pipe stdio fix as krikri-playbook.cr.
require "./src/krikri/stdio_pipe_guard"

require "option_parser"
require "colorize"
require "./src/krikri/version"
require "./src/krikri/yaml_bigint"
require "./src/krikri/unsafe_values"
require "./src/krikri/playbook_parser"
require "./src/krikri/inventory_parser"
require "./src/krikri/cli_options"
require "./src/krikri/extra_vars_parser"
require "./src/krikri/vault"
require "./src/krikri/vault_cli"
require "./src/krikri/task_executor"
require "./src/krikri/adhoc_cli"

Krikri::AdhocCli.run
