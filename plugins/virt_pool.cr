#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/virsh_pool"

module Krikri
  # virt_pool plugin (community.libvirt.virt_pool) - manages libvirt
  # storage pools through the `virsh` CLI, mirroring the Ansible module's
  # core() control flow (Ansible module source read, not assumed).
  #
  # Params: name (aliases pool), state (active/inactive/present/absent/
  # undefined/deleted), command (define/create/start/stop/destroy/
  # undefine/build/delete/get_xml/list_pools/facts/info/status/refresh),
  # uri (default qemu:///system), xml, autostart, mode.
  #
  # ghyde.libvirt (issue #1360) calls `command: list_pools` in check mode
  # and branches on the registered `list_pools` list; without this plugin
  # the task was dropped as an unimplemented one, and the registered skip
  # dict made the block's own `when:` fail fatally where real answered ok.
  #
  # Real-module quirks ported deliberately:
  # - argument-spec validation (state/command/mode choices and the
  #   `autostart` bool type) fires at AnsibleModule construction time -
  #   BEFORE the libvirt import probe - so an invalid choice fails with
  #   parameters.py wording on a libvirt-less host.
  # - the `name` requirement is NOT an argument-spec one (unlike
  #   virt_net's required_if): core() checks it after the probes, so a
  #   libvirt-less host reports the import message first.
  # - `state:` returns before the `command:`/`autostart:` sections, and
  #   the state branches leave `msg` as Ansible's native libvirt return
  #   code (0) only when they actually changed something; the check-mode
  #   branches of conn.create/destroy/undefine/delete exit from INSIDE
  #   the method, so those tasks carry no `msg` key at all.
  # - `command: define` on an already-defined pool emits a bare empty
  #   result (no changed key on the wire at all).
  # - `command: refresh` has no check-mode branch in the Ansible module:
  #   it runs the libvirt call even under --check.
  #
  # Not implemented: nothing the Ansible module surfaces, except that
  # the facts/info byte sizes need a `virsh pool-info --bytes` (libvirt
  # prints human units otherwise and those have no lossless byte count).
  class VirtPoolPlugin < BasePlugin
    private ENTRY_COMMANDS = %w[create status start stop build delete undefine destroy get_xml define refresh]
    private HOST_COMMANDS  = %w[list_pools facts info]
    private ALL_COMMANDS   = ENTRY_COMMANDS + HOST_COMMANDS
    private STATE_CHOICES  = %w[active inactive present absent undefined deleted]
    private MODE_CHOICES   = %w[new repair resize no_overwrite overwrite normal zeroed]

    # virt_pool's real argument-spec declaration order, for the `type:
    # bool` validation AnsibleModule performs before main().
    protected def bool_params : Array(String)
      %w[autostart]
    end

    def execute : PluginResult
      validate_bool_params!
      if err = validate_choices
        return err
      end

      # Ansible's HAS_VIRT probe - on a host with no libvirt the Ansible
      # module fails up front with this exact message (its python binding
      # isn't importable). The CLI equivalent is the virsh binary itself
      # being absent.
      return fail("The `libvirt` module is not importable. Check the requirements.") unless executable_in_path?("virsh")

      state = @params["state"]?
      command = @params["command"]?
      name = pool_name

      if state && command == "list_pools"
        return list_pools_result(state)
      end

      if state
        return fail("state change requires a specified name") unless name
        return execute_state(name, state)
      end

      if command
        return execute_command(name, command)
      end

      unless (value = @params["autostart"]?).nil?
        return execute_autostart(name, true?(value))
      end

      fail("expected state or command parameter to be specified")
    end

    # AnsibleModule construction - choices for state/command/mode and
    # the autostart bool all fire before the HAS_VIRT probe below.
    private def validate_choices : PluginResult?
      if (state = @params["state"]?) && !STATE_CHOICES.includes?(state)
        return fail("value of state must be one of: #{STATE_CHOICES.join(", ")}, got: #{state}")
      end
      if (command = @params["command"]?) && !ALL_COMMANDS.includes?(command)
        return fail("value of command must be one of: #{ALL_COMMANDS.join(", ")}, got: #{command}")
      end
      if (mode = @params["mode"]?) && !MODE_CHOICES.includes?(mode)
        return fail("value of mode must be one of: #{MODE_CHOICES.join(", ")}, got: #{mode}")
      end
      nil
    end

    private def execute_state(name : String, state : String) : PluginResult
      case state
      when "active"
        state_active(name)
      when "present"
        state_present(name)
      when "inactive"
        state_inactive(name)
      when "undefined", "absent"
        state_absent(name)
      when "deleted"
        state_deleted(name)
      else
        fail("unexpected state")
      end
    end

    private def state_active(name : String) : PluginResult
      uri = pool_uri
      current = pool_status(uri, name)
      if current.nil?
        # conn.get_status lets EntryNotFound escape in a real run; its
        # check-mode branch swallows it into "unknown", after which
        # v.start's own check branch exits changed=True.
        return fail("storage pool #{name} not found") unless check_mode?
        return ok(true)
      end
      return ok(false) if current == "active"
      return ok(true) if check_mode?
      if res = run!(virsh(uri, "pool-start", name))
        return res
      end
      ok(true, native_msg: JSON::Any.new(0))
    end

    private def state_present(name : String) : PluginResult
      uri = pool_uri
      return ok(false) if pool_exists?(uri, name)
      return fail("storage pool '#{name}' not present, but xml not specified") unless xml = @params["xml"]?
      # conn.define_from_xml's check branch exits changed=True.
      return ok(true) if check_mode?
      if res = define_pool(uri, xml)
        return res
      end
      res = ok(true)
      res.extra["created"] = JSON::Any.new(name)
      res
    end

    private def state_inactive(name : String) : PluginResult
      uri = pool_uri
      return ok(false) unless pool_exists?(uri, name)
      return ok(false) if pool_status(uri, name) == "inactive"
      return ok(true) if check_mode?
      if res = run!(virsh(uri, "pool-destroy", name))
        return res
      end
      ok(true, native_msg: JSON::Any.new(0))
    end

    private def state_absent(name : String) : PluginResult
      uri = pool_uri
      return ok(false) unless pool_exists?(uri, name)
      if pool_status(uri, name) != "inactive"
        return ok(true) if check_mode?
        if res = run!(virsh(uri, "pool-destroy", name))
          return res
        end
      end
      # conn.undefine's check branch re-finds the still-present pool and
      # falls through, so `msg` stays None there.
      return ok(true, native_msg: JSON::Any.new(nil)) if check_mode?
      if res = run!(virsh(uri, "pool-undefine", name))
        return res
      end
      ok(true, native_msg: JSON::Any.new(0))
    end

    private def state_deleted(name : String) : PluginResult
      uri = pool_uri
      return ok(false) unless pool_exists?(uri, name)
      if pool_status(uri, name) != "inactive"
        return ok(true) if check_mode?
        if res = run!(virsh(uri, "pool-destroy", name))
          return res
        end
      end
      # conn.delete's check branch exits changed=True for a present
      # pool, so the undefine (and its msg) never runs under --check.
      return ok(true) if check_mode?
      if res = run!(virsh(uri, "pool-delete", name))
        return res
      end
      if res = run!(virsh(uri, "pool-undefine", name))
        return res
      end
      ok(true, native_msg: JSON::Any.new(0))
    end

    private def execute_command(name : String?, command : String) : PluginResult
      if ENTRY_COMMANDS.includes?(command)
        return fail("#{command} requires 1 argument: name") unless name
        return execute_entry_command(name, command)
      end

      return fail("Command #{command} not recognized") unless HOST_COMMANDS.includes?(command)
      execute_host_command(command)
    end

    private def execute_entry_command(name : String, command : String) : PluginResult
      case command
      when "define"
        command_define(name)
      when "build"
        command_build(name)
      when "delete"
        command_delete(name)
      when "create", "start"
        command_start(name, command)
      when "stop", "destroy"
        command_stop(name, command)
      when "undefine"
        command_undefine(name, command)
      when "status"
        command_status(name, command)
      when "get_xml"
        command_get_xml(name, command)
      when "refresh"
        command_refresh(name, command)
      else
        fail("Command #{command} not recognized")
      end
    end

    private def execute_host_command(command : String) : PluginResult
      uri = pool_uri
      case command
      when "list_pools"
        command_result(command, JSON::Any.new(list_pools(uri).map { |pool| JSON::Any.new(pool) }))
      when "facts"
        command_result("ansible_facts", JSON::Any.new({"ansible_libvirt_pools" => gather_facts(uri)}))
      when "info"
        command_result("pools", gather_facts(uri))
      else
        fail("Command #{command} not recognized")
      end
    end

    private def command_define(name : String) : PluginResult
      uri = pool_uri
      return fail("define requires xml argument") unless xml = @params["xml"]?
      # An already-defined pool produces no keys at all on the wire.
      return empty_result if pool_exists?(uri, name)
      # conn.define_from_xml's check branch exits changed=True.
      return ok(true) if check_mode?
      if res = define_pool(uri, xml)
        return res
      end
      res = ok(true)
      res.extra["created"] = JSON::Any.new(name)
      res
    end

    private def command_build(name : String) : PluginResult
      uri = pool_uri
      if check_mode?
        return ok(true) unless pool_exists?(uri, name)
        return command_changed_result("build", JSON::Any.new(nil))
      end
      if res = run!(PluginHelpers::VirshPool.build_command(uri, name, @params["mode"]?))
        return res
      end
      command_changed_result("build", JSON::Any.new(0))
    end

    private def command_delete(name : String) : PluginResult
      uri = pool_uri
      if check_mode?
        return ok(true) if pool_exists?(uri, name)
        return command_changed_result("delete", JSON::Any.new(nil))
      end
      if res = run!(virsh(uri, "pool-delete", name))
        return res
      end
      command_changed_result("delete", JSON::Any.new(0))
    end

    private def command_start(name : String, command : String) : PluginResult
      uri = pool_uri
      if check_mode?
        return ok(true) unless pool_status(uri, name) == "active"
        return command_result(command, JSON::Any.new(nil))
      end
      if res = run!(virsh(uri, "pool-start", name))
        return res
      end
      command_result(command, JSON::Any.new(0))
    end

    private def command_stop(name : String, command : String) : PluginResult
      uri = pool_uri
      if check_mode?
        return ok(true) if pool_status(uri, name) == "active"
        return command_result(command, JSON::Any.new(nil))
      end
      if res = run!(virsh(uri, "pool-destroy", name))
        return res
      end
      command_result(command, JSON::Any.new(0))
    end

    private def command_undefine(name : String, command : String) : PluginResult
      uri = pool_uri
      return fail("storage pool #{name} not found") unless pool_exists?(uri, name)
      return command_result(command, JSON::Any.new(nil)) if check_mode?
      if res = run!(virsh(uri, "pool-undefine", name))
        return res
      end
      command_result(command, JSON::Any.new(0))
    end

    private def command_status(name : String, command : String) : PluginResult
      current = pool_status(pool_uri, name)
      return fail("storage pool #{name} not found") if current.nil? && !check_mode?
      # conn.get_status's check-mode catch answers ENTRY_STATE_ACTIVE_MAP's
      # "inactive" lookup, which is not a state key -> "unknown".
      command_result(command, JSON::Any.new(current || "unknown"))
    end

    private def command_get_xml(name : String, command : String) : PluginResult
      rc, dump, err = capture(virsh(pool_uri, "pool-dumpxml", name))
      return fail(virsh_error_msg(err)) unless rc == 0
      command_result(command, JSON::Any.new(dump))
    end

    private def command_refresh(name : String, command : String) : PluginResult
      # The Ansible module's refresh() has no check-mode guard.
      if res = run!(virsh(pool_uri, "pool-refresh", name))
        return res
      end
      command_result(command, JSON::Any.new(0))
    end

    private def execute_autostart(name : String?, autostart : Bool) : PluginResult
      return fail("state change requires a specified name") unless name

      info = pool_info(pool_uri, name)
      if info.nil?
        # conn.get_autostart2's check branch catches EntryNotFound and
        # exits changed=True; the non-check branch lets it reach
        # core()'s fail_json.
        return ok(true) if check_mode?
        return fail("storage pool #{name} not found")
      end

      current = info.autostart == true
      if autostart
        return ok(false) if current
        # conn.set_autostart's check branch exits changed=True.
        return ok(true) if check_mode?
        if res = run!(virsh(pool_uri, "pool-autostart", name))
          return res
        end
        return ok(true, native_msg: JSON::Any.new(0))
      end

      return ok(false) unless current
      return ok(true) if check_mode?
      if res = run!(virsh(pool_uri, "pool-autostart", "--disable", name))
        return res
      end
      ok(true, native_msg: JSON::Any.new(0))
    end

    private def fail(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    private def pool_name : String?
      @params["name"]? || @params["pool"]?
    end

    private def pool_uri : String
      @params["uri"]? || "qemu:///system"
    end

    private def check_mode? : Bool
      true?(@params["_ansible_check_mode"]?)
    end

    private def executable_in_path?(binary : String) : Bool
      ENV.fetch("PATH", "").split(':').any? do |dir|
        exe = File.join(dir, binary)
        File.exists?(exe) && File::Info.executable?(exe)
      end
    end

    # native_msg carries Ansible's NATIVE-typed `msg` (the libvirt return
    # code integer its state branches pass straight through, or the None
    # those branches assign when the check-mode method already exited);
    # nil keeps the string msg (which PluginResult then drops when empty,
    # exactly like Ansible's absent msg key).
    private def ok(changed : Bool, native_msg : JSON::Any? = nil) : PluginResult
      PluginResult.new(changed: changed, failed: false, msg: "", native_msg: native_msg)
    end

    # Ansible's ENTRY/HOST command results are exit_json(**{command:
    # value}) with NO `changed` key at all - core() only sets
    # res['changed'] on the state, define and build/delete branches. The
    # task executor backfills changed at the tail.
    private def command_result(command : String, value : JSON::Any) : PluginResult
      res = PluginResult.new(changed: false, failed: false, omit_changed: true, key_order: [command])
      res.extra[command] = value
      res
    end

    # build/delete are the two commands whose result object starts with
    # changed: True AND the command's own value.
    private def command_changed_result(command : String, value : JSON::Any) : PluginResult
      res = PluginResult.new(changed: true, failed: false)
      res.extra[command] = value
      res
    end

    private def empty_result : PluginResult
      PluginResult.new(changed: false, failed: false, omit_changed: true)
    end

    # v.list_pools(state=state) filters libvirt's own active/inactive
    # status; a state like "present" simply matches nothing.
    private def list_pools_result(state : String) : PluginResult
      uri = pool_uri
      pools = list_pools(uri).select { |pool| pool_status(uri, pool) == state }
      command_result("list_pools", JSON::Any.new(pools.map { |pool| JSON::Any.new(pool) }))
    end

    private def pool_info(uri : String, name : String) : PluginHelpers::VirshPool::PoolInfo?
      rc, text, _ = capture(virsh(uri, "pool-info", "--bytes", name))
      rc == 0 ? PluginHelpers::VirshPool.parse_pool_info(text) : nil
    end

    private def pool_exists?(uri : String, name : String) : Bool
      !pool_info(uri, name).nil?
    end

    # virStoragePoolIsActive(): active/inactive only, nil when the pool
    # is missing (the Ansible module's EntryNotFound).
    private def pool_status(uri : String, name : String) : String?
      info = pool_info(uri, name)
      return nil unless info
      PluginHelpers::VirshPool.active_state?(info.state) ? "active" : "inactive"
    end

    private def list_pools(uri : String) : Array(String)
      rc, text, _ = capture(virsh(uri, "pool-list", "--all", "--name"))
      return [] of String unless rc == 0
      PluginHelpers::VirshPool.parse_pool_names(text)
    end

    private def volume_names(uri : String, name : String) : Array(String)
      rc, text, _ = capture(virsh(uri, "vol-list", "--name", name))
      return [] of String unless rc == 0
      PluginHelpers::VirshPool.parse_pool_names(text)
    end

    private def define_pool(uri : String, xml : String) : PluginResult?
      tmp = File.tempfile("krikri-virt-pool", ".xml")
      tmp.print(xml)
      tmp.close
      begin
        run!(PluginHelpers::VirshPool.define_command(uri, tmp.path))
      ensure
        File.delete?(tmp.path)
      end
    end

    private def gather_facts(uri : String) : JSON::Any
      results = Hash(String, JSON::Any).new
      list_pools(uri).each do |pool|
        if facts = pool_facts(uri, pool)
          results[pool] = JSON::Any.new(facts)
        end
      end
      JSON::Any.new(results)
    end

    private def pool_facts(uri : String, pool : String) : Hash(String, JSON::Any)?
      info = pool_info(uri, pool)
      return nil unless info

      xml = pool_xml(uri, pool)
      active = PluginHelpers::VirshPool.active_state?(info.state)
      facts = {
        "status"         => JSON::Any.new(PluginHelpers::VirshPool.info_state(info.state)),
        "size_total"     => JSON::Any.new((info.capacity || 0).to_s),
        "size_used"      => JSON::Any.new((info.allocation || 0).to_s),
        "size_available" => JSON::Any.new((info.available || 0).to_s),
        "autostart"      => JSON::Any.new(info.autostart ? "yes" : "no"),
        "persistent"     => JSON::Any.new(info.persistent ? "yes" : "no"),
        "state"          => JSON::Any.new(active ? "active" : "inactive"),
        "type"           => json_or_null(PluginHelpers::VirshPool.parse_pool_type(xml)),
        "uuid"           => JSON::Any.new(info.uuid || ""),
      } of String => JSON::Any

      if active
        volumes = volume_names(uri, pool)
        facts["volume_count"] = JSON::Any.new(volumes.size)
        facts["volumes"] = JSON::Any.new(volumes.map { |volume| JSON::Any.new(volume) })
      else
        facts["volume_count"] = JSON::Any.new(-1)
      end

      add_xml_facts(facts, xml)
      facts
    end

    private def add_xml_facts(facts : Hash(String, JSON::Any), xml : String) : Nil
      if path = PluginHelpers::VirshPool.parse_target_path(xml)
        facts["path"] = JSON::Any.new(path)
      end
      if host = PluginHelpers::VirshPool.parse_source_host(xml)
        facts["host"] = JSON::Any.new(host)
      end
      if source_path = PluginHelpers::VirshPool.parse_source_path(xml)
        facts["source_path"] = JSON::Any.new(source_path)
      end
      if format = PluginHelpers::VirshPool.parse_source_format(xml)
        facts["format"] = JSON::Any.new(format)
      end
      devices = PluginHelpers::VirshPool.parse_source_devices(xml)
      unless devices.empty?
        facts["devices"] = JSON::Any.new(devices.map { |device| JSON::Any.new(device) })
      end
    end

    private def json_or_null(value : String?) : JSON::Any
      value ? JSON::Any.new(value) : JSON::Any.new(nil)
    end

    private def pool_xml(uri : String, name : String) : String
      rc, dump, _ = capture(virsh(uri, "pool-dumpxml", name))
      rc == 0 ? dump : ""
    end

    private def virsh(uri : String, subcommand : String, *args : String) : Array(String)
      PluginHelpers::VirshPool.virsh(uri, subcommand, *args)
    end

    private def capture(cmd : Array(String)) : {Int32, String, String}
      out_io = IO::Memory.new
      err_io = IO::Memory.new
      status = Process.run(cmd[0], cmd[1..], output: out_io, error: err_io)
      {status.success? ? 0 : 1, out_io.to_s, err_io.to_s}
    end

    # Real talks to libvirt through its python bindings and reports
    # libvirt's own error text verbatim (EntryNotFound's
    # "storage pool %s not found" for a missing pool, str(libvirtError)
    # for everything else). virsh instead wraps the same errors as
    # "error: " lines - strip those wrappers so the registered msg
    # matches Ansible's.
    private def virsh_error_msg(err : String) : String
      lines = err.strip.split("\n").map(&.sub(/^error: /, "")).reject(&.empty?)
      if line = lines.find(&.starts_with?("failed to get pool '"))
        if pool = line[/\Afailed to get pool '(.*)'\z/, 1]
          return "storage pool #{pool} not found"
        end
      end
      lines.reject(&.starts_with?("Failed to ")).join("\n")
    end

    private def run!(cmd : Array(String)) : PluginResult?
      rc, _, err = capture(cmd)
      return nil if rc == 0
      fail(virsh_error_msg(err))
    end
  end
end
