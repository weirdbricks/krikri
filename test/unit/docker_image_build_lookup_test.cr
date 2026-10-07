require "../minitest_helper"

# Pins plugins/docker_image_build.cr's image-existence lookup against real
# community.docker 5.2.1's CLI-based find_image (_common_cli.py):
#
#   docker image ls --format '{{ json . }}' --no-trunc \
#     --filter reference=<name>      (call_cli_json_stream, check_rc=True)
#
# followed by a first Tag/Digest row match, the docker.io fallback chain
# when no rows come back, and a final `docker image inspect <ID>`
# (call_cli_json, check_rc=False). Live-verified 2026-10-06 against
# ansible-core 2.19.11 + community.docker 5.2.1 with a fake daemon on a
# unix socket answering /_ping and /version and HTTP 500/404 JSON for
# everything else: the failing `image ls` surfaces real's run_command
# failure shape (the CLI renders the daemon's message itself):
#
#   cmd = "<cli> --host unix:///tmp/kop_fake_500.sock image ls --format \
#          '{{ json . }}' --no-trunc --filter reference=kop_img500_bx"
#   rc = 1, stdout = "", stderr = "Error response from daemon: ...\n",
#   msg = stderr stripped, stderr_lines = [stderr line],
#   keys: cmd rc stdout stderr failed msg stdout_lines stderr_lines
#         changed exception
#
# The fake docker CLI scripts below stand in for the real CLI the same way
# the version-probe/buildx-gate tests do: docker_cli points at a tmp-dir
# script keyed on 'version' / 'info' / 'image ls' / 'image inspect' /
# 'buildx build' argv fragments.
describe "docker_image_build CLI image lookup" do
  private def build_dir : String
    dir = PluginSpecHelper.tmp_path("dib-build")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "Dockerfile"), "FROM busybox\n")
    dir
  end

  # Probes green (version silent-ok, info carries the buildx plugin),
  # `image ls` fails with *stderr* and rc 1 - the daemon-error arm.
  private def failing_lookup_cli(stderr : String) : String
    path = PluginSpecHelper.tmp_path("dib-lookup-docker")
    File.write(path, <<-SCRIPT)
      #!/bin/sh
      case " $* " in
        *" info "*)
          printf '%s' '{"ClientInfo": {"Plugins": [{"Name": "buildx", "Version": "v0.17.0"}]}}'
          ;;
        *" image ls "*)
          echo '#{stderr}' >&2
          exit 1
          ;;
        *" buildx build "*)
          echo 'buildx must not run here' >&2
          exit 1
          ;;
      esac
      exit 0
      SCRIPT
    File.chmod(path, 0o755)
    path
  end

  # Empty `image ls` until the buildx-build arm runs (a state marker file
  # tells the pre- and post-build ls calls apart), then an optional
  # post-build row/inspect payload; the buildx-build arm configurable.
  private def building_cli(build_rc : Int32, build_stdout : String, build_stderr : String,
                           post_ls_row : String? = nil, post_inspect : String? = nil) : String
    path = PluginSpecHelper.tmp_path("dib-building-docker")
    state = PluginSpecHelper.tmp_path("dib-ls-state")
    FileUtils.rm_f(state)
    post_ls_arm = post_ls_row ? "printf '%s\\n' '#{post_ls_row}'" : ":"
    post_inspect_out = post_inspect || "[]"
    File.write(path, <<-SCRIPT)
      #!/bin/sh
      case " $* " in
        *" info "*)
          printf '%s' '{"ClientInfo": {"Plugins": [{"Name": "buildx", "Version": "v0.17.0"}]}}'
          ;;
        *" image ls "*)
          if [ -f '#{state}' ]; then
            #{post_ls_arm}
          fi
          ;;
        *" image inspect "*)
          printf '%s' '#{post_inspect_out}'
          ;;
        *" buildx build "*)
          touch '#{state}'
          printf '%s' '#{build_stdout.gsub("'", "'\\''")}'
          echo '#{build_stderr.gsub("'", "'\\''")}' >&2
          exit #{build_rc}
          ;;
      esac
      exit 0
      SCRIPT
    File.chmod(path, 0o755)
    path
  end

  # `image ls` prints *ls_stdout* verbatim, `image inspect` prints
  # *inspect* with *inspect_rc*/*inspect_stderr*.
  private def found_cli(ls_stdout : String, inspect : String, inspect_rc : Int32 = 0,
                        inspect_stderr : String = "inspect exploded") : String
    path = PluginSpecHelper.tmp_path("dib-found-docker")
    File.write(path, <<-SCRIPT)
      #!/bin/sh
      case " $* " in
        *" info "*)
          printf '%s' '{"ClientInfo": {"Plugins": [{"Name": "buildx", "Version": "v0.17.0"}]}}'
          ;;
        *" image ls "*)
          printf '%s' '#{ls_stdout.gsub("'", "'\\''")}'
          ;;
        *" image inspect "*)
          printf '%s' '#{inspect.gsub("'", "'\\''")}'
          echo '#{inspect_stderr.gsub("'", "'\\''")}' >&2
          exit #{inspect_rc}
          ;;
        *" buildx build "*)
          echo 'buildx must not run here' >&2
          exit 1
          ;;
      esac
      exit 0
      SCRIPT
    File.chmod(path, 0o755)
    path
  end

  it "fails in the run_command shape when the image ls call fails (500 daemon)" do
    cli = failing_lookup_cli("Error response from daemon: kop fake daemon: internal failure")
    host = "unix:///tmp/kop_fake_500.sock"

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "kop_img500_bx",
      "path"        => build_dir,
      "docker_cli"  => cli,
      "docker_host" => host,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error response from daemon: kop fake daemon: internal failure")
    result["cmd"].as_s.must_equal("#{cli} --host #{host} image ls --format '{{ json . }}' --no-trunc --filter reference=kop_img500_bx")
    result["rc"].as_i.must_equal(1)
    result["stdout"].as_s.must_equal("")
    result["stderr"].as_s.must_equal("Error response from daemon: kop fake daemon: internal failure\n")
    result["stdout_lines"].as_a.must_be_empty
    result["stderr_lines"].as_a.must_equal(["Error response from daemon: kop fake daemon: internal failure"])
    result["changed"].as_bool.must_equal(false)
    result["exception"].as_s.must_equal("(traceback unavailable)")
    result.as_h.keys.must_equal(%w[cmd rc stdout stderr failed msg stdout_lines stderr_lines changed exception])
  end

  it "fails in the run_command shape when the image ls call fails (404 daemon)" do
    cli = failing_lookup_cli("Error response from daemon: kop fake daemon: no such thing")
    host = "unix:///tmp/kop_fake_404.sock"

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "kop_img404_bx",
      "path"        => build_dir,
      "docker_cli"  => cli,
      "docker_host" => host,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error response from daemon: kop fake daemon: no such thing")
    result["stderr"].as_s.must_equal("Error response from daemon: kop fake daemon: no such thing\n")
    result.as_h.keys.must_equal(%w[cmd rc stdout stderr failed msg stdout_lines stderr_lines changed exception])
  end

  it "fails in the call_cli_json_stream shape when an ls line starts with { but is not JSON" do
    path = PluginSpecHelper.tmp_path("dib-badjson-docker")
    File.write(path, <<-SCRIPT)
      #!/bin/sh
      case " $* " in
        *" info "*)
          printf '%s' '{"ClientInfo": {"Plugins": [{"Name": "buildx", "Version": "v0.17.0"}]}}'
          ;;
        *" image ls "*)
          printf '%s\\n' '{ broken'
          ;;
        *" buildx build "*)
          echo 'buildx must not run here' >&2
          exit 1
          ;;
      esac
      exit 0
      SCRIPT
    File.chmod(path, 0o755)
    host = "unix:///tmp/kop_badjson.sock"

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "krikri/thing",
      "path"        => build_dir,
      "docker_cli"  => path,
      "docker_host" => host,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Error while parsing JSON output of #{path} --host #{host} image ls --format '{{ json . }}' --no-trunc --filter reference=krikri/thing: ")
    result["msg"].as_s.must_include("\nJSON output: { broken\n")
    result["msg"].as_s.must_include("\n\nError output:\n")
    result["cmd"].as_s.must_equal("#{path} --host #{host} image ls --format '{{ json . }}' --no-trunc --filter reference=krikri/thing")
    result["rc"].as_i.must_equal(0)
    result.as_h.keys.must_equal(%w[cmd rc stdout stderr failed msg stdout_lines stderr_lines changed exception])
  end

  it "proceeds to check mode when the lookup returns no rows" do
    cli = building_cli(1, "", "")

    result = PluginSpecHelper.run("docker_image_build", {
      "name"                 => "krikri/thing",
      "path"                 => build_dir,
      "docker_cli"           => cli,
      "docker_host"          => "unix:///tmp/kop_absent.sock",
      "_ansible_check_mode"  => "true",
    })

    result["failed"].as_bool.must_equal(false)
    result["changed"].as_bool.must_equal(true)
    result["image"].as_h.must_be_empty
    result["msg"]?.must_be_nil
  end

  it "runs the build when the lookup returns no rows and registers the post-build image" do
    row = %({"Repository": "krikri/thing", "Tag": "latest", "Digest": "", "ID": "sha256:post"})
    cli = building_cli(0, "build output\n", "", post_ls_row: row, post_inspect: %([{"Id": "sha256:post", "RepoTags": ["krikri/thing:latest"]}]))

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "krikri/thing",
      "path"        => build_dir,
      "docker_cli"  => cli,
      "docker_host" => "unix:///tmp/kop_build.sock",
    })

    result["failed"].as_bool.must_equal(false)
    result["changed"].as_bool.must_equal(true)
    result["image"]["Id"].as_s.must_equal("sha256:post")
    result["stdout"].as_s.must_equal("build output\n")
    result["command"].as_a.map(&.as_s).must_equal(["buildx", "build", "--progress", "plain", "--tag", "krikri/thing:latest", "--", build_dir])
  end

  it "fails in the Building ... failed shape when the build exits non-zero after an empty lookup" do
    cli = building_cli(1, "partial output\n", "boom during build")

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "krikri/thing",
      "path"        => build_dir,
      "docker_cli"  => cli,
      "docker_host" => "unix:///tmp/kop_buildfail.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Building krikri/thing:latest failed")
    result["stdout"].as_s.must_equal("partial output\n")
    result["stderr"].as_s.must_equal("boom during build\n")
    result.as_h.keys.must_equal(%w[stdout stderr command failed msg stdout_lines stderr_lines changed exception])
  end

  it "skips the build when the lookup finds the image with a matching tag" do
    row = %({"Repository": "valid-name", "Tag": "latest", "Digest": "sha256:d1", "ID": "sha256:abc"})
    cli = found_cli(row + "\n", %([{"Id": "sha256:abc", "RepoTags": ["valid-name:latest"]}]))

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "valid-name",
      "path"        => build_dir,
      "docker_cli"  => cli,
      "docker_host" => "unix:///tmp/kop_present.sock",
    })

    result["failed"].as_bool.must_equal(false)
    result["changed"].as_bool.must_equal(false)
    result["msg"]?.must_be_nil
    result["image"]["Id"].as_s.must_equal("sha256:abc")
    result.as_h.keys.must_equal(%w[changed actions image failed])
  end

  it "runs the build when the only row has a different tag" do
    row = %({"Repository": "valid-name", "Tag": "other", "Digest": "", "ID": "sha256:abc"})
    cli = building_cli(1, "", "no build should matter here\n", post_ls_row: nil)

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "valid-name",
      "path"        => build_dir,
      "docker_cli"  => cli,
      "docker_host" => "unix:///tmp/kop_tagmiss.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Building valid-name:latest failed")
  end

  it "walks the docker.io fallback chain before giving up" do
    row = %({"Repository": "docker.io/library/valid-name", "Tag": "latest", "Digest": "", "ID": "sha256:lib"})
    path = PluginSpecHelper.tmp_path("dib-fallback-docker")
    File.write(path, <<-SCRIPT)
      #!/bin/sh
      case " $* " in
        *" info "*)
          printf '%s' '{"ClientInfo": {"Plugins": [{"Name": "buildx", "Version": "v0.17.0"}]}}'
          ;;
        *" image ls "*)
          case " $* " in
            *"reference=docker.io/library/valid-name"*)
              printf '%s\\n' '#{row}'
              ;;
          esac
          ;;
        *" image inspect "*)
          printf '%s' '[{"Id": "sha256:lib"}]'
          ;;
        *" buildx build "*)
          echo 'buildx must not run here' >&2
          exit 1
          ;;
      esac
      exit 0
      SCRIPT
    File.chmod(path, 0o755)

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "valid-name",
      "path"        => build_dir,
      "docker_cli"  => path,
      "docker_host" => "unix:///tmp/kop_fallback.sock",
    })

    result["failed"].as_bool.must_equal(false)
    result["changed"].as_bool.must_equal(false)
    result["image"]["Id"].as_s.must_equal("sha256:lib")
  end

  it "fails plainly when the image inspect call after a found row exits non-zero" do
    row = %({"Repository": "valid-name", "Tag": "latest", "Digest": "", "ID": "sha256:abc"})
    cli = found_cli(row + "\n", %([{"Id": "sha256:abc"}]), inspect_rc: 1)

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "valid-name",
      "path"        => build_dir,
      "docker_cli"  => cli,
      "docker_host" => "unix:///tmp/kop_inspectfail.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error inspecting image valid-name:latest - inspect exploded\n")
    result.as_h.keys.must_equal(%w[failed msg changed exception])
  end

  it "treats an empty image inspect list as not found even on failure" do
    row = %({"Repository": "valid-name", "Tag": "latest", "Digest": "", "ID": "sha256:abc"})
    cli = found_cli(row + "\n", "[]", inspect_rc: 1)

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "valid-name",
      "path"        => build_dir,
      "docker_cli"  => cli,
      "docker_host" => "unix:///tmp/kop_emptyinspect.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Building valid-name:latest failed")
  end

  it "fails with the more-than-one-result wording when the tag is empty and rows are many" do
    row = %({"Repository": "valid-name", "Tag": "a", "Digest": "", "ID": "sha256:a"})
    cli = found_cli("#{row}\n#{row.gsub("sha256:a", "sha256:b")}\n", "[]")

    result = PluginSpecHelper.run("docker_image_build", {
      "name"        => "valid-name",
      "tag"         => "",
      "path"        => build_dir,
      "docker_cli"  => cli,
      "docker_host" => "unix:///tmp/kop_multi.sock",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Daemon returned more than one result for valid-name:")
    result.as_h.keys.must_equal(%w[failed msg changed exception])
  end
end
