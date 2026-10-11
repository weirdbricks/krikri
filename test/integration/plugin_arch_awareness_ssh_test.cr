require "../minitest_helper"
require "file_utils"
require "../../src/krikri/plugin_manager"

# Issue #1 (arch awareness) end to end over a REAL ssh target: the arch
# probe folded into upload round trip 1, the plugins-<arch>/ upload, and
# the early actionable failure when no per-arch build exists.
#
# krikri's modules are compiled binaries, so a genuine foreign-arch EXEC
# needs a target kernel of that arch (real hardware, or qemu-user-static
# + binfmt_misc). When neither is available on the box running the suite,
# this spec still verifies the full controller-side MECHANISM against a
# same-kernel sshd that merely REPORTS a foreign arch: a `/usr/local/bin/
# uname` shim on the target (echoing `aarch64`) stands in for the real
# CPU - the probe, the per-arch selection, the upload, the remote md5,
# and the exec path are all real; only the emulated CPU is not.
#
# One throwaway sshd (adjust key/port to match):
#
#   ssh-keygen -t ed25519 -N '' -f /tmp/kkt-key
#   podman run -d --name kkt-archd -p 127.0.0.1:2225:22 ubuntu:22.04 \
#     sh -c 'while :; do sleep 3600; done'
#   podman exec kkt-archd bash -c 'apt-get update \
#     && apt-get install -y openssh-server libyaml-0-2 \
#     && mkdir -p /root/.ssh && chmod 700 /root/.ssh \
#     && echo "MaxAuthTries 30" >> /etc/ssh/sshd_config'
#   podman cp /tmp/kkt-key.pub kkt-archd:/root/.ssh/authorized_keys
#   podman exec kkt-archd ssh-keygen -A
#   podman exec kkt-archd mkdir -p /run/sshd
#   podman exec -d kkt-archd /usr/sbin/sshd -D
#   # the foreign-arch shim:
#   podman exec kkt-archd sh -c \
#     'printf "#!/bin/sh\necho aarch64\n" > /usr/local/bin/uname \
#      && chmod 755 /usr/local/bin/uname'
#
# The same shape runs against any sshd reachable at
# KRIKRI_TEST_ARCH_SSHD_HOST/PORT with KRIKRI_TEST_ARCH_SSHD_KEY authorized
# for KRIKRI_TEST_ARCH_SSHD_USER - deliberately its OWN defaults (port
# 2225) and its OWN env names, NOT the KRIKRI_TEST_SSHD_* endpoint other
# ssh integration specs share: a shimmed (foreign-arch-reporting) target
# would break every same-arch assumption those specs make, so the two
# must never accidentally point at the same container. Skips (rather
# than fails) when no sshd is reachable, when the target does not report
# a foreign arch, or when the plugin binaries were not built. On a
# controller with many agent-loaded keys, raise the target's
# MaxAuthTries (echo "MaxAuthTries 30" >> /etc/ssh/sshd_config in the
# container, then restart sshd) - krikri's own ssh path relies on
# default identities first, like Ansible's.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private SSHD_HOST = ENV["KRIKRI_TEST_ARCH_SSHD_HOST"]? || "127.0.0.1"
private SSHD_PORT = (ENV["KRIKRI_TEST_ARCH_SSHD_PORT"]? || "2225").to_i
private SSHD_USER = ENV["KRIKRI_TEST_ARCH_SSHD_USER"]? || "root"
private SSHD_KEY  = ENV["KRIKRI_TEST_ARCH_SSHD_KEY"]? || "/tmp/kkt-key"

private def sshd_reachable? : Bool
  return false unless File.exists?(SSHD_KEY)
  TCPSocket.new(SSHD_HOST, SSHD_PORT, connect_timeout: 1).close
  true
rescue
  false
end

private def controller_arch : String
  io = IO::Memory.new
  Process.run("uname", ["-m"], output: io, error: Process::Redirect::Close)
  Krikri::PluginManager.normalize_arch(io.to_s)
end

private def ssh_base_args : Array(String)
  ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
   "-o", "IdentitiesOnly=yes", "-i", SSHD_KEY,
   "-o", "ConnectTimeout=5", "-p", SSHD_PORT.to_s,
   "#{SSHD_USER}@#{SSHD_HOST}"]
end

private def target_arch : String
  io = IO::Memory.new
  err = IO::Memory.new
  Process.run("ssh", ssh_base_args + ["uname -m"], output: io, error: err)
  Krikri::PluginManager.normalize_arch(io.to_s.presence || "SSH-ERR:#{err.to_s.strip.gsub(/\s+/, " ")}")
end

