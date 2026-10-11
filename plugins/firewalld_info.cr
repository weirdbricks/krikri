#!/usr/bin/env crystal

require "json"
require "file_utils"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/python_lib_gate"

module Krikri
  # Firewalld info plugin - gathers firewalld zone state. Compatible with
  # Ansible's ansible.posix.firewalld_info module.
  #
  # Found by the deekayen.ping round (5460373): the module didn't exist
  # here at all, so the "Read the firewalld zone settings" task hit the
  # unavailable-module skip and its registered result carried no
  # `firewalld_info` key - the later firewalld task's
  # `ping_firewalld_info.firewalld_info.zones[zone].icmp_block_inversion`
  # lookup then died with "object of type 'dict' has no attribute
  # 'firewalld_info'" while ansible-playbook ran the same role clean.
  #
  # Backend: the real module is a thin D-Bus client - it imports
  # python-dbus + python-firewall and calls FirewallClient's
  # getZoneSettings/getZones/getDefaultZone getters, nothing else. This
  # plugin runs the same client calls through the target's own python
  # (the same imports, the same types the module's exit_json serializes:
  # ports/forward_ports/source_ports as [port, proto(, toport, toaddr)]
  # pair lists, icmp_block_inversion/masquerade/forward as real bools),
  # instead of re-deriving all of that from `firewall-cmd --info-zone`
  # text parsing. Live-verified shape against ansible.posix.firewalld_info
  # under ansible-core 2.20.7 in a firewalld 2.4.4 container.
  #
  # Failure/interpreter behavior mirrors the module's main():
  # - python-dbus import gate first, python-firewall second (the module's
  #   own two fail_json checks, in that order), each with Ansible's
  #   missing_required_lib message via the shared python_lib_gate.
  # - when BOTH are missing under the discovered interpreter, the module
  #   respawns itself under ansible.posix's SYSTEM_PYTHON_INTERPRETERS
  #   (probing `import firewall` only) and re-runs there - reproduced,
  #   including the case where the respawned interpreter still lacks
  #   dbus (python-dbus failure wins there too).
  # - AttributeError during the gathering ("firewalld probably not be
  #   running...") and DBusException ("Unable to gather firewalld
  #   settings...", raised by the FirewallClient construction too - it
  #   sits inside the module's try block) become the module's exact
  #   fail_json messages; every other error is a plain module failure.
  #
  # Result (success, the module's own result-dict insertion order):
  # changed (always false - supports_check_mode, never mutates),
  # active_zones (echoed param), collected_zones, undefined_zones,
  # warnings (the ignored-zones note; the engine appends it after the
  # failed/changed backfill like real's controller does), firewalld_info
  # {version, default_zone, zones: {<zone>: {target, icmp_block_inversion,
  # interfaces, sources, services, ports, protocols, masquerade,
  # forward_ports, source_ports, icmp_blocks, rich_rules, [forward]}}}.
  # `forward` only appears when firewalld's version is >= 0.9.0 (the
  # module's own StrictVersion gate).
  class FirewalldInfoPlugin < BasePlugin
    # ansible.posix's module_utils/_respawn.py SYSTEM_PYTHON_INTERPRETERS,
    # verbatim - the respawn probe order.
    SYSTEM_PYTHON_INTERPRETERS = [
      "/usr/bin/libexec/platform-python",
      "/usr/bin/python3",
      "/usr/bin/python2",
      "/usr/bin/python",
    ]

    def execute : PluginResult
      active_zones = true?(@params["active_zones"]?)
      zones = @params["zones"]?.try { |raw| parse_zone_list(raw) }

      # Interpreter selection, mirroring the module's import gates +
      # _respawn path (see the class comment).
      python = Krikri.discovered_target_python
      unless python
        return PluginResult.new(changed: false, failed: true,
          msg: Krikri.missing_required_lib_message("python-dbus", "(no python interpreter found)"))
      end

      dbus_ok = python_imports?(python, "dbus")
      firewall_ok = python_imports?(python, "firewall.client")

      if !dbus_ok && !firewall_ok
        # The module's respawn_module("firewall"): probe the system
        # interpreters for `import firewall` only, re-run there.
        SYSTEM_PYTHON_INTERPRETERS.each do |candidate|
          next unless File.executable?(candidate)
          next unless python_imports?(candidate, "firewall")
          python = candidate
          dbus_ok = python_imports?(python, "dbus")
          firewall_ok = true
          break
        end
      end

      unless dbus_ok
        gate = Krikri.missing_python_library("python-dbus", "dbus")
        return PluginResult.new(changed: false, failed: true, msg: gate.try(&.[:msg]) ||
                                                                   Krikri.missing_required_lib_message("python-dbus", python))
      end
      unless firewall_ok
        gate = Krikri.missing_python_library("firewall", "firewall.client")
        return PluginResult.new(changed: false, failed: true, msg: gate.try(&.[:msg]) ||
                                                                   Krikri.missing_required_lib_message("firewall", python))
      end

      # 0700 dir + random name, same reasoning as py_module's own work dir.
      work_dir = File.join(Dir.tempdir, "krikri-fwinfo-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(work_dir, 0o700)
      begin
        params_path = File.join(work_dir, "params.json")
        File.write(params_path, {active_zones: active_zones, zones: zones}.to_json)
        script_path = File.join(work_dir, "firewalld_info_probe.py")
        File.write(script_path, GATHER_SCRIPT)

        stdout = IO::Memory.new
        Process.run(python, {script_path, params_path}, output: stdout, error: Process::Redirect::Close)

        data = JSON.parse(stdout.to_s)
        unless data["ok"]?.try(&.as_bool?)
          return PluginResult.new(changed: false, failed: true, msg: data["msg"].as_s)
        end

        # The module's exit_json kwargs/result insertion order. No msg key:
        # a success exit_json never passes one.
        result = PluginResult.new(
          changed: false,
          failed: false,
          key_order: ["changed", "active_zones", "collected_zones", "undefined_zones", "warnings", "firewalld_info"],
          active_zones: JSON::Any.new(active_zones),
          collected_zones: data["collected_zones"],
          undefined_zones: data["undefined_zones"],
          warnings: data["warnings"],
          firewalld_info: data["firewalld_info"],
        )
        add_exit_json_warnings_deprecation(result)
        result
      rescue ex
        PluginResult.new(changed: false, failed: true,
          msg: "firewalld_info: failed to gather firewalld information: #{ex.message}")
      ensure
        FileUtils.rm_rf(work_dir)
      end
    end

    private def python_imports?(interpreter : String, import_stmt : String) : Bool
      Process.run(interpreter, {"-c", "import #{import_stmt}"},
        output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    rescue
      false
    end

    # The exact stderr text ansible-core 2.19 renders for this deprecation
    # (see mount.cr's identical helper - same shape, same reason: the
    # module passes its `warnings` list to exit_json, which ansible-core
    # 2.19's _return_formatted deprecates outright; the structured entry
    # rides every SUCCESS result into registered vars, live-verified
    # against 2.19.11).
    CORE_WARNINGS_DEPRECATION_TEXT = "Passing `warnings` to `exit_json` or `fail_json` is deprecated. " \
                                     "This feature will be removed from ansible-core version 2.23. " \
                                     "Use `AnsibleModule.warn` instead."

    private def add_exit_json_warnings_deprecation(result : PluginResult) : Nil
      result.extra["deprecations"] = JSON.parse([{
        "collection_name" => "ansible.builtin",
        "deprecator"      => {"resolved_name" => "ansible.builtin", "type" => nil},
        "msg"             => "Passing `warnings` to `exit_json` or `fail_json` is deprecated.",
        "version"         => "2.23",
      }].to_json)
      result.extra["_ansible_core_deprecations"] = JSON.parse([CORE_WARNINGS_DEPRECATION_TEXT].to_json)
    end

    # The whole-value `{{ list_var }}` form arrives as the JSON the wire
    # serialized it to; a bare string is Ansible's own type:list
    # comma-split (see find.cr's parse_list_param for the same shape).
    private def parse_zone_list(raw : String) : Array(String)
      trimmed = raw.strip
      if trimmed.starts_with?('[') && trimmed.ends_with?(']')
        parsed = begin
          Array(String).from_json(trimmed)
        rescue
          nil
        end
        return parsed.map(&.strip).reject(&.empty?) if parsed
      end
      trimmed.split(",").map(&.strip).reject(&.empty?)
    end

    # The gathering half of ansible.posix.firewalld_info's main(), verbatim
    # call-for-call (FirewallClient construction INSIDE the try, the
    # version/default-zone pair first, the StrictVersion 'forward' gate,
    # the two exception messages byte-for-byte). Emits one JSON object on
    # stdout; stderr is ignored (the module's warnings would land in
    # Ansible's warning channel, not the result).
    GATHER_SCRIPT = <<-PYTHON
      import json
      import sys

      import dbus
      import firewall.client as fw_client
      import firewall.config as fw_config


      def version_ge(version, other):
          def parts(value):
              return [int(p) for p in value.split(".")]

          left, right = parts(version), parts(other)
          width = max(len(left), len(right))
          left += [0] * (width - len(left))
          right += [0] * (width - len(right))
          return left >= right


      def main():
          with open(sys.argv[1]) as handle:
              params = json.load(handle)
          active_zones = params.get("active_zones", False)
          zones_param = params.get("zones")

          firewalld_info = {}
          warn = []
          collected_zones = []
          undefined_zones = []
          try:
              client = fw_client.FirewallClient()
              firewalld_info["version"] = fw_config.VERSION
              firewalld_info["default_zone"] = client.getDefaultZone()

              zones_info = {}
              if active_zones:
                  collected_zones = list(client.getActiveZones().keys())
              elif zones_param:
                  all_zones = client.getZones()
                  specified = list(zones_param)
                  collected_zones = [z for z in specified if z in all_zones]
                  undefined_zones = [z for z in specified if z not in all_zones]
                  if undefined_zones:
                      warn.append(
                          "Please note: zone:(%s) have been ignored in the gathering process."
                          % ",".join(undefined_zones)
                      )
              else:
                  collected_zones = list(client.getZones())

              for zone in collected_zones:
                  zone_settings = client.getZoneSettings(zone)
                  zone_info = {}
                  zone_info["target"] = zone_settings.getTarget()
                  zone_info["icmp_block_inversion"] = zone_settings.getIcmpBlockInversion()
                  zone_info["interfaces"] = list(zone_settings.getInterfaces())
                  zone_info["sources"] = list(zone_settings.getSources())
                  zone_info["services"] = list(zone_settings.getServices())
                  zone_info["ports"] = [list(p) for p in zone_settings.getPorts()]
                  zone_info["protocols"] = list(zone_settings.getProtocols())
                  zone_info["masquerade"] = zone_settings.getMasquerade()
                  zone_info["forward_ports"] = [
                      list(p) for p in zone_settings.getForwardPorts()
                  ]
                  zone_info["source_ports"] = [
                      list(p) for p in zone_settings.getSourcePorts()
                  ]
                  zone_info["icmp_blocks"] = list(zone_settings.getIcmpBlocks())
                  zone_info["rich_rules"] = list(zone_settings.getRichRules())
                  if version_ge(firewalld_info["version"], "0.9.0"):
                      zone_info["forward"] = zone_settings.getForward()
                  zones_info[zone] = zone_info
              firewalld_info["zones"] = zones_info
          except AttributeError as err:
              json.dump(
                  {
                      "ok": False,
                      "msg": "firewalld probably not be running, Or the following method "
                      "is not supported with your python-firewall version. (Error: %s)"
                      % str(err),
                  },
                  sys.stdout,
              )
              return
          except dbus.exceptions.DBusException as err:
              json.dump(
                  {
                      "ok": False,
                      "msg": "Unable to gather firewalld settings. "
                      "You may need to run as the root user or use become. (Error: %s)"
                      % str(err),
                  },
                  sys.stdout,
              )
              return

          json.dump(
              {
                  "ok": True,
                  "collected_zones": collected_zones,
                  "undefined_zones": undefined_zones,
                  "warnings": warn,
                  "firewalld_info": firewalld_info,
              },
              sys.stdout,
          )


      main()
      PYTHON
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::FirewalldInfoPlugin.new(config)
plugin.run
