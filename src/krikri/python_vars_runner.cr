require "json"
require "./bigint_json"
require "./controller_python"
require "./inventory_parser"
require "./python_filter_runner"
require "./var_origin"

module Krikri
  # Runner for custom VARS plugins - legacy `.py` files under a
  # playbook-adjacent `vars_plugins/`, `$ANSIBLE_HOME/plugins/vars`,
  # `/usr/share/ansible/plugins/vars`, or the dirs named by
  # `ANSIBLE_VARS_PLUGINS` (which REPLACES the two defaults, exactly like
  # the other ANSIBLE_*_PLUGINS lists). Before this, a `VarsModule`'s
  # `get_vars()` was never called, so every variable it produced was
  # silently undefined (issue #1474).
  #
  # The vars are attached to hosts at inventory-parse time. ansible's
  # default `run_vars_plugins = demand` evaluates inventory-adjacent vars
  # plugins on the first get_vars() of a task, i.e. right before the task
  # sees them; the plugin's signature (`loader, path, entities`) carries
  # no play or task context, so evaluating it once here - after
  # group_vars/host_vars and the inline inventory vars are in place -
  # produces the same entities and the same values, without paying for a
  # python spawn on every task.
  module PythonVarsRunner
    extend self

    # Every custom vars plugin FILE to load, in the order ansible's
    # PluginLoader caches them: extra (playbook-adjacent) dirs first, then
    # the configured dirs. Last-in-cache wins a same-key merge, which is
    # the order the wrapper applies them in.
    def sources(playbook_dir : String?) : Array(String)
      roots = [] of String
      roots << File.join(playbook_dir, "vars_plugins") if playbook_dir && !playbook_dir.empty?
      roots.concat(PythonFilterRunner.configured_roots("vars", "ANSIBLE_VARS_PLUGINS"))

      files = [] of String
      roots.each do |root|
        files.concat(py_sources_in(root)) if Dir.exists?(root)
      end
      files.uniq
    end

    # Runs every sourced plugin against *inventory*'s hosts and groups and
    # merges the results into `host.vars`. `source` is the `-i` value the
    # parse was given (file, dir, host list or dynamic script) - ansible
    # hands the inventory-side plugins the DIRECTORY of each inventory
    # source, and the playbook-side ones the playbook's directory.
    def apply(inventory : Inventory, source : String, playbook_dir : String?) : Nil
      return if inventory.hosts.empty?
      files = sources(playbook_dir)
      return if files.empty?

      inventory_paths = inventory_source_dirs(source)
      play_paths = (playbook_dir && !playbook_dir.empty?) ? [File.expand_path(playbook_dir)] : [] of String
      return if inventory_paths.empty? && play_paths.empty?

      result = run_wrapper(payload(files, inventory_paths, play_paths, inventory, playbook_dir))
      merge(inventory, result)
    end

    # The inventory source's own plugin path - ansible's
    # get_vars_from_inventory_sources skips host lists (`-i
    # web1,web2,`) and passes a source FILE's directory, a source
    # DIRECTORY itself.
    private def inventory_source_dirs(source : String) : Array(String)
      return [] of String if source.includes?(',') && !File.exists?(source)
      return [File.expand_path(source)] if File.directory?(source)
      [File.expand_path(File.dirname(source))]
    end

    private def py_sources_in(root : String) : Array(String)
      sources = [] of String
      Dir.children(root).sort!.each do |entry|
        next unless entry.ends_with?(".py")
        path = File.join(root, entry)
        sources << path if File.file?(path)
      end
      sources
    end

    # ANSIBLE_VARS_ENABLED's default (ansible config `vars_plugins_enabled`)
    # is `host_group_vars`; a plugin that sets REQUIRES_ENABLED only runs
    # when its name is listed there.
    private def enabled_plugin_names : Array(String)
      if custom = ENV["ANSIBLE_VARS_ENABLED"]?
        return custom.split(',').map(&.strip).reject(&.empty?)
      end
      ["host_group_vars"]
    end

    private def payload(files : Array(String), inventory_paths : Array(String),
                        play_paths : Array(String), inventory : Inventory,
                        playbook_dir : String?) : Hash(String, JSON::Any)
      hosts = inventory.hosts.each_value.map do |host|
        JSON::Any.new({
          "name"   => JSON::Any.new(host.name),
          "vars"   => JSON::Any.new(host.vars),
          "groups" => JSON::Any.new(inventory.groups_for(host.name).map { |group| JSON::Any.new(group) }),
        })
      end.to_a

      groups = inventory.groups.each_value.map do |group|
        children = group.children.map { |child| JSON::Any.new(child) }
        JSON::Any.new({
          "name"     => JSON::Any.new(group.name),
          "children" => JSON::Any.new(children),
          "vars"     => JSON::Any.new(group.vars),
        })
      end.to_a

      {
        "plugins" => JSON::Any.new(files.map { |path| JSON::Any.new(path) }),
        "paths"   => JSON::Any.new({
          "inventory" => JSON::Any.new(inventory_paths.map { |path| JSON::Any.new(path) }),
          "play"      => JSON::Any.new(play_paths.map { |path| JSON::Any.new(path) }),
          "basedir"   => JSON::Any.new(playbook_dir ? File.expand_path(playbook_dir) : nil),
        }),
        "enabled" => JSON::Any.new(enabled_plugin_names.map { |name| JSON::Any.new(name) }),
        "hosts"   => JSON::Any.new(hosts),
        "groups"  => JSON::Any.new(groups),
      }
    end

    private def merge(inventory : Inventory, result : JSON::Any?) : Nil
      return unless result
      return emit_failure(result) unless result["ok"]?.try(&.as_bool?)
      emit_skip_warnings(result)

      result["hosts"]?.try(&.as_h?).try do |per_host|
        per_host.each do |host_name, tiers|
          host = inventory.hosts[host_name.to_s]? || next
          merge_host_tiers(host, tiers)
        end
      end
    end

    private def emit_failure(result : JSON::Any) : Nil
      detail = result["error"]?.try(&.as_s?) || "unknown error"
      # A plugin whose get_vars() raised would abort the whole run in
      # ansible ("Unexpected Exception, this is probably a bug: ...");
      # here the inventory loader treats a parse-time exception as an
      # unreadable SOURCE (warns, empty inventory), so a plugin bug would
      # turn into "every host vanished". Warn and keep the hosts instead.
      if path = result["plugin"]?.try(&.as_s?)
        emit_plugin_error(path, detail)
      else
        warning_sink.puts "[WARNING]: Vars plugins were not run: #{detail}"
      end
    end

    private def emit_skip_warnings(result : JSON::Any) : Nil
      skipped = result["skipped"]?.try(&.as_a?) || return
      skipped.each do |entry|
        emit_skip_warning(entry["path"]?.try(&.as_s?) || "custom vars plugin",
          entry["error"]?.try(&.as_s?) || "unknown error")
      end
    end

    # Precedence here is ansible's own, live-verified against 2.21.6:
    # a legacy vars plugin's vars beat both inline inventory vars and
    # group_vars FILE values, while a host_vars file value beats the
    # plugin (host_group_vars runs after the legacy plugins in the
    # task-stage pass). Play vars rank above all of these too; those are
    # merged by the executor, which is why nothing here knows about them.
    private def merge_host_tiers(host : Host, tiers : JSON::Any) : Nil
      if group_tier = tiers["groups"]?.try(&.as_h?)
        group_tier.each { |key, value| merge_plugin_var(host, key.to_s, value) }
      end
      if host_tier = tiers["host"]?.try(&.as_h?)
        host_tier.each { |key, value| merge_plugin_var(host, key.to_s, value, sync_connection_vars: true) }
      end
    end

    private def merge_plugin_var(host : Host, key : String, value : JSON::Any,
                                 sync_connection_vars : Bool = false) : Nil
      return if host_vars_file_var?(host.var_origins[key]?)
      host.vars[key] = value
      host.var_origins.delete(key)
      return unless sync_connection_vars
      case key
      when "ansible_user"
        host.user = value.as_s? || host.user
      when "ansible_port"
        host.port = value.as_i? || value.as_s?.try(&.to_i?) || host.port
      end
    end

    # Whether *origin* points into a host_vars tree, i.e. the key was
    # loaded by the builtin host_group_vars plugin equivalent. Only a
    # HOST_VARS file outranks a legacy vars plugin (a group_vars file does
    # not) - live-verified against 2.21.6.
    private def host_vars_file_var?(origin : VarOrigin?) : Bool
      origin.is_a?(FileVarOrigin) && origin.path.includes?("/host_vars/")
    end

    # Where the plugin-load warnings go - STDERR in production,
    # replaceable so a spec can capture the text without touching the
    # process's STDERR. Same wording as the other plugin runners.
    class_property warning_sink : IO = STDERR

    private def emit_skip_warning(path : String, error : String) : Nil
      warning_sink.puts "[WARNING]: Skipping plugin (#{File.expand_path(path)}), cannot load: #{error}"
    end

    private def emit_plugin_error(path : String, error : String) : Nil
      warning_sink.puts "[WARNING]: Vars plugin (#{File.expand_path(path)}) failed: #{error}"
    end

    private def run_wrapper(payload : Hash(String, JSON::Any)) : JSON::Any?
      captured = ControllerPython.run_wrapper(ControllerPython.executable, WRAPPER,
        Krikri.unquote_bigint_json(payload.to_json))
      return nil unless captured
      return nil unless captured[:status].success?
      # A plugin is free to print during get_vars(), so only the last
      # parseable stdout line is the wrapper's answer.
      captured[:stdout].lines.reverse_each do |line|
        next if line.blank?
        parsed = (Krikri::BigJson.parse(line) rescue nil)
        return parsed if parsed && parsed.as_h?
      end
      nil
    rescue SpawnError
      nil
    end

    # The controller-side wrapper: imports each candidate plugin file
    # (reporting unloadable files in "skipped", the way ansible warns and
    # keeps loading the rest), builds ansible's own Host/Group objects for
    # the inventory, then replays VariableManager.get_vars' vars-plugin
    # precedence per host and prints one JSON line.
    WRAPPER = <<-PYTHON
      import importlib.util
      import json
      import os
      import sys


      _unavailable = None
      try:
          from ansible.inventory.host import Host
          from ansible.inventory.group import Group
          from ansible.inventory.helpers import sort_groups
          from ansible.parsing.dataloader import DataLoader
          from ansible.plugins.vars import BaseVarsPlugin
          from ansible.utils.vars import combine_vars
      except Exception as exc:
          _unavailable = "%s: %s" % (type(exc).__name__, exc)


      _loaded = 0


      def _serialize(value):
          if isinstance(value, (set, frozenset)):
              return list(value)
          if isinstance(value, bytes):
              return value.decode("utf-8", "replace")
          return str(value)


      def _respond(body):
          sys.stdout.write(json.dumps(body, default=_serialize))


      def _load_plugin(path):
          global _loaded
          modname = "krikri_vars_%d" % _loaded
          _loaded += 1
          spec = importlib.util.spec_from_file_location(modname, path)
          if spec is None or spec.loader is None:
              raise ImportError("cannot load vars plugin: %s" % path)
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
                  C.config.initialize_plugin_configuration_definitions("vars", name, parsed["options"])
          except Exception:
              pass


      def _instantiate(module, plugin_class, name):
          _register_config(module, name)
          instance = plugin_class()
          instance._load_name = name
          return instance


      def _build_entities(payload):
          groups = {}
          specs = payload.get("groups") or []
          for spec in specs:
              group = Group(spec["name"])
              group.vars = spec.get("vars") or {}
              groups[spec["name"]] = group
              # Group.__init__ sanitizes a name (dashes become underscores),
              # so keep the inventory's own spelling resolvable too.
              groups.setdefault(group.name, group)
          for spec in specs:
              group = groups[spec["name"]]
              for child_name in spec.get("children") or []:
                  child = groups.get(child_name)
                  if child is not None and child is not group:
                      try:
                          group.add_child_group(child)
                      except Exception:
                          pass
          hosts = {}
          host_specs = payload.get("hosts") or []
          for spec in host_specs:
              host = Host(spec["name"])
              host.vars = spec.get("vars") or {}
              hosts[spec["name"]] = host
          all_group = groups.get("all")
          for spec in host_specs:
              host = hosts[spec["name"]]
              for group_name in spec.get("groups") or []:
                  group = groups.get(group_name)
                  if group is not None:
                      group.add_host(host)
              if all_group is not None:
                  all_group.add_host(host)
          if all_group is not None:
              for name, group in groups.items():
                  if name != "all" and not group.parent_groups:
                      try:
                          all_group.add_child_group(group)
                      except Exception:
                          pass
          return hosts, groups


      def _entity_vars(loader, plugins, paths, entities):
          data = {}
          for path in paths:
              for plugin_path, plugin in plugins:
                  try:
                      new_vars = plugin.get_vars(loader, path, entities)
                  except BaseException as exc:
                      raise RuntimeError("%s|%s" % (plugin_path, exc))
                  if new_vars:
                      data = combine_vars(data, new_vars)
          return data


      def main():
          payload = json.loads(sys.stdin.read())
          if _unavailable is not None:
              _respond({"ok": False, "kind": "unavailable",
                        "error": "ansible is not importable by the controller python3: %s" % _unavailable})
              return
          enabled = set(payload.get("enabled") or [])
          plugins = []
          skipped = []
          for path in payload.get("plugins") or []:
              name = os.path.basename(path).rsplit(".", 1)[0]
              # krikri's inventory parser already applies group_vars/host_vars
              # natively (vault decryption included); running ansible's own
              # host_group_vars here would apply them a second time.
              if name == "host_group_vars":
                  continue
              try:
                  module = _load_plugin(path)
              except BaseException as exc:
                  skipped.append({"path": path, "error": "%s" % exc})
                  continue
              plugin_class = getattr(module, "VarsModule", None)
              if plugin_class is None or not isinstance(plugin_class, type):
                  continue
              try:
                  if not issubclass(plugin_class, BaseVarsPlugin):
                      continue
              except TypeError:
                  continue
              if getattr(plugin_class, "REQUIRES_ENABLED", False) and name not in enabled:
                  continue
              try:
                  plugin = _instantiate(module, plugin_class, name)
              except BaseException as exc:
                  skipped.append({"path": path, "error": "%s" % exc})
                  continue
              plugins.append((path, plugin))
          paths = payload.get("paths") or {}
          inventory_paths = paths.get("inventory") or []
          play_paths = paths.get("play") or []
          if not plugins or not (inventory_paths or play_paths):
              _respond({"ok": True, "skipped": skipped, "hosts": {}})
              return
          loader = DataLoader()
          if paths.get("basedir"):
              try:
                  loader.set_basedir(paths["basedir"])
              except Exception:
                  pass
          hosts, groups = _build_entities(payload)
          all_group = groups.get("all")
          result = {}
          try:
              for host_name, host in hosts.items():
                  host_groups = []
                  if all_group is not None:
                      host_groups = [g for g in host.get_groups() if g.name != "all"]
                  host_groups = sort_groups(host_groups)
                  group_data = {}
                  if all_group is not None:
                      group_data = combine_vars(group_data, _entity_vars(loader, plugins, inventory_paths, [all_group]))
                      group_data = combine_vars(group_data, _entity_vars(loader, plugins, play_paths, [all_group]))
                  if host_groups:
                      group_data = combine_vars(group_data, _entity_vars(loader, plugins, inventory_paths, host_groups))
                      group_data = combine_vars(group_data, _entity_vars(loader, plugins, play_paths, host_groups))
                  host_data = _entity_vars(loader, plugins, inventory_paths, [host])
                  host_data = combine_vars(host_data, _entity_vars(loader, plugins, play_paths, [host]))
                  result[host_name] = {"groups": group_data, "host": host_data}
          except RuntimeError as exc:
              plugin_path, _, detail = str(exc).partition("|")
              _respond({"ok": False, "kind": "error", "plugin": plugin_path,
                        "error": detail or str(exc)})
              return
          _respond({"ok": True, "skipped": skipped, "hosts": result})


      try:
          main()
      except BaseException as exc:
          _respond({"ok": False, "kind": "error", "error": "%s" % exc})
      PYTHON
  end
end
