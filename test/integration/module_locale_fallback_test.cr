require "../minitest_helper"

# AnsibleModule#_check_locale: when the module process's LANG names a
# locale that cannot be set (exported by ssh's SendEnv, never generated on
# the target), ansible exports a usable one as LANG, LC_ALL and
# LC_MESSAGES to every command/shell child - otherwise perl/pecl print
# "Setting locale failed" noise real ansible's output lacks (ecgalaxy.php,
# issue #488). A locale that does work is left alone.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_locale_playbook(lang : String)
  playbook = File.tempname("module-locale-fallback", ".yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      environment:
        LANG: #{lang}
      tasks:
        - shell: echo "[$LANG|$LC_ALL|$LC_MESSAGES]"
          register: sh
        - command: env
          register: cmd
        - debug:
            msg: "shell={{ sh.stdout }} command={{ cmd.stdout_lines | select('match', '^(LANG|LC_ALL|LC_MESSAGES)=') | sort | join(',') }}"
    YAML
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  output.to_s
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "module locale fallback for command and shell" do
  it "rewrites an uninstalled LANG to a usable locale for both modules" do
    output = run_locale_playbook("zz_ZZ.UTF-8")
    output.wont_include("zz_ZZ")
    output.must_match(/shell=\[(C\.[Uu][Tt][Ff]-?8|en_US\.[Uu][Tt][Ff]-?8|C|POSIX)\|\1\|\1\]/)
    output.must_match(/command=LANG=(\S+?),LC_ALL=\1,LC_MESSAGES=\1/)
  end

  it "leaves an installed locale untouched" do
    output = run_locale_playbook("C")
    output.must_include("shell=[C||]")
    output.wont_include("LC_ALL=")
  end
end
