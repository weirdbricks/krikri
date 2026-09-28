require "../minitest_helper"
require "../../src/krikri/base_plugin"
require "json"

# Pins the shared strict `type: bool` param validation
# (PluginHelpers::StrictBoolValidation, applied through
# BasePlugin#validate_bool_params!) against real ansible-core's
# check_type_bool (module_utils/common/validation.py) + boolean()
# (module_utils/parsing/convert_bool.py) + the parameters.py failure
# wrapper, live-verified against ansible-core 2.19.11.
#
# Two layers:
# - a probe plugin exercising every conversion rule and message shape
#   directly (valid matrix, native JSON types, explicit-null default
#   gate, alias -> canonical reporting, declaration-order first-error),
# - a table-driven sweep over EVERY documented bool param of every core
#   (ansible.builtin) plugin, asserting the exact failure message for an
#   invalid value (validation fails before any module logic, so these
#   runs are side-effect free).

# The fixed "Valid booleans include:" tail the engine emits - real
# serializes a Python SET there, so its ORDER differs between module
# processes (PYTHONHASHSEED); only the element set is deterministic in
# real. The engine's fixed order is check_type_bool's docstring listing.
VALID_BOOLEANS = "'1', 'on', 1, '0', 0, 'n', 'f', 'false', 'true', 'y', 't', 'yes', 'no', 'off'"

private def bool_error(param : String, type_name : String, value : String, detail : String? = nil) : String
  detail ||= "The value '#{value}' is not a valid boolean. Valid booleans include: #{VALID_BOOLEANS}"
  "argument '#{param}' is of type #{type_name} and we were unable to convert to bool: #{detail}"
end

private class BoolParamProbe < Krikri::BasePlugin
  protected def bool_params : Array(String)
    %w[flag aliased nullok]
  end

  protected def bool_param_aliases : Hash(String, String)
    {"aliased-alias" => "aliased"}
  end

  protected def bool_params_none_default : Array(String)
    %w[nullok]
  end

  def execute : Krikri::PluginResult
    validate_bool_params!
    Krikri::PluginResult.new(changed: false, failed: false)
  end
end

