require "file_utils"
require "../minitest_helper"

# Runs the compiled binary: container repr in the TASK banner is a
# display-only concern of the name-rendering path
# (render_task_name_for_display), not reachable from a unit spec on
# VarSubstitutor alone.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# Issue #86: a task name built from a container renders as JSON in the
# `TASK [...]` banner, but real ansible-core 2.19.11 renders Python repr
# there (`install ['ntp']`, `dict {'a': 1, 'b': ['x', 'y']}`), because the
# banner is a final user-facing rendering. All banner sites (TASK,
# RUNNING HANDLER, block/include names) go through the same name
# renderer, so pinning the plain TASK banner covers the class.
describe "container vars in a TASK banner render as Python repr" do
  it "renders list and dict name vars as repr, not JSON" do
    src_dir = File.tempname("task-name-repr")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ntp_packages: ['ntp']
          d: {a: 1, b: [x, y]}
          s: str
          t: True
          # a lazily-templated var: its own value is a {{ }} string that
          # renders to a list (tehtbl.ntp's real ntp_packages shape,
          # including a default() chain), unlike the plain YAML list above
          other: "{{ _pk[fam] }}"
          ntp_packages: "{{ _pk[fam ~ '-1'] | default(_pk[fam] | default(_pk['default'])) }}"
          _pk:
            Debian: ['ntp']
            default: ['x']
          fam: Debian
        tasks:
          - name: install {{ ntp_packages }}
            ansible.builtin.debug:
              msg: hi
          - name: dict {{ d }}
            ansible.builtin.debug:
              msg: hi
          - name: other {{ other }}
            ansible.builtin.debug:
              msg: hi
          - name: mix {{ [s, t, 1.5] }}
            ansible.builtin.debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    out = output.to_s
    out.must_include("TASK [install ['ntp']]")
    out.must_include("TASK [dict {'a': 1, 'b': ['x', 'y']}]")
    out.must_include("TASK [mix ['str', True, 1.5]]")
    out.must_include("TASK [other ['ntp']]")
    out.wont_include("TASK [install [\"ntp\"]]")
    out.wont_include("TASK [dict {\"a\":1")
    out.wont_include("TASK [other [\"ntp\"]]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
