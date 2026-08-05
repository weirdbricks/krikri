#!/usr/bin/env crystal

# Ansible compatibility harness.
#
# For each playbook under compat/playbooks/*.yml, runs it once via real
# `ansible-playbook` and once via `bin/crystal-ansible`, each in its own
# fresh, throwaway container (built from compat/Dockerfile - ansible-core
# and a from-source crystal-ansible build side by side), then compares:
#   - success/failure (exit code 0 vs nonzero)
#   - the final state of /work (a checksum+type snapshot of every file and
#     directory the playbook touched)
#
# Raw stdout is NOT diffed directly - the two tools format output very
# differently, so that would just be noise. The filesystem snapshot is the
# actual signal: if both tools end up in the same state, they behaved the
# same way, regardless of how they logged getting there.
#
# Usage: crystal run compat/run.cr

require "process"
require "set"

module Compat
  PROJECT_ROOT   = File.expand_path("..", __DIR__)
  IMAGE          = "crystal-ansible-compat"
  PLAYBOOKS_DIR  = File.join(PROJECT_ROOT, "compat", "playbooks")
  INVENTORY_PATH = "/repo/compat/inventory.ini"

  # Lists every file (with an md5 checksum) and directory under /work,
  # relative to /work, one per line: "F path checksum" or "D path".
  # .git directories are excluded: both engines shell out to the same git
  # binary, so their internals are implementation plumbing, not behavior -
  # comparing them would just add noise (refspec formatting, etc).
  # Also reports getent state for the fixed account/group names the
  # user/group compat playbook uses (05-user-group.yml) - that state lives
  # outside /work, in the system passwd/group databases.
  SNAPSHOT_SCRIPT = <<-SH
    find /work -mindepth 1 -not -path '*/.git*' | sort | while read -r p; do
      rel=${p#/work/}
      if [ -f "$p" ]; then
        echo "F $rel $(md5sum < "$p" | cut -d' ' -f1)"
      elif [ -d "$p" ]; then
        echo "D $rel"
      fi
    done
    getent passwd compatuser 2>/dev/null | sed 's/^/PASSWD /'
    getent group compatgroup 2>/dev/null | sed 's/^/GROUP /'
    SH

  record Snapshot, exit_code : Int32, output : String, files : String
  record Result, playbook : String, ok : Bool, detail : String

  def self.run(args : Array(String)) : {Int32, String}
    output = IO::Memory.new
    status = Process.run(args[0], args[1..], output: output, error: output)
    {status.exit_code, output.to_s}
  end

  def self.build_image : Bool
    puts "Building compat image (rebuilds crystal-ansible from source - may take a few minutes)..."
    code, output = run(["docker", "build", "-q", "-t", IMAGE, "-f", File.join(PROJECT_ROOT, "compat", "Dockerfile"), PROJECT_ROOT])
    puts output unless code == 0
    code == 0
  end

  # Runs `engine_args + [-i, inventory, playbook_path]` inside a fresh
  # throwaway container, then snapshots the resulting /work.
  def self.run_playbook(engine_args : Array(String), playbook_path : String) : Snapshot
    container = "compat-#{Random::Secure.hex(6)}"

    start_code, start_output = run(["docker", "run", "-d", "--rm", "--name", container, IMAGE, "sleep", "300"])
    raise "failed to start compat container: #{start_output}" unless start_code == 0

    begin
      exec_code, exec_output = run(["docker", "exec", container] + engine_args + ["-i", INVENTORY_PATH, playbook_path])
      _, files_output = run(["docker", "exec", container, "sh", "-c", SNAPSHOT_SCRIPT])

      Snapshot.new(exec_code, exec_output, files_output)
    ensure
      run(["docker", "kill", container])
    end
  end

  # 16-vault.yml is itself vault-encrypted, and 17-vault-inline.yml has an
  # inline `!vault`-tagged variable value - both need
  # --vault-password-file (compat/vault_pass.txt) to read/decrypt.
  VAULT_EXTRA_ARGS = ["--vault-password-file", "/repo/compat/vault_pass.txt"]
  VAULT_PLAYBOOKS  = {"16-vault.yml", "17-vault-inline.yml"}

  # Podman's default (network-less) `docker run` gives a container no
  # inspectable IP at all (empty .NetworkSettings.Networks) under this
  # harness's rootless setup - a real user-defined bridge network (via
  # netavark) is what actually gives containers routable IPs reachable
  # from a sibling container. Created once, left in place (containers
  # using it are `--rm`; the network itself is negligible and fine to
  # reuse across runs) - `docker network create` on an existing name
  # errors, so this checks first.
  BATCHING_NETWORK = "crystal-ansible-compat-batching"

  def self.ensure_batching_network
    code, _ = run(["docker", "network", "inspect", BATCHING_NETWORK])
    return if code == 0

    create_code, create_out = run(["docker", "network", "create", BATCHING_NETWORK])
    raise "failed to create #{BATCHING_NETWORK} network: #{create_out}" unless create_code == 0
  end

  # item 3 (BATCHING_DESIGN.md, --experimental-batching, 0.9.61) needs a
  # real, separate SSH connection to exercise at all - run_playbook above
  # always uses `docker exec` + ansible_connection=local, which
  # PluginManager.is_local_connection? short-circuits before ever
  # consulting a batch group. Spins up two fresh containers *from this
  # same image* - a "target" (runs its own real sshd) and a "controller"
  # (runs *engine_args* against the target over a real SSH connection,
  # using the keypair compat/Dockerfile bakes into every image built
  # from it) - then snapshots the target's /work, since that's where the
  # playbook actually ran. Only used for BATCHING_PLAYBOOK_NAME below.
  def self.run_playbook_via_ssh(engine_args : Array(String), playbook_path : String) : Snapshot
    ensure_batching_network

    target = "compat-target-#{Random::Secure.hex(6)}"
    controller = "compat-ctrl-#{Random::Secure.hex(6)}"

    t_code, t_out = run(["docker", "run", "-d", "--rm", "--name", target, "--network", BATCHING_NETWORK, IMAGE, "sleep", "300"])
    raise "failed to start compat target container: #{t_out}" unless t_code == 0

    begin
      c_code, c_out = run(["docker", "run", "-d", "--rm", "--name", controller, "--network", BATCHING_NETWORK, IMAGE, "sleep", "300"])
      raise "failed to start compat controller container: #{c_out}" unless c_code == 0

      begin
        sshd_code, sshd_out = run(["docker", "exec", target, "/usr/sbin/sshd"])
        raise "failed to start sshd on compat target: #{sshd_out}" unless sshd_code == 0

        ip_code, ip_out = run(["docker", "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", target])
        raise "failed to inspect compat target IP: #{ip_out}" unless ip_code == 0
        target_ip = ip_out.strip
        raise "compat target container has no IP address" if target_ip.empty?

        inventory = "[bench]\n#{target_ip} ansible_user=root\n"
        inv_code, inv_out = run(["docker", "exec", controller, "sh", "-c", "printf '%s' #{shell_quote(inventory)} > /tmp/batching_inventory.ini"])
        raise "failed to write batching inventory on controller: #{inv_out}" unless inv_code == 0

        exec_code, exec_output = run(["docker", "exec", controller] + engine_args + ["-i", "/tmp/batching_inventory.ini", playbook_path])
        _, files_output = run(["docker", "exec", target, "sh", "-c", SNAPSHOT_SCRIPT])

        Snapshot.new(exec_code, exec_output, files_output)
      ensure
        run(["docker", "kill", controller])
      end
    ensure
      run(["docker", "kill", target])
    end
  end

  private def self.shell_quote(str : String) : String
    "'" + str.gsub("'", "'\\''") + "'"
  end

  def self.compare(playbook_path : String) : Result
    name = File.basename(playbook_path)
    container_path = "/repo/compat/playbooks/#{name}"
    extra_args = VAULT_PLAYBOOKS.includes?(name) ? VAULT_EXTRA_ARGS : [] of String

    ansible = run_playbook(["ansible-playbook"] + extra_args, container_path)
    crystal = run_playbook(["/repo/bin/crystal-ansible"] + extra_args, container_path)

    diff_snapshots(name, ansible, crystal)
  end

  # item 3 (BATCHING_DESIGN.md, --experimental-batching, 0.9.61) -
  # BATCHING_PLAYBOOK_NAME only, driven over a real SSH connection via
  # run_playbook_via_ssh instead of the normal docker-exec/local path -
  # see that method's own comment for why.
  def self.compare_batching(playbook_path : String) : Result
    name = File.basename(playbook_path)
    container_path = "/repo/compat/playbooks/#{name}"

    ansible = run_playbook_via_ssh(["ansible-playbook"], container_path)
    crystal = run_playbook_via_ssh(["/repo/bin/crystal-ansible", "--experimental-batching"], container_path)

    diff_snapshots(name, ansible, crystal)
  end

  private def self.diff_snapshots(name : String, ansible : Snapshot, crystal : Snapshot) : Result
    ansible_ok = ansible.exit_code == 0
    crystal_ok = crystal.exit_code == 0

    unless ansible_ok == crystal_ok
      detail = String.build do |str|
        str << "exit status differs: ansible-playbook "
        str << (ansible_ok ? "succeeded" : "failed (exit #{ansible.exit_code})")
        str << ", crystal-ansible "
        str << (crystal_ok ? "succeeded" : "failed (exit #{crystal.exit_code})")
        str << "\n--- ansible-playbook output ---\n" << ansible.output
        str << "\n--- crystal-ansible output ---\n" << crystal.output
      end
      return Result.new(name, false, detail)
    end

    if ansible.files != crystal.files
      return Result.new(name, false, "final /work state differs:\n#{describe_diff(ansible.files, crystal.files)}")
    end

    Result.new(name, true, "")
  end

  def self.describe_diff(ansible_files : String, crystal_files : String) : String
    ansible_lines = ansible_files.lines.map(&.strip).reject(&.empty?).to_set
    crystal_lines = crystal_files.lines.map(&.strip).reject(&.empty?).to_set

    only_ansible = ansible_lines - crystal_lines
    only_crystal = crystal_lines - ansible_lines

    String.build do |str|
      unless only_ansible.empty?
        str << "  only in ansible-playbook's final state:\n"
        only_ansible.to_a.sort.each { |line| str << "    #{line}\n" }
      end
      unless only_crystal.empty?
        str << "  only in crystal-ansible's final state:\n"
        only_crystal.to_a.sort.each { |line| str << "    #{line}\n" }
      end
    end
  end

  # Excluded from the normal glob loop below - it uses hosts: bench,
  # which only resolves under run_playbook_via_ssh's dynamically
  # generated inventory, not compat/inventory.ini's static
  # `localhost ansible_connection=local`. Run through compare() like
  # everything else, hosts: bench would just match zero hosts and the
  # play would silently no-op for both engines - a false PASS that
  # tests nothing, not a real comparison.
  BATCHING_PLAYBOOK_NAME = "39-batching.yml"
end

all_playbooks = Dir.glob(File.join(Compat::PLAYBOOKS_DIR, "*.yml")).sort
playbooks = all_playbooks.reject { |path| File.basename(path) == Compat::BATCHING_PLAYBOOK_NAME }
batching_playbook = all_playbooks.find { |path| File.basename(path) == Compat::BATCHING_PLAYBOOK_NAME }

abort("Failed to build compat image") unless Compat.build_image

results = playbooks.map { |path| Compat.compare(path) }
if path = batching_playbook
  results << Compat.compare_batching(path)
end

puts ""
puts "=" * 70
puts "Ansible compatibility report"
puts "=" * 70

results.each do |result|
  puts "#{result.ok ? "PASS" : "FAIL"}  #{result.playbook}"
  unless result.detail.empty?
    result.detail.each_line { |line| puts "    #{line}" }
  end
end

failures = results.reject(&.ok)
puts ""
puts "#{results.size - failures.size}/#{results.size} passed"

exit(failures.empty? ? 0 : 1)
