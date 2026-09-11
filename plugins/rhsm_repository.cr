#!/usr/bin/env crystal
# community.general.rhsm_repository - manages RHSM repository enable/disable
# state via `subscription-manager repos`. Ported from community.general's
# rhsm_repository module (round 310195: zaxos.docker-ce-ansible-role runs it
# on RHEL-only tasks; previously unavailable -> rc=4 "unavailable modules"
# where real ansible-playbook ran the whole role cleanly, ok=8 changed=5).
#
# Supported here: name (single ID, comma-separated list, or YAML list; glob
# patterns like `rhel-6-server*` work, exact fnmatch semantics), state
# (enabled/disabled, plus the pre-10.0 present/absent spellings mapped onto
# them - the collection version real controllers still install accepts
# those), purge (bool, default false).
#
# Idempotency: parse `subscription-manager repos --list` (LANGUAGE=C forced,
# like the real module's environ update), compare each requested repo's
# current enabled state, and pass exactly one --enable/--disable per repo
# that actually needs flipping - matching the real module's single
# `repos` invocation with collected arguments.
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/rhsm_repository"

module Krikri
  class RhsmRepositoryPlugin < BasePlugin
    def execute : PluginResult
      names = parse_names
      if names.empty?
        return PluginResult.new(changed: false, failed: true,
          msg: "missing required argument: name")
      end

      state = normalize_state(@params["state"]? || "enabled")
      unless state
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: enabled, disabled, present, absent, got #{@params["state"]?}")
      end
      purge = true?(@params["purge"]?)

      listing = remote_exec("export LANGUAGE=C LC_ALL=C; subscription-manager repos --list")
      if listing[:exit_code] != 0
        return PluginResult.new(changed: false, failed: true,
          msg: "subscription-manager failed with the following error: #{listing[:stderr]}")
      end
      if listing[:stdout].includes?("This system has no repositories available through subscriptions.")
        return PluginResult.new(changed: false, failed: true,
          msg: "This system has no repositories available through subscriptions")
      end

      repos = PluginHelpers::RhsmRepository.parse_list(listing[:stdout])
      plan = PluginHelpers::RhsmRepository.plan(repos, names, state, purge)
      if pattern = plan.invalid_pattern
        return PluginResult.new(changed: false, failed: true,
          msg: "#{pattern} is not a valid repository ID")
      end

      args = plan.enable.map { |id| "--enable #{id}" } + plan.disable.map { |id| "--disable #{id}" }
      if args.empty?
        return PluginResult.new(changed: false, failed: false,
          msg: "Repository states unchanged", repositories: repositories_json(plan.updated))
      end

      result = remote_exec("export LANGUAGE=C LC_ALL=C; subscription-manager repos #{args.join(" ")}")
      return PluginResult.new(changed: false, failed: true,
        msg: "subscription-manager failed with the following error: #{result[:stderr]}") if result[:exit_code] != 0

      PluginResult.new(changed: true, failed: false,
        msg: "Repositories changed: #{args.size}", repositories: repositories_json(plan.updated))
    end

    private def parse_names : Array(String)
      raw = @params["name"]?
      return [] of String unless raw

      begin
        parsed = JSON.parse(raw)
        return parsed.as_a.map(&.as_s) if parsed.as_a?
        return [parsed.as_s] if parsed.as_s? && !parsed.as_s.empty?
      rescue
      end

      return [] of String if raw.empty?
      raw.includes?(",") ? raw.split(",").map(&.strip).reject(&.empty?) : [raw.strip]
    end

    private def normalize_state(value : String) : String?
      case value
      when "enabled", "present" then "enabled"
      when "disabled", "absent" then "disabled"
      end
    end

    private def repositories_json(repos : Array(PluginHelpers::RhsmRepository::Repo)) : JSON::Any
      entries = repos.map do |repo|
        JSON::Any.new({
          "id"      => JSON::Any.new(repo.id),
          "name"    => JSON::Any.new(repo.name),
          "url"     => JSON::Any.new(repo.url),
          "enabled" => JSON::Any.new(repo.enabled),
        })
      end
      JSON::Any.new(entries)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::RhsmRepositoryPlugin.new(config)
plugin.run
