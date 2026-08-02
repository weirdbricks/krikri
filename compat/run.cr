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

  def self.compare(playbook_path : String) : Result
    name = File.basename(playbook_path)
    container_path = "/repo/compat/playbooks/#{name}"
    extra_args = VAULT_PLAYBOOKS.includes?(name) ? VAULT_EXTRA_ARGS : [] of String

    ansible = run_playbook(["ansible-playbook"] + extra_args, container_path)
    crystal = run_playbook(["/repo/bin/crystal-ansible"] + extra_args, container_path)

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
end

playbooks = Dir.glob(File.join(Compat::PLAYBOOKS_DIR, "*.yml")).sort

abort("Failed to build compat image") unless Compat.build_image

results = playbooks.map { |path| Compat.compare(path) }

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
