require "../spec_helper"

# Runs the compiled binary against a real playbook (real template
# rendering), since this bug is in the vendored Crinja fork's
# Value#compare (lib/crinja/src/runtime/value.cr), reached only through
# a real {% for %} + sort filter template render.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "sorting a dict's .items() (a list of 2-tuples) in a template" do
  it "sorts lexicographically by key instead of raising 'cannot compare'" do
    # Real bug found benchmarking Oefenweb.bash's own .bash_aliases.j2:
    # `{% for key, value in bash_aliases.items() | sort %}`. Value#compare
    # had cases for Array/Bool/Number/String but none for Crinja::Tuple -
    # a tuple-vs-tuple comparison (needed to sort a list of 2-tuples)
    # fell through to the generic "cannot compare X with Y" error even
    # though Crinja::Tuple already implements element-wise `<=>` via its
    # own `delegate :<=>, to: @data` - Value#compare just never routed a
    # Tuple pair into it.
    src = File.tempname("tuple-sort-src", ".j2")
    dest = File.tempname("tuple-sort-dest")
    playbook = File.tempname("tuple-sort", ".yml")
    File.write(src, <<-J2)
      {% for key, value in bash_aliases.items() | sort %}
      alias {{ key }}='{{ value }}'
      {% endfor %}
      J2

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          bash_aliases:
            ll: "ls -la"
            la: "ls -A"
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should_not contain("cannot compare")
    rendered = File.read(dest)
    if la_index = rendered.index("alias la=")
      if ll_index = rendered.index("alias ll=")
        la_index.should be < ll_index
      else
        fail("expected to find 'alias ll=' in rendered output: #{rendered}")
      end
    else
      fail("expected to find 'alias la=' in rendered output: #{rendered}")
    end
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
