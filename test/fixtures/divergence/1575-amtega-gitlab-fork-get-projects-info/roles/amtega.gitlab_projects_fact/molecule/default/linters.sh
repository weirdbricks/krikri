#!/usr/bin/env bash

set -euo pipefail

export ANSIBLE_ACTION_PLUGINS=$PWD/action_plugins
export ANSIBLE_BECOME_PLUGINS=$PWD/become_plugins
export ANSIBLE_CACHE_PLUGINS=$PWD/cache_plugins
export ANSIBLE_CALLBACK_PLUGINS=$PWD/callback_plugins
export ANSIBLE_CLICONF_PLUGINS=$PWD/cliconf_plugins
export ANSIBLE_CONNECTION_PLUGINS=$PWD/connection_plugins
export ANSIBLE_DOC_FRAGMENT_PLUGINS=$PWD/doc_fragment_plugins
export ANSIBLE_FILTER_PLUGINS=$PWD/filter_plugins
export ANSIBLE_HTTPAPI_PLUGINS=$PWD/httpapi_plugins
export ANSIBLE_INVENTORY_PLUGINS=$PWD/inventory_plugins
export ANSIBLE_LIBRARY=$PWD/library
export ANSIBLE_LOOKUP_PLUGINS=$PWD/lookup_plugins
export ANSIBLE_NETCONF_PLUGINS=$PWD/netconf_plugins
export ANSIBLE_ROLES_PATH=$MOLECULE_EPHEMERAL_DIRECTORY/roles
export ANSIBLE_STRATEGY_PLUGINS=$PWD/strategy_plugins
export ANSIBLE_TERMINAL_PLUGINS=$PWD/terminal_plugins
export ANSIBLE_TEST_PLUGINS=$PWD/test_plugins
export ANSIBLE_VARS_PLUGINS=$PWD/vars_plugins

yamllint .
ansible-lint
flake8
