require "../minitest_helper"
require "file_utils"

# ansible.cfg is a first-class config source: ansible-playbook reads the
# settings in it, but krikri used to locate the file only for its `-v`
# banner and drop every value inside (issue #1478). A project whose
# inventory, roles_path or library lived in `./ansible.cfg` therefore ran
# against the implicit localhost / reported "not found" while the same
# setting passed as an env var or CLI flag worked. Each case below is the
# issue's own repro, with the child process started in the ansible.cfg
# directory and every other ANSIBLE_* variable cleared.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def write_cfg_tree(files : Hash(String, String)) : String
  dir = PluginSpecHelper.tmp_path("ansible-cfg-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  files.each do |relative, content|
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
  dir
end

private def run_with_cfg(dir : String, args : Array(String)) : {Process::Status, String}
  output = IO::Memory.new
  env = {
    "HOME"            => dir,
    "PATH"            => ENV["PATH"]? || "/usr/local/bin:/usr/bin:/bin",
    "LANG"            => "C.UTF-8",
    "LC_ALL"          => "C.UTF-8",
    "ANSIBLE_NOCOLOR" => "1",
  }
  status = Process.run(BINARY, args, output: output, error: output, chdir: dir, env: env, clear_env: true)
  {status, output.to_s}
end

private INVENTORY_LOCAL = "[all]\nhost1 ansible_connection=local\n"

describe "ansible.cfg settings" do
  it "reads [defaults] inventory with no -i and uses it for the play" do
    dir = write_cfg_tree({
      "ansible.cfg" => "[defaults]\ninventory = ./inv.ini\n",
      "inv.ini"     => INVENTORY_LOCAL,
      "play.yml"    => <<-YAML,
        - hosts: all
          gather_facts: false
          tasks:
            - ansible.builtin.debug: {msg: cfg-inventory}
        YAML
    })

    status, output = run_with_cfg(dir, ["play.yml"])

    status.success?.must_equal(true, output)
    output.must_include("ok: [host1]")
    output.must_include("cfg-inventory")
    output.wont_include("No inventory was parsed")
  end

  it "lets -i outrank [defaults] inventory" do
    dir = write_cfg_tree({
      "ansible.cfg" => "[defaults]\ninventory = ./missing.ini\n",
      "inv.ini"     => INVENTORY_LOCAL,
      "play.yml"    => <<-YAML,
        - hosts: all
          gather_facts: false
          tasks:
            - ansible.builtin.debug: {msg: cli-inventory}
        YAML
    })

    status, output = run_with_cfg(dir, ["-vvv", "-i", "inv.ini", "play.yml"])

    status.success?.must_equal(true, output)
    output.must_include("Parsed #{File.join(dir, "inv.ini")} inventory source")
    output.wont_include("missing.ini")
  end

  it "reads [defaults] roles_path and finds a role installed there" do
    dir = write_cfg_tree({
      "ansible.cfg"                  => "[defaults]\ninventory = ./inv.ini\nroles_path = ./myroles\n",
      "inv.ini"                      => INVENTORY_LOCAL,
      "myroles/hello/tasks/main.yml" => "- ansible.builtin.debug: {msg: role-hello}\n",
      "play.yml"                     => <<-YAML,
      - hosts: all
        gather_facts: false
        roles: [hello]
      YAML
    })

    status, output = run_with_cfg(dir, ["play.yml"])

    status.success?.must_equal(true, output)
    output.must_include("role-hello")
  end

  it "reads [defaults] library and runs a module found there" do
    dir = write_cfg_tree({
      "ansible.cfg"      => "[defaults]\ninventory = ./inv.ini\nlibrary = ./library\n",
      "inv.ini"          => INVENTORY_LOCAL,
      "library/mymod.py" => <<-PYTHON,
        #!/usr/bin/python
        import json
        print(json.dumps({"changed": False, "msg": "custom-module-ran"}))
        PYTHON
      "play.yml" => <<-YAML,
        - hosts: host1
          gather_facts: false
          tasks:
            - name: run custom module
              mymod:
        YAML
    })

    status, output = run_with_cfg(dir, ["-v", "play.yml"])

    status.success?.must_equal(true, output)
    output.must_include("custom-module-ran")
  end
end
