require "digest/sha1"
require "../minitest_helper"

# Regression spec for issue #1841 (Azulinho.azulinho-google-dns): the role
# copies onto /etc/resolv.conf, which inside the round's podman container is
# a bind mount, so real copy.py's atomic_move cannot land its final rename
# (EBUSY) and crashes the whole MODULE with "Unable to make ... failed final
# rename from ...". krikri reported its own "Failed to move file to
# destination" wording instead, and the crash result carried no checksum.
#
# This spec reproduces the same ladder-and-crash shape without root or a bind
# mount, on the sticky directory's other workaround errno: in a root-owned
# sticky directory (/tmp) a rename over a dest NEITHER the spec user NOR the
# directory owns fails EPERM, so the whole ladder runs and its final rename
# fails exactly like the EBUSY one. Preparing such a dest needs a foreign uid,
# which podman's --user mapping provides without root (the technique
# blockinfile's ladder spec shares).
describe "copy: atomic_move's failed final rename" do
  it "crashes with real's failed-final-rename wording and checksum (sticky-dir EPERM)" do
    skip "root owns every sticky dir, so root never sees this EPERM" if PluginSpecHelper.running_as_root?

    podman = Process.run("podman", ["--version"], output: Process::Redirect::Close, error: Process::Redirect::Close)
    skip "needs podman to prepare a foreign-owned dest in root-owned sticky /tmp" unless podman.success?

    name = "krikri-spec-copy-foreign-#{Process.pid}-#{Random::Secure.hex(4)}"
    dest = File.join("/tmp", name)
    prepared = Process.run("podman",
      ["run", "--rm", "--user", "1000:1000", "-v", "/tmp:/hosttmp", "docker.io/library/alpine",
       "sh", "-c", "echo stale > /hosttmp/#{name} && chmod 644 /hosttmp/#{name}"],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    skip "podman could not prepare the foreign dest" unless prepared.success? && File.exists?(dest)

    content = "nameserver 1.1.1.1\n"
    begin
      result = PluginSpecHelper.run("copy", {"content" => content, "dest" => dest})

      result["failed"].as_bool.must_equal(true)
      msg = result["msg"].as_s
      # Real's crash chain, ": "-joined by the module crash wrapper: the
      # raise's own text (its trailing period stripped by the join) + the
      # final rename's OSError, whose repr carries both byte paths. The
      # echoed source keeps real's remote-tmp staging shape and the stage its
      # .ansible_tmp + 8-random + basename shape.
      msg.starts_with?("Task failed: Module failed: Unable to make b'").must_equal(true)
      msg.includes?("/.ansible/tmp/ansible-tmp-").must_equal(true)
      msg.includes?("into to '#{dest}', failed final rename from '/tmp/.ansible_tmp").must_equal(true)
      msg.includes?("[Errno 1] Operation not permitted: b'").must_equal(true)
      msg.includes?("-> b'#{dest}'").must_equal(true)
      # The copy ACTION plugin backfills local_checksum into any result
      # lacking one, crashes included.
      result["checksum"].as_s.must_equal(Digest::SHA1.hexdigest(content))
      # The failed ladder left dest untouched.
      File.read(dest).must_equal("stale\n")
    ensure
      # Neither the spec user nor /tmp owns the file, so the sticky bit blocks
      # our own unlink - the foreign uid cleans up after itself.
      Process.run("podman",
        ["run", "--rm", "--user", "1000:1000", "-v", "/tmp:/hosttmp", "docker.io/library/alpine",
         "rm", "-f", "/hosttmp/#{name}"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
    end
  end
end
