require "../minitest_helper"
require "../../src/krikri/task_executor"

# Regression spec for the andrewrothstein.func_e divergence (round 810153,
# confirmed live against ansible-core 2.19): the role's get_url: downloads
# the tarball to the REMOTE host's /tmp, then its unarchive: task sets no
# remote_src:, so real Ansible's unarchive action plugin requires src: to
# exist on the CONTROLLER - unconditionally, never falling back to the
# remote filesystem ("Could not find or access '/tmp/func-e_..._linux_
# amd64.tar.gz' on the Ansible Controller", failed=1). krikri-playbook
# previously returned params unchanged on that controller miss, so the
# plugin ran anyway and its remote_file_exists? check found the file ON
# THE TARGET (exactly where get_url put it) and succeeded - the backwards
# direction.
#
# The private method is exercised through a subclass (Crystal private
# methods are callable from subclasses via the implicit receiver), same
# pattern as copy_binary_source_staging_spec.cr's InlineCopyProbeExecutor.
private class UnarchiveStageProbeExecutor < Krikri::TaskExecutor
  def probe(task, params, host, vars_context)
    stage_unarchive_remote_src(task, params, host, vars_context)
  end
end

# crystal spec created this once in Spec.before_suite; the minitest
# entrypoint executes file-level code at require time, which is the
# same once-per-process guarantee (unique dir, no cross-run reuse).
private SPEC_ARCHIVE_DIR = File.join(Dir.tempdir, "unarchive-controller-src-#{Random::Secure.hex(4)}")
private SPEC_ARCHIVE     = File.join(SPEC_ARCHIVE_DIR, "spec-archive.tar.gz")

Dir.mkdir_p(SPEC_ARCHIVE_DIR)
`tar czf #{SPEC_ARCHIVE} -C #{SPEC_ARCHIVE_DIR} .`

private def unarchive_task
  Krikri::Task.new("Unarchive spec archive", "ansible.builtin.unarchive")
end

