require "file_utils"
require "../minitest_helper"

# Runs the compiled binary against a real role tree: the bug is in the
# controller-side python filter-plugin search (PythonFilterRunner.
# find_sources via RoleLoader.load_role's registry), not reachable from
# a unit spec.
#
# Real bug found in round 5250000 (nephelaiio.i3): the role's own
# `set_fact: _i3_packages: "{{ i3_packages | default(i3_packages_default
# | sorted_get(overrides)) }}"` failed with "No filter named
# 'sorted_get'." even though the filter ships in the role's meta
# DEPENDENCY (nephelaiio.plugins/filter_plugins/custom_filters.py).
# ansible-core calls add_all_plugin_dirs(role_path) at Role.load for
# every legacy role - play roles, meta dependencies, include_role: - so
# a dependency's filters stay reachable from every later task even when
# the depending role ships no plugins of its own. Verified against
# ansible-playbook 2.19.11 before being encoded here.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "filters from a meta dependency role (dependency_role_filter_test.cr)" do
  it "resolves a filter shipped by a meta dependency role" do
    run_dependency_filter[:output].must_include("xorg")
  end

  it "matches real's precedence: a dependency's filter wins over the current role's own" do
    ctx = run_dependency_filter(with_own_override: true)
    ctx[:output].must_include("xorg")
  end

  private def run_dependency_filter(with_own_override : Bool = false) : Hash(Symbol, String)
    dir = PluginSpecHelper.tmp_path("dep-role-filter", Random::Secure.hex(4))
    FileUtils.mkdir_p(File.join(dir, "roles", "main1", "meta"))
    FileUtils.mkdir_p(File.join(dir, "roles", "main1", "tasks"))
    FileUtils.mkdir_p(File.join(dir, "roles", "main1", "defaults"))
    FileUtils.mkdir_p(File.join(dir, "roles", "main1", "filter_plugins"))
    FileUtils.mkdir_p(File.join(dir, "roles", "deprole", "filter_plugins"))

    File.write(File.join(dir, "roles", "deprole", "filter_plugins", "custom_filters.py"), <<-PY)
      class FilterModule(object):
          def filters(self):
              return {"sorted_get": sorted_get}

      def sorted_get(d, ks):
          for k in ks:
              if k in d:
                  return d[k]
          raise KeyError("None of {} keys found".format(ks))
      PY
    if with_own_override
      File.write(File.join(dir, "roles", "main1", "filter_plugins", "override.py"), <<-PY)
        class FilterModule(object):
            def filters(self):
                return {"sorted_get": sorted_get}

        def sorted_get(d, ks):
            return ["from-main1"]
        PY
    end
    File.write(File.join(dir, "roles", "main1", "meta", "main.yml"),
      "dependencies:\n  - role: deprole\n")
    File.write(File.join(dir, "roles", "main1", "defaults", "main.yml"),
      "i3_packages_default:\n  ubuntu: [xorg, i3]\noverrides: [ubuntu]\n")
    File.write(File.join(dir, "roles", "main1", "tasks", "main.yml"),
      <<-YAML
      - set_fact:
          _packages: "{{ i3_packages | default(i3_packages_default | sorted_get(overrides)) }}"
      - debug:
          msg: "{{ _packages }}"
      YAML
    )
    File.write(File.join(dir, "site.yml"),
      <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - main1
      YAML
    )

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, File.join(dir, "site.yml")], output: output, error: output)
    {:output => output.to_s, :dir => dir}
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
