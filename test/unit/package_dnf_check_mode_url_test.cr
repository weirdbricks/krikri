require "../minitest_helper"
require "file_utils"
require "json"

# Issue #1973 (ihmels.rpmfusion_repo, round29930900, rocky, --check): the
# role installs RPM Fusion's release repositories as URL specs
# (`ansible.builtin.package: {name: "{{ rpmfusion_repo_free_repo_url }}",
# state: present}`), and the round's check phase re-runs the host the
# role's own cold/warm phases already converged - the rpmfusion-release
# rpms are installed by then. Real's dnf module fetch_file()s the URL,
# hands the LOCAL file to the transaction, and resolves it to the EMPTY
# one, so `ansible-playbook --check` says ok; this engine's check-mode
# plan classified every URL spec as "would install" and said changed.
# Live-verified on a rockylinux:9 container (ansible-core 2.21.6), the
# issue's own URL:
#   converged host, --check -> ok: {"changed": false, "msg": "Nothing
#       to do", "rc": 0, "results": ["Installed /root/.ansible/tmp/
#       ansible-tmp-.../rpmfusion-free-release-9.noarch<rand>.rpm"]}
#   fresh host, --check     -> changed: ... "results": ["Installed
#       <fetch temp path>", "Installed: <nevra>", ...]
# The rpm shim answers for http(s)/ftp specs the way real rpm does -
# it reads the header off the URL - so the verdict needs no staged
# download. dnf/rpm are not on the spec host; everything runs against
# shimmed binaries on PATH through the plugin's _environment, so no
# process-wide ENV mutation is involved and no serial! is needed.
private def with_package1973_shims(
  installed : Array(String),
  url_nevra : String,
  install_out : String = "",
  install_rc : Int32 = 0,
  &
)
  bin_dir = File.join(Dir.tempdir, "krikri-pkg1973-#{Random.rand(1_000_000)}")
  url_log = File.join(bin_dir, "urls.log")
  FileUtils.mkdir_p(bin_dir)

  rpm_shim = <<-'SH'
    #!/bin/sh
    if [ "$1" = "-qp" ]; then
      case "$4" in
        http://*|https://*|ftp://*)
          printf '%s\n' "$4" >> "${KRIKRI_RPM_URL_LOG:?}"
          printf '%s\n' "${KRIKRI_RPM_URL_NEVRA:-}"
          exit 0
          ;;
      esac
      [ -f "$4" ] || exit 1
      printf '%s\n' "${KRIKRI_RPM_URL_NEVRA:-}"
      exit 0
    fi
    qarg="$4"
    [ -n "$qarg" ] || qarg="$2"
    for pair in ${KRIKRI_RPM_INSTALLED:-}; do
      pkg="${pair%%=*}"; nevra="${pair#*=}"
      [ "$qarg" = "$pkg" ] && { printf '%s\n' "$nevra"; exit 0; }
    done
    exit 1
    SH

  dnf_shim = <<-'SH'
    #!/bin/sh
    printf '%s\n' "$*" >> "${KRIKRI_DNF_LOG:?}"
    case "$1" in
      install|upgrade)
        if [ -n "${KRIKRI_DNF_INSTALL_OUT:-}" ]; then
          printf '%b' "${KRIKRI_DNF_INSTALL_OUT:-}"
          exit "${KRIKRI_DNF_INSTALL_RC:-0}"
        fi
        ;;
    esac
    echo "Nothing to do"
    exit 0
    SH

  File.write(File.join(bin_dir, "rpm"), rpm_shim)
  File.write(File.join(bin_dir, "dnf"), dnf_shim)
  File.write(File.join(bin_dir, "yum"), dnf_shim)
  {"rpm", "dnf", "yum"}.each { |bin| File.chmod(File.join(bin_dir, bin), 0o755) }

  env = {
    "PATH"                   => "#{bin_dir}:/usr/bin:/bin",
    "KRIKRI_DNF_LOG"         => File.join(bin_dir, "calls.log"),
    "KRIKRI_RPM_URL_LOG"     => url_log,
    "KRIKRI_RPM_INSTALLED"   => installed.join(" "),
    "KRIKRI_RPM_URL_NEVRA"   => url_nevra,
    "KRIKRI_DNF_INSTALL_OUT" => install_out,
    "KRIKRI_DNF_INSTALL_RC"  => install_rc.to_s,
  }.to_json
  yield env, url_log
ensure
  FileUtils.rm_rf(bin_dir) if bin_dir
end

describe "package plugin - check mode resolves a fetched URL rpm against the installed set (issue 1973)" do
  it "present for an already-installed URL rpm is the no-op ok, not changed" do
    with_package1973_shims(
      ["rpmfusion-free-release-9-1.noarch=rpmfusion-free-release-9-1.noarch"],
      "rpmfusion-free-release-9-1.noarch") do |env, url_log|
      url = "https://download1.rpmfusion.org/free/el/rpmfusion-free-release-9.noarch.rpm"
      result = PluginSpecHelper.run("package", {
        "name"                => url,
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"]?.try(&.as_bool).must_be_nil
      result.as_h.keys.must_equal(["msg", "changed", "results", "rc"])
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      # Real's results entry for a fetched URL names its random fetch temp
      # path, which this engine does not invent (see the file plan's own
      # comment); the verdict and the msg are what the round compares.
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(0)
      # The verdict came from the URL's own header, not from a name lookup.
      File.read_lines(url_log).must_equal([url])
    end
  end

  it "latest for an already-installed URL rpm is the same no-op ok" do
    with_package1973_shims(
      ["rpmfusion-free-release-9-1.noarch=rpmfusion-free-release-9-1.noarch"],
      "rpmfusion-free-release-9-1.noarch") do |env, _url_log|
      result = PluginSpecHelper.run("package", {
        "name"                => "https://download1.rpmfusion.org/free/el/rpmfusion-free-release-9.noarch.rpm",
        "state"               => "latest",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to do")
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(0)
    end
  end

  it "present for a URL rpm this host does not have still reports the would-install shape" do
    with_package1973_shims([] of String, "rpmfusion-free-release-9-1.noarch") do |env, _url_log|
      url = "https://download1.rpmfusion.org/free/el/rpmfusion-free-release-9.noarch.rpm"
      result = PluginSpecHelper.run("package", {
        "name"                => url,
        "state"               => "present",
        "use"                 => "dnf",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Check mode: No changes made, but would have if not in check mode")
      result["results"].as_a.map(&.as_s).must_equal(["Installed: #{url}"])
      result["rc"].as_i.must_equal(0)
    end
  end
end
