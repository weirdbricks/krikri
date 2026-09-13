require "json"
require "../base_action_plugin"

module Krikri
  # add_host: (ansible.builtin.addhost) as a controller-side action plugin -
  # real Ansible's own add_host is action-plugin-only (no target-side
  # module exists), and its entire effect is a controller-side inventory
  # mutation, so a remote round trip would be meaningless. The plugin
  # mutates the ONE shared Inventory instance every play's host-pattern
  # resolution reads from (krikri-playbook.cr's own `inventory` local,
  # same object handed to every TaskExecutor) - that mutation is the whole
  # feature: a host added in play 1 only shows up when play 2's `hosts:`
  # pattern is resolved because play 2 re-calls Inventory#get_hosts on the
  # same object. It is deliberately NOT added to the current play's own
  # host list (already fixed before the task ran) - real Ansible behaves
  # the same way, verified.
  #
  # Out of scope on purpose: exact host-var precedence layering for the
  # new host (its vars are plain host vars, same as any inventory-parsed
  # host), delegate_to: against a dynamically-added host, and inventory
  # plugins re-running over the mutated inventory.
  class AddHostActionPlugin < ActionPlugin
    NAME_PARAMS  = {"name", "hostname"}
    GROUP_PARAMS = {"groups", "group"}

    def execute : ActionResult
      inventory = @inventory
      unless inventory
        return ActionResult.failure("add_host: no inventory available in this context")
      end

      name = find_param(NAME_PARAMS)
      unless name
        return ActionResult.failure("add_host: requires a non-empty 'name' (or 'hostname') argument")
      end

      host = inventory.hosts[name]? || Host.new(name)
      @params.each do |key, value|
        next if NAME_PARAMS.includes?(key) || GROUP_PARAMS.includes?(key)
        host.vars[key] = JSON::Any.new(value)
      end

      # Mirror InventoryParser's own ansible_user/ansible_port handling -
      # the SSH/connection layer reads Host#user/#port, not just vars.
      host.user = host.vars["ansible_user"]?.try(&.as_s?) || host.user
      if (port = host.vars["ansible_port"]?) && (port_i = port.as_i? || port.as_s?.try(&.to_i?))
        host.port = port_i
      end

      group_names = parse_group_names
      inventory.add_host(host)
      inventory.get_or_create_group("all").add_host(host)
      group_names.each do |group_name|
        inventory.get_or_create_group(group_name).add_host(host)
      end

      extra = {
        "add_host" => JSON::Any.new({
          "host_name" => JSON::Any.new(name),
          "groups"    => JSON::Any.new(group_names.map { |group_name| JSON::Any.new(group_name) }),
          "host_vars" => JSON::Any.new(host.vars),
        }),
      }
      ActionResult.final(ActionResult.plugin_result_json(true, false, "", extra))
    end

    # `groups`/`group` accepts a comma-separated string, a JSON array
    # (a literal YAML list hits parse_module_params's stringify_value and
    # arrives comma-joined; a templated `groups: "{{ some_list }}"` may
    # arrive as valid JSON or as Python's single-quoted repr - the same
    # rendering bug class SetFactActionPlugin#try_parse_json already
    # handles), or a bare single group name.
    private def parse_group_names : Array(String)
      raw = find_param(GROUP_PARAMS)
      return [] of String unless raw

      trimmed = raw.strip
      if trimmed.starts_with?('[') && (parsed = try_parse_json(trimmed)) && (items = parsed.as_a?)
        return items.compact_map(&.as_s?).reject(&.empty?)
      end

      trimmed.split(',').map(&.strip).reject(&.empty?)
    end

    private def find_param(keys) : String?
      keys.each do |key|
        value = @params[key]?
        return value if value && !value.strip.empty?
      end
      nil
    end

    private def try_parse_json(value : String) : JSON::Any?
      JSON.parse(value)
    rescue JSON::ParseException
      JSON.parse(value.gsub('\'', '"')) rescue nil
    end
  end
end
