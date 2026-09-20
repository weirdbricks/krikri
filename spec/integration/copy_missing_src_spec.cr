require "../spec_helper"
require "../../src/krikri/task_executor"

# Regression spec for the dirless-infra findings report (Bug 2): a
# `copy: {src: /etc/caddy/tls/wildcard.crt, ...}` whose controller-side
# src does not exist must FAIL the task like real ansible-playbook
# ("Could not find or access '<src>' on the Ansible Controller."), in
# ordinary AND check mode - previously the missing src silently fell
# through param staging, the plugin's check-mode run had nothing to
# compare, and the task reported a green `ok` on every host while a real
# dry run reported failed=1 on each.
#
# Exercised through a subclass (Crystal private methods are callable from
# subclasses via the implicit receiver), same trick
# copy_binary_source_staging_spec.cr uses. No remote host is needed: the
# controller-side existence check fires before any staging/upload.
private class MissingCopySrcProbeExecutor < Krikri::TaskExecutor
  def probe(task, params, host, vars_context)
    inline_copy_source_content(task, params, host, vars_context)
  end
end

describe "copy: missing controller-side src fails the task" do
  it "returns a failed result for an absolute src that does not exist" do
    task = Krikri::Task.new("Copy wildcard cert", "ansible.builtin.copy")
    host = Krikri::Host.new("spec-host", "root", 1)
    params = {"src" => "/nonexistent/spec/wildcard.crt", "dest" => "/etc/ssl/wildcard.crt"}

    result = MissingCopySrcProbeExecutor.new([host] of Krikri::Host, [task] of Krikri::Task)
      .probe(task, params, host, {} of String => JSON::Any)

    json = result.should be_a(JSON::Any)
    json["failed"].as_bool.should be_true
    json["msg"].as_s.should contain("Could not find or access '/nonexistent/spec/wildcard.crt' on the Ansible Controller.")
  end
end
