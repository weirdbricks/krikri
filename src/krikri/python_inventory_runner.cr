require "json"
require "./bigint_json"
require "./spawn_error"
require "./controller_python"
require "./python_filter_runner"

# Runner for CUSTOM inventory plugins - an `inventory_plugins/<name>.py`
# next to the playbook, or in Ansible's configured inventory plugin
# directories (`ANSIBLE_INVENTORY_PLUGINS`, `$ANSIBLE_HOME/plugins/
# inventory`, `/usr/share/ansible/plugins/inventory`).
#
# Ansible's `auto` inventory plugin is what makes a YAML source like
# `plugin: myinv` work: it reads the `plugin` key and hands the source
# to that plugin's own `parse()`, which populates the controller-side
# inventory data through `add_host`/`set_variable`. krikri's own plugin
# support (InventoryPlugins) reimplements the few built-ins it knows;
# before this runner, every other name ended in "Inventory plugin 'x'
# is not supported" (issue #1475), so the play ran against the implicit
# localhost while ansible-playbook ran it against the plugin's hosts.
#
# Like the custom lookup/filter runners, nothing here reimplements a
# plugin: the source file is handed to the CONTROLLER's own python3
# (the interpreter Ansible itself runs under), which loads the
# `InventoryModule` class, calls `verify_file` + `parse` against a real
# `ansible.inventory.data.InventoryData`, and prints the resulting
# hosts, group memberships and vars back as JSON. Only "the mechanism
# cannot run at all" (no source file on the search path, no python3, the
# `ansible` package not importable by it, a file declaring no
# `InventoryModule`) leaves the caller on its unchanged "not supported"
# error - inventories WITHOUT custom plugins behave exactly as before.
# A plugin that raises IS surfaced: Ansible reports it as a failed
# parse, and so does krikri.
module Krikri
  module PythonInventoryRunner
    extend self

    # The mechanism cannot serve this plugin name at all: no source file
    # on Ansible's search path, no controller python3 that can import
    # ansible, or a file that declares no `InventoryModule` subclass.
    # The caller keeps its pre-existing "not supported" error.
    class Unavailable < Exception
    end

    # The plugin WAS found and dispatched, and Ansible would report its
    # failure ("Failed to parse ... with <name> plugin"): a raising
    # `verify_file`/`parse`, or an import error in the plugin file.
    class PluginError < Exception
    end

    # Ansible derives an inventory plugin's name from its FILE NAME
    # (`inventory_plugins/myinv.py` IS the `myinv` plugin), so no Python
    # introspection is needed to find it. Search order follows Ansible's
    # loader: the playbook-adjacent directory first (ansible-playbook
    # calls add_all_plugin_dirs on the playbook's own directory before
    # any inventory is parsed), then the configured paths - which,
    # exactly like the lookup/filter runners, come from
    # ANSIBLE_INVENTORY_PLUGINS when set and the same two defaults
    # otherwise.
    def find_source(name : String, playbook_dir : String?) : String?
      if playbook_dir && !playbook_dir.empty?
        path = File.join(playbook_dir, "inventory_plugins", "#{name}.py")
        return path if File.file?(path)
      end
      PythonFilterRunner.configured_roots("inventory", "ANSIBLE_INVENTORY_PLUGINS").each do |root|
        path = File.join(root, "#{name}.py")
        return path if File.file?(path)
      end
      nil
    end

    # Runs the plugin for *name* against the inventory source *source*
    # and returns the inventory it populated.
    def parse(name : String, source : String, playbook_dir : String?) : Inventory
      path = find_source(name, playbook_dir)
      raise Unavailable.new("no inventory_plugins/#{name}.py on the search path") unless path

      # Ansible unfrackpaths the source before any plugin sees it; the
      # wrapper process has no reason to share our cwd (krikri has
      # already chdir'd into the playbook's directory).
      result = run_wrapper({
        "path"   => path,
        "name"   => name,
        "source" => File.expand_path(source),
      })
      raise Unavailable.new("inventory plugin wrapper produced no result") unless result

      unless result["ok"]?.try(&.as_bool?)
        kind = result["kind"]?.try(&.as_s?) || "error"
        detail = result["error"]?.try(&.as_s?) || "unknown error"
        case kind
        when "unavailable", "not_found"
          raise Unavailable.new(detail)
        when "load"
          raise PluginError.new("The inventory plugin '#{name}' failed to load: #{detail}")
        when "verify"
          # Ansible's auto plugin's own wording for a plugin that refuses
          # the source it was matched to.
          raise PluginError.new(detail)
        else
          raise PluginError.new(detail.empty? ? "The inventory plugin '#{name}' failed." : "The inventory plugin '#{name}' failed: #{detail}")
        end
      end

      build_inventory(result)
    end

    # The controller's own python3 (see PythonLookupRunner#python_executable).
    def python_executable : String?
      ControllerPython.executable
    end

    # Builds an Inventory from the wrapper's response. Groups are created
    # first-name-wins over the two Ansible always has (`all`,
    # `ungrouped`), which an Inventory starts with already, and every
    # membership/membership-of-a-child references hosts by name - the
    # same Host instance whichever groups list it.
    private def build_inventory(result : JSON::Any) : Inventory
      inventory = Inventory.new

      if hosts = result["hosts"]?.try(&.as_h?)
        hosts.each do |host_name, host_vars|
          host = Host.new(host_name)
          host_vars.as_h?.try &.each do |key, value|
            host.vars[key] = value
          end
          # Same mirroring every other inventory format does: the two vars
          # that also live on the Host itself, so a connection that falls
          # back to the Host's own fields dials the right user/port.
          if user = host.vars["ansible_user"]?.try(&.as_s?)
            host.user = user
          end
          if ansible_port = host.vars["ansible_port"]?
            host.port = ansible_port.as_i? || ansible_port.as_s?.try(&.to_i?) || host.port
          end
          inventory.add_host(host)
        end
      end

      if groups = result["groups"]?.try(&.as_h?)
        groups.each do |group_name, group_def|
          next unless group_def.as_h?
          group = inventory.get_or_create_group(group_name)

          group_def["vars"]?.try(&.as_h?).try &.each do |key, value|
            group.vars[key] = value
          end

          group_def["hosts"]?.try(&.as_a?).try &.each do |member|
            # `all` is kept as an empty group by krikri's own inventory
            # model (its membership is implicit), so a plugin listing
            # every host under `all` must not turn it into a literal
            # membership list.
            next if group_name == "all"
            host = inventory.hosts[member.as_s?]?
            group.add_host(host) if host
          end

          group_def["children"]?.try(&.as_a?).try &.each do |child|
            group.add_child(child.as_s)
          end
        end
      end

      # Group vars belong to the group, not to its members, in Ansible:
      # they are merged into a host's vars lazily when the host is used.
      # krikri bakes that merge in at parse time for every inventory
      # format, so a plugin-created group's vars have to reach its hosts
      # (and its children's hosts) here too.
      InventoryParser.apply_group_vars(inventory)

      inventory
    end

    private def run_wrapper(payload) : JSON::Any?
      captured = ControllerPython.run_wrapper(python_executable, WRAPPER, payload.to_json)
      return nil unless captured
      return nil unless captured[:status].success?

      # A plugin that prints its own diagnostics must not corrupt the
      # protocol, so only the LAST non-blank line is the response.
      line = captured[:stdout].lines.reject(&.blank?).last?
      return nil unless line

      parsed = (Krikri::BigJson.parse(line) rescue nil)
      return nil unless parsed && parsed.as_h?
      parsed
    end

    # The controller-side wrapper: imports the plugin file, finds its
    # `InventoryModule` class (which must subclass the real
    # `ansible.plugins.inventory.BaseInventoryPlugin`, the same check
    # Ansible's loader makes), registers the plugin's DOCUMENTATION
    # options with ansible's config manager (without which the very
    # common `self.set_options()`/`self._read_config_data(path)` idiom
    # raises KeyError), then runs `verify_file` and `parse` against a
    # real InventoryData with a real DataLoader - the objects Ansible's
    # own InventoryManager would hand the plugin. Hosts, their vars,
    # groups, group children and group vars are printed back as one JSON
    # object.
    #
    # `inventory.current_source` is set the way InventoryManager sets it,
    # so a plugin's hosts carry the same `inventory_file`/`inventory_dir`
    # vars ansible-playbook gives them, and `reconcile_inventory()` runs
    # afterwards so a host the plugin never added to a group lands in
    # `ungrouped` and every group parents onto `all` exactly as it would
    # have there.
    WRAPPER = <<-PYTHON
      import importlib.util
      import json
      import os
      import sys


      _unavailable = None
      try:
          from ansible.inventory.data import InventoryData
          from ansible.parsing.dataloader import DataLoader
          from ansible.plugins.inventory import BaseInventoryPlugin
      except Exception as exc:
          _unavailable = "%s: %s" % (type(exc).__name__, exc)


      def _load_plugin(path):
          modname = "krikri_inventory_%d" % hash(path)
          spec = importlib.util.spec_from_file_location(modname, path)
          if spec is None or spec.loader is None:
              raise ImportError("cannot load inventory plugin: %s" % path)
          module = importlib.util.module_from_spec(spec)
          spec.loader.exec_module(module)
          return module


      def _register_config(module, name):
          doc = getattr(module, "DOCUMENTATION", None)
          if not doc:
              return
          try:
              import yaml
              from ansible import constants as C
              from ansible.parsing.yaml.loader import AnsibleLoader
              parsed = yaml.load(doc, Loader=AnsibleLoader)
              if isinstance(parsed, dict) and isinstance(parsed.get("options"), dict):
                  C.config.initialize_plugin_configuration_definitions(
                      "inventory", name, parsed["options"])
          except Exception:
              pass


      def _vars(values):
          return {str(key): value for key, value in values.items()}


      def _serialize(value):
          return str(value)


      def main():
          payload = json.loads(sys.stdin.read())
          if _unavailable is not None:
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "unavailable",
                   "error": "ansible is not importable by the controller python3: %s"
                            % _unavailable}))
              return

          path = payload.get("path")
          try:
              module = _load_plugin(path)
          except Exception as exc:
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "load", "error": "%s" % exc}))
              return

          plugin_class = getattr(module, "InventoryModule", None)
          if plugin_class is None or not isinstance(plugin_class, type) or \\
                  not issubclass(plugin_class, BaseInventoryPlugin):
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "not_found",
                   "error": "no InventoryModule subclass of BaseInventoryPlugin in %s"
                            % path}))
              return

          name = payload.get("name") or os.path.basename(path).rsplit(".", 1)[0]
          source = payload.get("source")

          _register_config(module, name)
          plugin = plugin_class()
          plugin._load_name = name
          loader = DataLoader()

          if not plugin.verify_file(source):
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "verify",
                   "error": "inventory source '%s' could not be verified by inventory plugin '%s'"
                            % (source, name)}))
              return

          inventory = InventoryData()
          inventory.current_source = source
          plugin.parse(inventory, loader, source, cache=True)
          inventory.reconcile_inventory()

          hosts = {host.name: _vars(host.vars) for host in inventory.hosts.values()}
          groups = {}
          for group in inventory.groups.values():
              groups[group.name] = {
                  "hosts": [host.name for host in group.hosts],
                  "children": [child.name for child in group.child_groups],
                  "vars": _vars(group.vars),
              }

          sys.stdout.write(json.dumps(
              {"ok": True, "hosts": hosts, "groups": groups},
              default=_serialize))


      try:
          main()
      # BaseException, not Exception: a plugin's `sys.exit()` raises
      # SystemExit, which would otherwise kill the wrapper before any
      # JSON response.
      except BaseException as exc:
          sys.stdout.write(json.dumps(
              {"ok": False, "kind": "error", "error": "%s" % exc}))
      PYTHON
  end
end
