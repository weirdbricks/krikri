#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/virsh_net"

module Krikri
  # virt_net plugin (community.libvirt.virt_net) - manages libvirt
  # networks through the `virsh` CLI, mirroring the real module's
  # core() control flow exactly (real module source read, not assumed).
  #
  # Params: name (aliases network), state (active/inactive/present/
  # absent/undefined), command (define/create/start/stop/destroy/
  # undefine/get_xml/list_nets/facts/info/status/modify), uri (default
  # qemu:///system), xml, autostart.
  #
  # Real-module quirks ported deliberately:
  # - `state:` RETURNS before the `command:` and `autostart:` sections
  #   run - `state: active, autostart: yes` (mattgeddes.libvirt_kvm's
  #   own "libvirt networks running state" task, round 410102) never
  #   touches autostart in real Ansible either. `autostart:` alone (no
  #   state/command) is the spelling that actually toggles it.
  # - `command: define` on an already-defined network is a silent
  #   no-op (only defines when the network is missing), and
  #   `command: modify` defines it too when missing.
  # - modify implements the real module's only supported section: a
  #   single `<host mac=... name=... ip=.../>` DHCP entry added last
  #   (virsh net-update), idempotent on mac; anything else fails with
  #   the real module's "updating this is not supported yet" message.
  #
  # Not implemented: the facts/info `dhcp_leases` entry (needs a
  # live-network handle the CLI does not expose in a stable form).
  class VirtNetPlugin < BasePlugin
    private ENTRY_COMMANDS = %w[create status start stop undefine destroy get_xml define modify]
    private HOST_COMMANDS  = %w[list_nets facts info]

    def execute : PluginResult
      name = @params["name"]? || @params["network"]?
      state = @params["state"]?
      command = @params["command"]?
      uri = @params["uri"]? || "qemu:///system"
      xml = @params["xml"]?
      autostart = @params["autostart"]? ? true?(@params["autostart"]?) : nil
      check_mode = true?(@params["check_mode"]?)

      # Real Ansible's HAS_VIRT probe - on a host with no libvirt the
      # real module fails up front with this exact message (its python
      # binding isn't importable), before any parameter validation.
      # The CLI equivalent is the virsh binary itself being absent.
      return fail("The `libvirt` module is not importable. Check the requirements.") unless executable_in_path?("virsh")

      if state && command == "list_nets"
        nets = list_nets(uri).select { |n| net_state(uri, n) == state }
        return ok(false, "list_nets", JSON::Any.new(nets.map { |n| JSON::Any.new(n) }))
      end

      if state
        return fail("state change requires a specified name") unless name

        changed = false
        case state
        when "active"
          if net_state(uri, name) != "active"
            changed = true
            run!(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-start", name), "start network #{name}", check_mode)
          end
        when "present"
          unless net_exists?(uri, name)
            return fail("network '#{name}' not present, but xml not specified") unless xml
            define_network(uri, xml, check_mode)
            changed = true
          end
        when "inactive"
          if net_exists?(uri, name) && net_state(uri, name) != "inactive"
            changed = true
            run!(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-destroy", name), "destroy network #{name}", check_mode)
          end
        when "absent", "undefined"
          if net_exists?(uri, name)
            if net_state(uri, name) != "inactive"
              run!(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-destroy", name), "destroy network #{name}", check_mode)
            end
            changed = true
            run!(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-undefine", name), "undefine network #{name}", check_mode)
          end
        else
          return fail("unexpected state #{state}")
        end

        return ok(changed)
      end

      if command
        if ENTRY_COMMANDS.includes?(command)
          return fail("#{command} requires 1 argument: name") unless name

          case command
          when "define", "modify"
            return fail("#{command} requires xml argument") unless xml
            unless net_exists?(uri, name)
              define_network(uri, xml, check_mode)
              res = ok(true)
              res.extra["created"] = JSON::Any.new(name)
              return res
            end
            if command == "modify"
              mod = modify_network(uri, name, xml, check_mode)
              res = ok(mod)
              res.extra["modified"] = JSON::Any.new(name)
              return res
            end
            return ok(false)
          when "create", "start"
            return ok(false) if net_state(uri, name) == "active"
            run!(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-start", name), "start network #{name}", check_mode)
            return ok(true, command, JSON::Any.new(0))
          when "stop", "destroy"
            if net_state(uri, name) == "active"
              run!(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-destroy", name), "destroy network #{name}", check_mode)
              return ok(true, command, JSON::Any.new(0))
            end
            return ok(false, command, JSON::Any.new(nil))
          when "undefine"
            if net_exists?(uri, name)
              run!(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-undefine", name), "undefine network #{name}", check_mode)
              return ok(true, command, JSON::Any.new(0))
            end
            return ok(false, command, JSON::Any.new(nil))
          when "get_xml"
            rc, stdout_text, _ = capture(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-dumpxml", name))
            return fail("network '#{name}' not found") unless rc == 0
            return ok(false, command, JSON::Any.new(stdout_text))
          when "status"
            return ok(false, command, JSON::Any.new(net_state(uri, name)))
          end
        elsif HOST_COMMANDS.includes?(command)
          case command
          when "list_nets"
            return ok(false, command, JSON::Any.new(list_nets(uri).map { |n| JSON::Any.new(n) }))
          when "facts", "info"
            networks = gather_facts(uri, name)
            if command == "facts"
              return ok(false, nil, nil, "ansible_facts", JSON::Any.new({"ansible_libvirt_networks" => networks}))
            else
              return ok(false, command, JSON::Any.new({"networks" => networks}))
            end
          end
        else
          return fail("Command #{command} not recognized")
        end
      end

      if !autostart.nil?
        return fail("state change requires a specified name") unless name

        current = net_info(uri, name)[:autostart]
        if current != autostart
          if autostart
            run!(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-autostart", name), "enable autostart", check_mode)
          else
            run!(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-autostart", name, "--disable"), "disable autostart", check_mode)
          end
          return ok(true)
        end
        return ok(false)
      end

      fail("expected state or command parameter to be specified")
    end

    private def fail(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    private def executable_in_path?(binary : String) : Bool
      ENV.fetch("PATH", "").split(':').any? do |dir|
        exe = File.join(dir, binary)
        File.exists?(exe) && File.executable?(exe)
      end
    end

    private def ok(changed : Bool, command : String? = nil, command_value : JSON::Any? = nil, facts_key : String? = nil, facts_value : JSON::Any? = nil) : PluginResult
      res = PluginResult.new(changed: changed, failed: false, msg: "")
      if command && command_value
        res.extra[command] = command_value
      elsif facts_key && facts_value
        res.extra[facts_key] = facts_value
      end
      res
    end

    private def net_exists?(uri : String, name : String) : Bool
      capture(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-info", name))[0] == 0
    end

    private def net_info(uri : String, name : String) : NamedTuple(active: Bool?, autostart: Bool?, persistent: Bool?, bridge: String?)
      rc, stdout_text, _ = capture(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-info", name))
      return {active: nil, autostart: nil, persistent: nil, bridge: nil} unless rc == 0
      Krikri::PluginHelpers::VirshNet.parse_net_info(stdout_text)
    end

    private def net_state(uri : String, name : String) : String
      active = net_info(uri, name)[:active]
      active.nil? ? "inactive" : (active ? "active" : "inactive")
    end

    private def list_nets(uri : String) : Array(String)
      rc, stdout_text, _ = capture(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-list", "--all", "--name"))
      return [] of String unless rc == 0
      stdout_text.split("\n").map(&.strip).reject(&.empty?)
    end

    private def define_network(uri : String, xml : String, check_mode : Bool) : Nil
      return if check_mode
      tmp = File.tempfile("krikri-virt-net", ".xml")
      tmp.print(xml)
      tmp.close
      begin
        run!(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-define", tmp.path), "define network", false)
      ensure
        File.delete?(tmp.path)
      end
    end

    # The real module's modify(): finds the DHCP <host> entry with the
    # same mac in the network's XML and adds (ADD_LAST) or rewrites it.
    # A same-mac host with matching name AND ip is a no-op.
    private def modify_network(uri : String, name : String, xml : String, check_mode : Bool) : Bool
      rc, dump, err = capture(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-dumpxml", name))
      raise "Cannot get network XML: #{err.strip}" unless rc == 0

      requested = Krikri::PluginHelpers::VirshNet.parse_dhcp_hosts(xml).first?
      raise "updating this is not supported yet #{xml}" unless requested

      existing = Krikri::PluginHelpers::VirshNet.parse_dhcp_hosts(dump).find { |h| h.mac == requested.mac }
      if existing && existing.name == requested.name && existing.ip == requested.ip
        return false
      end

      cmd = Krikri::PluginHelpers::VirshNet.net_update_command(uri, name, xml, net_state(uri, name) == "active")
      raise "updating this is not supported yet #{xml}" unless cmd
      run!(cmd, "update network #{name}", check_mode)
      true
    end

    private def gather_facts(uri : String, single : String?) : JSON::Any
      entries = single ? [single] : list_nets(uri)
      results = Hash(String, JSON::Any).new
      entries.each do |net|
        info = net_info(uri, net)
        rc, dump, _ = capture(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-dumpxml", net))
        xml = rc == 0 ? dump : ""

        facts = {
          "state"      => JSON::Any.new(info[:active].nil? ? "unknown" : (info[:active] == true ? "active" : "inactive")),
          "autostart"  => JSON::Any.new(info[:autostart].nil? ? "unknown" : (info[:autostart] == true ? "yes" : "no")),
          "persistent" => JSON::Any.new(info[:persistent].nil? ? "unknown" : (info[:persistent] == true ? "yes" : "no")),
          "bridge"     => (b = info[:bridge]) ? JSON::Any.new(b) : JSON::Any.new(nil),
        } of String => JSON::Any

        rc, uuid_out, _ = capture(Krikri::PluginHelpers::VirshNet.virsh(uri, "net-uuid", net))
        facts["uuid"] = JSON::Any.new(rc == 0 ? uuid_out.strip : "")
        facts["forward_mode"] = (fm = Krikri::PluginHelpers::VirshNet.parse_forward_mode(xml)) ? JSON::Any.new(fm) : JSON::Any.new(nil)
        facts["domain"] = (dm = Krikri::PluginHelpers::VirshNet.parse_domain(xml)) ? JSON::Any.new(dm) : JSON::Any.new(nil)
        facts["macaddress"] = (ma = Krikri::PluginHelpers::VirshNet.parse_macaddress(xml)) ? JSON::Any.new(ma) : JSON::Any.new(nil)

        results[net] = JSON::Any.new(facts)
      end
      JSON::Any.new(results)
    end

    private def capture(cmd : Array(String)) : {Int32, String, String}
      out_io = IO::Memory.new
      err_io = IO::Memory.new
      status = Process.run(cmd[0], cmd[1..], output: out_io, error: err_io)
      {status.success? ? 0 : 1, out_io.to_s, err_io.to_s}
    end

    private def run!(cmd : Array(String), what : String, check_mode : Bool) : Nil
      return if check_mode
      rc, _, err = capture(cmd)
      raise "#{what} failed: #{err.strip}" unless rc == 0
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::VirtNetPlugin.new(config)
plugin.run
