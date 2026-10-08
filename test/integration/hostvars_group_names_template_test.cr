require "../minitest_helper"

# Regression spec for the per-host magic variables on EVERY hostvars
# entry. The add_host path carried the full play-magic set
# (inventory_hostname_short, group_names, groups, ...) but ordinary
# inventory hosts relied on HostvarsContext's reading-host fallback -
# which only exists for the hand-rolled evaluators. The Jinja template
# path turns each hostvars entry into a plain dict, so
# `hostvars[inventory_hostname].group_names[0]` died with
# "object of type 'dict' has no attribute 'group_names'"
# (bilalcaliskan.redis's redis.conf.j2, round 5210000: real rendered
# the template and ran on, krikri failed the task).
#
# Live-verified against ansible-core 2.19.11: `hostvars[h].group_names`
# is the host's own group list (parents included, sorted).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_with_inventory(inventory : String, playbook : String)
  inv_file = File.tempname("gn-inv", ".ini")
  File.write(inv_file, inventory)
  play_file = File.tempname("gn-play", ".yml")
  File.write(play_file, playbook)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inv_file, play_file], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(inv_file) if inv_file && File.exists?(inv_file)
  File.delete(play_file) if play_file && File.exists?(play_file)
end

describe "hostvars entry group_names" do
  it "renders the host's own groups through the template path" do
    out_path = PluginSpecHelper.tmp_path("gn-out.txt")
    status, output = run_with_inventory(
      "[webservers]\nmyhost ansible_connection=local\n",
      <<-YAML
        - hosts: webservers
          connection: local
          gather_facts: false
          tasks:
            - template:
                src: #{__DIR__}/../fixtures/group_names_tmpl.j2
                dest: #{out_path}
        YAML
    )

    status.exit_code.must_equal(0)
    File.read(out_path).chomp.must_equal("gn=['webservers']")
  end
end
