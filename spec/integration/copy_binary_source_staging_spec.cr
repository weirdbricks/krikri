require "../spec_helper"
require "../../src/krikri/task_executor"

# Regression spec for the systemli.jitsi_meet / systemli.apt_repositories
# NO_PUBKEY divergence (round 74501, confirmed live on a fresh Atlantic.net
# host): the role's binary OpenPGP keyring
# (`copy: {src: prosody-debian-packages.gpg, dest: /usr/share/keyrings/...}`,
# 4702 bytes of invalid-UTF-8 OpenPGP packets) reached the remote plugin as
# INLINE `content:` - and the params ride to the remote plugin as JSON, a
# UTF-8 format. Serializing a String holding invalid byte sequences mangles
# them (observed live: 4702 bytes round-tripped through
# `{"content" => content}.to_json` + `JSON.parse` to 8394 bytes of
# U+FFFD-substituted garbage), so the keyring installed on the target was
# corrupt while every task-level checksum comparison against the
# equally-corrupt destination still "passed". apt then failed the role's
# final "Update cache" with NO_PUBKEY F7A37EB33D0B25D7, where real
# ansible-playbook's identical sequence succeeded.
#
# Fix: TaskExecutor#inline_copy_source_content never inlines a source whose
# bytes are not valid UTF-8 - binary sources take the byte-safe SCP staging
# path (the same one an oversized file takes) instead of the JSON-embedded
# `content:` path.
#
# The private method is exercised through a subclass (Crystal private
# methods are callable from subclasses via the implicit receiver). The host
# is deliberately unreachable, so the SCP staging attempt fails fast and
# returns the params untouched - which is exactly what makes the routing
# decision observable without a real remote: a binary src must come back
# WITHOUT a `content:` key (nothing inlined), a text src WITH it.
private class InlineCopyProbeExecutor < Krikri::TaskExecutor
  def probe(task, params, host, vars_context)
    inline_copy_source_content(task, params, host, vars_context)
  end
end

describe "copy: binary src is never inlined as JSON-transported content:" do
  it "routes an invalid-UTF-8 src to the SCP staging path (no content: key)" do
    bin_src = File.tempname("copy-binary-src-spec")
    File.write(bin_src, Bytes[0x99, 0x01, 0xa2, 0x04, 0x4a, 0x00, 0xf6, 0xfe, 0xff])

    task = Krikri::Task.new("Copy key", "ansible.builtin.copy")
    host = Krikri::Host.new("unreachable-spec-host", "root", 1)
    params = {"src" => bin_src, "dest" => "/usr/share/keyrings/spec.gpg", "mode" => "0644"}

    resolved = InlineCopyProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
      .probe(task, params, host, {} of String => JSON::Any)

    # The corruption ONLY happens when the bytes ride through JSON as
    # `content:` - so a binary source must never be inlined. (The staging
    # upload itself fails against the unreachable host and returns the
    # params as-is; the assertion is about the routing, not the upload.)
    resolved["content"]?.should be_nil
    resolved["src"]?.should eq(bin_src)
  ensure
    File.delete(bin_src) if bin_src && File.exists?(bin_src)
  end

  it "still inlines a valid-UTF-8 src as content: (unchanged behavior)" do
    text_src = File.tempname("copy-text-src-spec")
    File.write(text_src, "plain text key material\n")

    task = Krikri::Task.new("Copy key", "ansible.builtin.copy")
    host = Krikri::Host.new("unreachable-spec-host", "root", 1)
    params = {"src" => text_src, "dest" => "/tmp/spec-key.txt", "mode" => "0644"}

    resolved = InlineCopyProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
      .probe(task, params, host, {} of String => JSON::Any)

    resolved["content"]?.should eq("plain text key material\n")
    resolved["src"]?.should be_nil
    resolved["__original_src_basename"]?.should eq(File.basename(text_src))
  ensure
    File.delete(text_src) if text_src && File.exists?(text_src)
  end
end