private def ssh_exec(command : String) : String
  io = IO::Memory.new
  Process.run("ssh", ssh_base_args + [command], output: io, error: Process::Redirect::Close)
  io.to_s.strip
end

private def run_over_ssh(gather_facts : Bool, task_body : String) : {Process::Status, String}
  playbook = PluginSpecHelper.tmp_path("arch-aware-#{Random::Secure.hex(4)}.yml")
  File.write(playbook, [
    "- hosts: target",
    "  gather_facts: #{gather_facts ? "true" : "false"}",
    "  tasks:",
    task_body,
    "",
  ].join("\n"))
  inventory = PluginSpecHelper.tmp_path("arch-aware-#{Random::Secure.hex(4)}.ini")
  File.write(inventory, "[target]\ntarget ansible_connection=ssh ansible_host=#{SSHD_HOST} ansible_user=#{SSHD_USER} ansible_port=#{SSHD_PORT} ansible_ssh_private_key_file=#{SSHD_KEY} ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=5'\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output, input: IO::Memory.new)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
  File.delete(inventory) if inventory && File.exists?(inventory)
end

describe "plugin arch awareness over ssh (issue #1)" do
  serial! # creates bin/plugins-<arch>/ inside the repo tree while it runs

  it "uploads and executes the per-arch plugin build for a foreign-arch target" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless sshd_reachable?

    arch = target_arch
    skip "target reports #{arch}, the controller's own arch - see this file's header" if arch.empty? || arch == controller_arch

    source = File.join(PROJECT_ROOT, "bin", "plugins", "command")
    skip "plugin binaries not built (run ./build.sh first)" unless File.exists?(source)

    # The per-arch build the fix looks up: one fat-plugin copy serves
    # every module name (here the controller-arch binary stands in for a
    # real aarch64 ELF - the target kernel can actually run it, which is
    # what makes the exec assertion meaningful without qemu).
    arch_dir = File.join(PROJECT_ROOT, "bin", "plugins-#{arch}")
    staged = File.join(arch_dir, "command")
    begin
      FileUtils.rm_rf(arch_dir)
      Dir.mkdir_p(arch_dir)
      FileUtils.cp(source, staged)
      File.chmod(staged, 0o755)
      # Distinguish this copy from the default binary it was made from
      # (both are controller-arch ELFs here): appended trailing bytes are
      # ignored by the ELF loader, so the file still executes identically
      # while its md5 - and therefore the remote .md5 the upload records -
      # proves WHICH local file was shipped.
      File.open(staged, "a") { |io| io << "\n#krikri-arch-marker\n" }

      status, output = run_over_ssh(false, "        - name: echo via per-arch binary\n          ansible.builtin.command: echo arch-ok")

      status.success?.must_equal(true, output)
      output.includes?("changed: [target]").must_equal(true, output)

      # And the file that actually landed on the target IS the per-arch
      # build, not the controller-arch default: the uploaded binary's
      # recorded md5 matches plugins-<arch>/command's content md5.
      local_md5 = IO::Memory.new
      Process.run("md5sum", [staged], output: local_md5, error: Process::Redirect::Close)
      expected = local_md5.to_s.split(' ').first?
      expected = "" unless expected
      remote_md5 = ssh_exec("cat #{Krikri::PluginManager.remote_plugin_dir(SSHD_USER)}/command.md5")
      remote_md5.includes?(expected).must_equal(true, "remote md5 #{remote_md5.inspect} != local per-arch md5 #{expected.inspect}")
    ensure
      FileUtils.rm_rf(arch_dir) if arch_dir && Dir.exists?(arch_dir)
    end
  end

  it "fails early with the actionable message when no per-arch build exists" do
    skip "no reachable test sshd (see this file's header for the throwaway setup)" unless sshd_reachable?

    arch = target_arch
    skip "target reports #{arch}, the controller's own arch - see this file's header" if arch.empty? || arch == controller_arch

    arch_dir = File.join(PROJECT_ROOT, "bin", "plugins-#{arch}")
    begin
      FileUtils.rm_rf(arch_dir)

      status, output = run_over_ssh(false, "        - name: must fail early\n          ansible.builtin.command: echo nope")

      status.success?.must_equal(false)
      # The old failure mode here was an exec-format error AFTER a
      # multi-MB upload; the fix fails at the decision point instead,
      # naming the missing arch dir and the remedy.
      output.includes?("no #{arch} plugin binaries available").must_equal(true, output)
      output.includes?("plugins-#{arch}").must_equal(true, output)
    ensure
      FileUtils.rm_rf(arch_dir) if arch_dir && Dir.exists?(arch_dir)
    end
  end
end