describe "unarchive: remote_src:false controller-side src: staging" do
  it "fails the task with real Ansible's own message when src: is missing on the controller" do
    # The get_url-then-unarchive shape: an absolute path that exists on
    # the remote target but NOT on the controller (deliberately pointing
    # at a path this spec never creates on the controller).
    missing_src = "/tmp/krikri-spec-func-e-#{Random::Secure.hex(4)}/func_e_1.1.4_linux_amd64.tar.gz"
    host = Krikri::Host.new("unreachable-spec-host", "root", 1)
    params = {"src" => missing_src, "dest" => "/opt/spec", "creates" => "/opt/spec/func-e"}

    staged = UnarchiveStageProbeExecutor.new([host] of Krikri::Host, [unarchive_task] of Krikri::Task)
      .probe(unarchive_task, params, host, {} of String => JSON::Any)

    staged.must_be_instance_of(JSON::Any)
    failure = staged.as(JSON::Any)
    failure["failed"].as_bool.must_equal(true)
    failure["changed"].as_bool.must_equal(false)
    failure["msg"].as_s.must_equal("Task failed: Could not find or access '#{missing_src}' on the Ansible Controller.\nIf you are using a module and expect the file to exist on the remote, see the remote_src option")
  end

  it "still fails on a controller miss when remote_src: is explicitly falsy, matching the default" do
    missing_src = "/tmp/krikri-spec-func-e-#{Random::Secure.hex(4)}/func_e_1.1.4_linux_amd64.tar.gz"
    host = Krikri::Host.new("unreachable-spec-host", "root", 1)
    params = {"src" => missing_src, "dest" => "/opt/spec", "remote_src" => "false"}

    staged = UnarchiveStageProbeExecutor.new([host] of Krikri::Host, [unarchive_task] of Krikri::Task)
      .probe(unarchive_task, params, host, {} of String => JSON::Any)

    staged.must_be_instance_of(JSON::Any)
    staged.as(JSON::Any)["failed"].as_bool.must_equal(true)
  end

  it "resolves and stages a controller-present src: as before (no regression, wezhai.minio shape)" do
    # The happy path: the file genuinely exists on the controller. On an
    # unreachable remote the SCP upload itself fails and falls back to
    # params-unchanged (pre-existing behavior) - the assertion is that
    # the controller-miss FAILURE path never fired and no failed-result
    # JSON came back, i.e. the file lookup succeeded.
    src = SPEC_ARCHIVE
    host = Krikri::Host.new("unreachable-spec-host", "root", 1)
    params = {"src" => src, "dest" => "/opt/spec"}

    staged = UnarchiveStageProbeExecutor.new([host] of Krikri::Host, [unarchive_task] of Krikri::Task)
      .probe(unarchive_task, params, host, {} of String => JSON::Any)

    staged.must_be_instance_of(Hash(String, String))
    staged.as(Hash(String, String))["src"]?.must_equal(src)
  end

  it "resolves the absolute path with no staging flags on a local connection (controller==target)" do
    src = SPEC_ARCHIVE
    host = Krikri::Host.new("spec-local", "root", 1)
    host.vars["ansible_connection"] = JSON::Any.new("local")
    params = {"src" => src, "dest" => "/opt/spec"}

    staged = UnarchiveStageProbeExecutor.new([host] of Krikri::Host, [unarchive_task] of Krikri::Task)
      .probe(unarchive_task, params, host, {} of String => JSON::Any)

    staged.must_be_instance_of(Hash(String, String))
    resolved = staged.as(Hash(String, String))
    resolved["src"]?.must_equal(File.expand_path(src))
    resolved["remote_src"]?.must_be_nil
    resolved["__cleanup_after_unarchive"]?.must_be_nil
  end

  it "still returns params unchanged for remote_src: true and URL src:, never staging" do
    host = Krikri::Host.new("unreachable-spec-host", "root", 1)

    remote_src_params = {"src" => "/tmp/does-not-exist-#{Random::Secure.hex(4)}.tar.gz", "dest" => "/opt/spec", "remote_src" => "true"}
    staged = UnarchiveStageProbeExecutor.new([host] of Krikri::Host, [unarchive_task] of Krikri::Task)
      .probe(unarchive_task, remote_src_params, host, {} of String => JSON::Any)
    staged.must_be_instance_of(Hash(String, String))

    url_params = {"src" => "https://example.invalid/archive.tar.gz", "dest" => "/opt/spec"}
    staged = UnarchiveStageProbeExecutor.new([host] of Krikri::Host, [unarchive_task] of Krikri::Task)
      .probe(unarchive_task, url_params, host, {} of String => JSON::Any)
    staged.must_be_instance_of(Hash(String, String))
  end

  it "treats copy: no the same as remote_src: true, never staging (round 812047, CVi.thanos)" do
    # copy: is unarchive's OLDER, mutually-exclusive-with-remote_src:
    # param spelling (`ansible-doc unarchive`): copy: false means the
    # same thing as remote_src: true - src: is already on the target,
    # never a controller path. CVi.thanos's own `copy: no` task (src:
    # downloaded straight to the remote by an earlier get_url-shaped
    # task) regressed through this exact staging path once the
    # controller-miss hard-fail landed (0.9.1048): copy: no was read as
    # the DEFAULT remote_src: false, so staging looked for src: on the
    # controller, found nothing, and failed where real Ansible succeeds.
    host = Krikri::Host.new("unreachable-spec-host", "root", 1)
    params = {"src" => "/tmp/does-not-exist-#{Random::Secure.hex(4)}.tar.gz", "dest" => "/opt/spec", "copy" => "no"}

    staged = UnarchiveStageProbeExecutor.new([host] of Krikri::Host, [unarchive_task] of Krikri::Task)
      .probe(unarchive_task, params, host, {} of String => JSON::Any)

    staged.must_be_instance_of(Hash(String, String))
  end
end
