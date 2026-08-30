#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Debconf plugin - pre-seeds/reads a package's debconf database
  # entries. Compatible with Ansible's ansible.builtin.debconf module.
  #
  # Shells to the real `debconf-set-selections`/`debconf-show`/
  # `debconf-get-selections` binaries, mirroring real Ansible's own
  # module exactly (it does the same - no python-apt/libdebconf binding
  # either). apt-only; these binaries don't exist on RHEL-family hosts.
  #
  # Not implemented: `vtype: password`'s own idempotency read-back
  # (`get_password_value`, parsing `debconf-get-selections`'s raw tab-
  # separated dump for a password-typed question) - real Ansible's own
  # docs recommend `no_log: true` for password questions precisely
  # because the value is sensitive, and this is a narrow, rarely-hit
  # shape; a `vtype: password` task here always re-applies (`changed:
  # true` every run) rather than silently under-reporting drift.
  class DebconfPlugin < BasePlugin
    def execute : PluginResult
      pkg = @params["name"]? || @params["pkg"]?
      return missing_param("name") unless pkg

      question = debconf_question
      vtype = @params["vtype"]?
      value = debconf_value
      unseen = true?(@params["unseen"]?)
      check_mode = true?(@params["check_mode"]?)

      if question.nil?
        return PluginResult.new(changed: false, failed: false, msg: "No question given, nothing to set")
      end

      if vtype.nil? || value.nil?
        return PluginResult.new(changed: false, failed: true, msg: "when supplying a question you must supply a valid vtype and value")
      end

      prev = get_selections(pkg)
      changed = value_differs?(prev, question, vtype, value)

      if changed && !check_mode
        result = set_selection(pkg, question, vtype, value, unseen)
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: result[:stderr])
        end
      end

      PluginResult.new(changed: changed, failed: false, msg: changed ? "Value set" : "Value already set")
    end

    # question:/selection:/setting: are documented aliases of each other
    private def debconf_question : String?
      @params["question"]? || @params["selection"]? || @params["setting"]?
    end

    # value:/answer: are documented aliases of each other
    private def debconf_value : String?
      @params["value"]? || @params["answer"]?
    end

    # Does the stored selection differ from the requested value?
    # Boolean questions are compared case-insensitively (debconf stores
    # booleans lowercased; real Ansible's module normalizes the same way)
    private def value_differs?(prev : Hash(String, String), question : String, vtype : String, value : String) : Bool
      compare_value = vtype == "boolean" ? value.downcase : value
      existing = prev[question]?
      existing = existing.try { |e| vtype == "boolean" ? e.downcase : e }

      existing != compare_value
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end

    # `debconf-show <pkg>` prints one `[*] question: value` line per
    # known question (`*` marks it "seen") - strip the leading `*`/
    # whitespace off the key, same as real Ansible's own `get_selections`.
    private def get_selections(pkg : String) : Hash(String, String)
      result = remote_exec("debconf-show #{pkg} 2>/dev/null")
      selections = Hash(String, String).new
      result[:stdout].each_line do |line|
        key, sep, val = line.partition(':')
        next if sep.empty?
        selections[key.strip('*').strip] = val.strip
      end
      selections
    end

    private def set_selection(pkg : String, question : String, vtype : String, value : String, unseen : Bool) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      flag = unseen ? "-u " : ""
      data = "#{pkg} #{question} #{vtype} #{value}"
      remote_exec("echo #{shell_single_quote(data)} | debconf-set-selections #{flag}".strip)
    end

    private def shell_single_quote(str : String) : String
      "'" + str.gsub("'", "'\\\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DebconfPlugin.new(config)
plugin.run
