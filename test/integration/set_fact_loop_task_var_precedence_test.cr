require "../minitest_helper"
require "file_utils"

# Real-Ansible parity: a set_fact outranks a task's own `vars:` of the
# same name. Inside a loop this engine re-applies the task's raw vars:
# text per item (so a value referencing `item` renders against that
# iteration), and that re-apply used to clobber an accumulated set_fact
# with the task var's seed value - cowops.debian-php-extensions'
# `set_fact: php_packages: "{{ php_packages + [...] }}"` loop
# (`vars: php_packages: []`) then saw only the last item, which decided
# which missing package its apt task reported. Verified against
# ansible-playbook 2.21.6.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "set_fact versus task vars in a loop" do
  it "accumulates across items although the task seeds the name in vars:" do
    dir = PluginSpecHelper.tmp_path("setfact-taskvar-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(dir)
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: accumulate
            set_fact:
              pkgs: "{{ pkgs + [ 'php7.0-' + item ] }}"
            loop:
              - curl
              - dbg
              - redis
            vars:
              pkgs: []

          - name: read it back outside the loop
            debug:
              var: pkgs

          - name: read it back in a loop with the same shadowing task var
            debug:
              msg: "{{ pkgs | join(',') }}"
            loop:
              - ignored
            vars:
              pkgs: []
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: output, error: output)
    captured = output.to_s

    status.success?.must_equal(true, captured)
    captured.must_include(%("pkgs": [\n        "php7.0-curl",\n        "php7.0-dbg",\n        "php7.0-redis"\n    ]), captured)
    captured.must_include(%("msg": "php7.0-curl,php7.0-dbg,php7.0-redis"), captured)
  end
end