private def probe_run(params_json : String) : JSON::Any
  config = JSON.parse(%({"host": {"name": "localhost", "user": "root", "port": 22}, "params": #{params_json}, "vars": {}}))
  JSON.parse(BoolParamProbe.new(config).run_and_capture)
end

private def msg_of(result : JSON::Any) : String
  result["msg"]?.try(&.as_s) || ""
end

describe "StrictBoolValidation conversion rules (probe)" do
  it "accepts every string spelling real's BOOLEANS lists, with case/whitespace slack" do
    ["y", "Y", " yes ", "on", "ON", "1", "true", "TRUE", "t", "n", "no", "off", "0", "false", "f"].each do |v|
      result = probe_run(%({"flag": #{v.inspect}}))
      expect(falsey?(result["failed"]?.try(&.as_bool))).must_equal(true)
    end
  end

  it "rejects a non-boolean string with the exact parameters.py wording" do
    result = probe_run(%({"flag": "sometimes"}))
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(bool_error("flag", "str", "sometimes"))
  end

  it "rejects an empty string - real's boolean('') is not in either set" do
    result = probe_run(%({"flag": ""}))
    result["msg"].as_s.must_equal(bool_error("flag", "str", ""))
  end

  it "reports a stringified-lookalike number as type str, like real does for a quoted YAML scalar" do
    result = probe_run(%({"flag": "1.0"}))
    result["msg"].as_s.must_equal(bool_error("flag", "str", "1.0"))
  end

  it "accepts the native JSON bools and 0/1 ints and 0.0/1.0 floats" do
    [true, false, 0, 1, 0.0, 1.0].each do |v|
      result = probe_run(%({"flag": #{v.to_json}}))
      expect(falsey?(result["failed"]?.try(&.as_bool))).must_equal(true)
    end
  end

  it "fails a non-0/1 int with native_type_name 'int'" do
    result = probe_run(%({"flag": 2}))
    result["msg"].as_s.must_equal(bool_error("flag", "int", "2"))
  end

  it "fails a non-0/1 float with native_type_name 'float'" do
    result = probe_run(%({"flag": 2.5}))
    result["msg"].as_s.must_equal(bool_error("flag", "float", "2.5"))
  end

  it "fails an explicit null on a real-defaulted bool with the NoneType message" do
    result = probe_run(%({"flag": null}))
    result["msg"].as_s.must_equal(
      "argument 'flag' is of type NoneType and we were unable to convert to bool: " \
      "<class 'NoneType'> cannot be converted to a bool")
  end

  it "skips an explicit null on a bool whose real default is None (parameters.py gate)" do
    result = probe_run(%({"nullok": null}))
    expect(falsey?(result["failed"]?.try(&.as_bool))).must_equal(true)
  end

  it "fails a list value with the <class 'list'> message" do
    result = probe_run(%({"flag": [1]}))
    result["msg"].as_s.must_equal(
      "argument 'flag' is of type list and we were unable to convert to bool: " \
      "<class 'list'> cannot be converted to a bool")
  end

  it "fails a dict value with the <class 'dict'> message" do
    result = probe_run(%({"flag": {"a": 1}}))
    result["msg"].as_s.must_equal(
      "argument 'flag' is of type dict and we were unable to convert to bool: " \
      "<class 'dict'> cannot be converted to a bool")
  end

  it "never validates an omitted param" do
    result = probe_run(%({}))
    expect(falsey?(result["failed"]?.try(&.as_bool))).must_equal(true)
  end

  it "reports an alias spelling under the CANONICAL name, like real's alias resolution" do
    result = probe_run(%({"aliased-alias": "blah"}))
    result["msg"].as_s.must_equal(bool_error("aliased", "str", "blah"))
  end

  it "reports the FIRST violating param in real argument-spec declaration order" do
    result = probe_run(%({"aliased": "bad-second", "flag": "bad-first"}))
    result["msg"].as_s.must_equal(bool_error("flag", "str", "bad-first"))
  end
end

# Every documented `type: bool` option of every core (ansible.builtin)
# module this engine ships a plugin for, from `ansible-doc -j
# ansible.builtin.<module>` (declaration order; aliases validated
# separately below). Special placements/wordings are asserted by the
# dedicated cases at the bottom.
BOOL_PARAM_TABLE = {
  "apt"               => %w[allow_change_held_packages allow_downgrade allow_unauthenticated auto_install_module_deps autoclean autoremove clean fail_on_autoremove force force_apt_get install_recommends only_upgrade purge update_cache],
  "apt_key"           => %w[validate_certs],
  "apt_repository"    => %w[install_python_apt update_cache validate_certs],
  "assemble"          => %w[backup decrypt ignore_hidden remote_src unsafe_writes],
  "assert"            => %w[quiet],
  "blockinfile"       => %w[append_newline backup create prepend_newline unsafe_writes],
  "command"           => %w[expand_argument_vars stdin_add_newline strip_empty_ends],
  "copy"              => %w[backup decrypt follow force local_follow remote_src unsafe_writes],
  "cron"              => %w[backup disabled env],
  "debconf"           => %w[unseen],
  "deb822_repository" => %w[allow_downgrade_to_insecure allow_insecure allow_weak by_hash check_date check_valid_until enabled pdiffs trusted],
  "dnf"               => %w[allow_downgrade allowerasing autoremove best bugfix cacheonly disable_gpg_check download_only install_repoquery install_weak_deps nobest security skip_broken sslverify update_cache update_only validate_certs],
  "dnf5"              => %w[allow_downgrade allowerasing auto_install_module_deps autoremove best bugfix cacheonly disable_gpg_check download_only install_repoquery install_weak_deps nobest security skip_broken sslverify update_cache update_only validate_certs],
  "expect"            => %w[echo],
  "fetch"             => %w[fail_on_missing flat validate_checksum],
  "file"              => %w[follow force recurse unsafe_writes],
  "find"              => %w[exact_mode follow get_checksum hidden read_whole_file recurse use_regex],
  "getent"            => %w[fail_key],
  "get_url"           => %w[backup decompress force force_basic_auth unsafe_writes use_gssapi use_netrc use_proxy validate_certs],
  "git"               => %w[accept_hostkey accept_newhostkey bare clone force recursive single_branch track_submodules update verify_commit],
  "group"             => %w[force local non_unique system],
  "iptables"          => %w[chain_management flush numeric],
  "known_hosts"       => %w[hash_host],
  "lineinfile"        => %w[backrefs backup create firstmatch unsafe_writes],
  "mount_facts"       => %w[include_aggregate_mounts],
  "package"           => %w[allow_change_held_packages allow_downgrade allow_unauthenticated auto_install_module_deps autoclean autoremove best bugfix cacheonly clean disable_gpg_check download_only fail_on_autoremove force force_apt_get install_repoquery install_weak_deps nobest only_upgrade purge security skip_broken sslverify update_cache update_only validate_certs],
  "pip"               => %w[break_system_packages editable virtualenv_site_packages],
  "replace"           => %w[backup unsafe_writes],
  "rpm_key"           => %w[validate_certs],
  "service"           => %w[enabled],
  "shell"             => %w[stdin_add_newline],
  "stat"              => %w[follow get_attributes get_checksum get_mime],
  "subversion"        => %w[checkout export force in_place switch update validate_certs],
  "systemd"           => %w[daemon_reexec daemon_reload enabled force masked no_block],
  "template"          => %w[backup follow force unsafe_writes],
  "unarchive"         => %w[copy decrypt keep_newer list_files remote_src unsafe_writes validate_certs],
  "uri"               => %w[decompress force force_basic_auth remote_src return_content unsafe_writes use_gssapi use_netrc use_proxy validate_certs],
  "user"              => %w[append create_home force generate_ssh_key hidden local move_home non_unique password_lock remove system],
  "yum_repository"    => %w[async countme enabled enablegroups gpgcheck keepalive module_hotfixes protect repo_gpgcheck s3_enabled skip_if_unavailable ssl_check_cert_permissions sslverify unsafe_writes],
}

# Context params a plugin needs to REACH its bool validation (its own
# required-args/controller gates sit first, exactly like real's
# required-before-types argspec order).
# unarchive's dest-existence + archive-handler checks sit before its bool
# validation (both live-verified ordering vs real), so the sweep needs a
# real (empty) tar as src.
UNARCHIVE_TAR = begin
  dir = File.tempname("krikri-bool-spec-src")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "marker.txt"), "x")
  tar = File.join(dir, "probe.tar")
  Process.run("tar", ["-cf", tar, "-C", dir, "marker.txt"])
  tar
end

CONTEXT = {
  "command"    => {"cmd" => "echo hi"},
  "fetch"      => {"src" => "/etc/hostname", "dest" => "/tmp"},
  "file"       => {"path" => "/tmp"},
  "getent"     => {"database" => "passwd"},
  "lineinfile" => {"path" => "/tmp"},
  "stat"       => {"path" => "/tmp"},
  "group"      => {"name" => "krikri-probe"},
  "user"       => {"name" => "krikri-probe"},
  "shell"      => {"_raw_params" => "echo hi"},
  "template"   => {"dest" => "/tmp"},
  "unarchive"  => {"src" => UNARCHIVE_TAR, "dest" => "/tmp"},
} of String => Hash(String, String)

describe "core plugins' documented bool params (table sweep)" do
  # Table-driven rows must be generated at compile time: minitest's `it`
  # compiles to a generated method, so the rows can't be registered from
  # a runtime loop like crystal spec's closure-based `it` could.
  {% for plugin, params in BOOL_PARAM_TABLE %}
    {% for param, j in params %}
      {% cname = plugin.id.stringify + ": " + param.id.stringify + " rejects a non-boolean value with real's wording" %}
      it {{ cname }} do
        base = CONTEXT[{{plugin}}]? || {} of String => String
        run_params = base.merge({ {{param}} => "krikri-not-a-bool" })
        result = PluginSpecHelper.run({{plugin}}, run_params)
        result["failed"].as_bool.must_equal(true)
        result["msg"].as_s.must_equal(bool_error({{param}}, "str", "krikri-not-a-bool"))
      end
    {% end %}
  {% end %}

  it "apt: update-cache alias fails under the canonical name" do
    result = PluginSpecHelper.run("apt", {"name" => "curl", "update-cache" => "blah"})
    result["msg"].as_s.must_equal(bool_error("update_cache", "str", "blah"))
  end

  it "dnf: expire-cache alias fails under the canonical update_cache name" do
    result = PluginSpecHelper.run("dnf", {"name" => "bash", "expire-cache" => "blah"})
    result["msg"].as_s.must_equal(bool_error("update_cache", "str", "blah"))
  end

  it "stat: attr alias fails under the canonical get_attributes name" do
    result = PluginSpecHelper.run("stat", {"path" => "/tmp", "attr" => "blah"})
    result["msg"].as_s.must_equal(bool_error("get_attributes", "str", "blah"))
  end

  it "systemd: daemon-reload alias fails under the canonical name" do
    result = PluginSpecHelper.run("systemd", {"name" => "ssh", "daemon-reload" => "blah"})
    result["msg"].as_s.must_equal(bool_error("daemon_reload", "str", "blah"))
  end

  it "user: createhome alias fails under the canonical create_home name" do
    result = PluginSpecHelper.run("user", {"name" => "krikri-probe", "createhome" => "blah"})
    result["msg"].as_s.must_equal(bool_error("create_home", "str", "blah"))
  end

  it "yum_repository: validate_certs alias fails under the canonical sslverify name" do
    result = PluginSpecHelper.run("yum_repository", {"name" => "krikri-probe", "validate_certs" => "blah"})
    result["msg"].as_s.must_equal(bool_error("sslverify", "str", "blah"))
  end

  it "apt: native int/float/null values report real's native type names" do
    result = PluginSpecHelper.run_raw("apt", {"name" => JSON::Any.new("curl"), "force" => JSON::Any.new(2_i64)})
    result["msg"].as_s.must_equal(bool_error("force", "int", "2"))

    result = PluginSpecHelper.run_raw("apt", {"name" => JSON::Any.new("curl"), "force" => JSON::Any.new(2.5)})
    result["msg"].as_s.must_equal(bool_error("force", "float", "2.5"))

    result = PluginSpecHelper.run_raw("apt", {"name" => JSON::Any.new("curl"), "force" => JSON::Any.new(nil)})
    result["msg"].as_s.must_equal(
      "argument 'force' is of type NoneType and we were unable to convert to bool: " \
      "<class 'NoneType'> cannot be converted to a bool")

    result = PluginSpecHelper.run_raw("apt", {"name" => JSON::Any.new("curl"), "install_recommends" => JSON::Any.new(nil)})
    msg_of(result).wont_include("unable to convert to bool")
  end

  it "set_fact: cacheable uses the controller-side wording (no argspec wrapper)" do
    result = PluginSpecHelper.run("set_fact", {"foo" => "bar", "cacheable" => "blah"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Task failed: The value 'blah' is not a valid boolean. Valid booleans include: #{VALID_BOOLEANS}")
  end

  it "template: trim_blocks/lstrip_blocks stay unvalidated, like real (action-plugin-consumed)" do
    result = PluginSpecHelper.run("template", {"dest" => "/tmp", "trim_blocks" => "blah"})
    msg_of(result).wont_include("unable to convert to bool")
  end
end
