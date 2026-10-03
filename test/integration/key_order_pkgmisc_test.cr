require "../minitest_helper"
require "file_utils"
require "json"
require "../../src/krikri/inventory_parser"
require "../../src/krikri/action_plugin_manager"

# Registered-result key orders (and spot values) for the round-993004
# kop_pkg_misc probe family - synchronize, subversion, apache2_module,
# java_cert, openssl_csr/openssl_csr_info - pinned to what REAL
# ansible-core 2.19.11 registered on the real host, captured per probe by
# the probe role's `KEYORDER|<probe>|{{ r | to_json }}` debug lines in
# ~/scratch/krt-results/993004_atlantic_local_kop_pkg_misc/cold_py.out
# (cold_py = real; the fix that aligned the plugins is commit 7eb185ad).
#
# Root-free exercisability on this dev box:
# - openssl and rsync are installed: the openssl_csr/openssl_csr_info and
#   synchronize probes run end-to-end against real tmp files/dirs.
# - svn, keytool and a2enmod/apache2ctl are NOT installed: those probes
#   run against fake-binaries-on-PATH shims (the same hermetic shim
#   approach test/integration/apache2_module_test.cr and the lvg/pv
#   tests use), scripted to emit the captured real tool output bytes.
#   The shim PATH reaches the plugin through the task's `environment:`
#   keyword (per-command exports), except java_cert, whose real module
#   probes keytool with a bare execvpe-style lookup INSIDE the plugin
#   process before any command runs - there the whole engine child gets
#   the shim PATH (per-child Process.run env, parallel-safe).
#
# The synchronize action plugin's controller-side final results register
# real's module shapes: success [changed, msg, rc, cmd, stdout_lines,
# failed] (empty msg kept, cmd carrying the resolved rsync path), failure
# [rc, cmd, failed, msg, changed, exception] - the probes below pin
# those captured orders.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# The 27-key openssl_csr_info info shape, captured identically for the
# openssl_csr_info_query, _exists and _check probes: the real module's
# get_info keys in real order (subject first, no leading changed), then
# the controller backfill failed, changed LAST.
private CSR_INFO_KEYS = [
  "subject", "subject_ordered", "key_usage", "key_usage_critical",
  "extended_key_usage", "extended_key_usage_critical", "basic_constraints",
  "basic_constraints_critical", "ocsp_must_staple", "ocsp_must_staple_critical",
  "subject_alt_name", "subject_alt_name_critical", "name_constraints_permitted",
  "name_constraints_excluded", "name_constraints_critical", "public_key",
  "public_key_type", "public_key_data", "public_key_fingerprints",
  "subject_key_identifier", "authority_key_identifier", "authority_cert_issuer",
  "authority_cert_serial_number", "extensions_by_oid", "signature_valid",
  "failed", "changed",
]

private def tool_available?(name : String) : Bool
  !Process.find_executable(name).nil?
end

# Runs one playbook through the engine and returns each probe's dumped
# registered result (`{{ r | to_json }}` through a copy task), keyed by
# the probe name the YAML embeds as KRIKRI_DUMP_DIR/<probe>.json.
# *env* adds to (never replaces) the child's environment.
private def run_probe_dumps(yaml : String, probes : Array(String), env : Hash(String, String)? = nil) : Hash(String, JSON::Any)
  dump_dir = PluginSpecHelper.tmp_path("kop-dumps")
  FileUtils.mkdir_p(dump_dir)
  playbook = File.tempname("kop-pkgmisc-keyorder", ".yml")
  File.write(playbook, yaml.gsub("KRIKRI_DUMP_DIR", dump_dir))
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, env: env)
  status.success?.must_equal(true)

  dumps = Hash(String, JSON::Any).new
  probes.each do |probe|
    path = File.join(dump_dir, "#{probe}.json")
    File.exists?(path).must_equal(true)
    dumps[probe] = JSON.parse(File.read(path))
  end
  dumps
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "kop_pkg_misc round 993004 keyorder: openssl_csr/openssl_csr_info" do
  it "registers openssl_csr's create result as [privatekey, subject, ..., diff, filename, changed, failed]" do
    # Real probe openssl_csr_info_helper_csr (the helper task that
    # generates the CSR registers the openssl_csr result itself):
    # 13 keys, ocspMustStaple spelled camelCase, the name_constraints
    # pair snake_case, diff/filename between them and the changed/failed
    # tail.
    skip("no openssl binary") unless tool_available?("openssl")

    tmp = PluginSpecHelper.tmp_path("csr-helper")
    FileUtils.mkdir_p(tmp)

    dumps = run_probe_dumps(<<-YAML, ["helper_csr"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - command: "openssl genrsa -out #{tmp}/kop.key 2048"
            changed_when: false
          - community.crypto.openssl_csr:
              path: #{tmp}/kop.csr
              privatekey_path: #{tmp}/kop.key
              subject:
                CN: kop-probe
              use_common_name_for_san: false
            register: r
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/helper_csr.json
            changed_when: false
      YAML

    dump = dumps["helper_csr"]
    dump.as_h.keys.must_equal([
      "privatekey", "subject", "subjectAltName", "keyUsage", "extendedKeyUsage",
      "basicConstraints", "ocspMustStaple", "name_constraints_permitted",
      "name_constraints_excluded", "diff", "filename", "changed", "failed",
    ])
    dump["privatekey"].as_s.must_equal("#{tmp}/kop.key")
    dump["filename"].as_s.must_equal("#{tmp}/kop.csr")
    dump["subject"].as_a[0].as_a.map(&.as_s).must_equal(["CN", "kop-probe"])
    dump["ocspMustStaple"].as_bool.must_equal(false)
    dump["subjectAltName"].raw.must_be_nil
    dump["changed"].as_bool.must_equal(true)
    dump["failed"].as_bool.must_equal(false)
  end

  it "registers openssl_csr_info's query as the 27-key subject-first info shape with failed/changed last" do
    # Real probe openssl_csr_info_query (27 keys, starts with subject,
    # no leading changed, ends failed, changed - the real module's
    # get_info keys in real order, then the controller backfill).
    skip("no openssl binary") unless tool_available?("openssl")

    tmp = PluginSpecHelper.tmp_path("csr-query")
    FileUtils.mkdir_p(tmp)

    dumps = run_probe_dumps(<<-YAML, ["query"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - command: "openssl genrsa -out #{tmp}/kop.key 2048"
            changed_when: false
          - command: >
              openssl req -new -key #{tmp}/kop.key -out #{tmp}/kop.csr
              -subj "/CN=kop-probe"
            changed_when: false
          - community.crypto.openssl_csr_info:
              path: #{tmp}/kop.csr
            register: r
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/query.json
            changed_when: false
      YAML

    dump = dumps["query"]
    dump.as_h.keys.must_equal(CSR_INFO_KEYS)
    dump["subject"].as_h["commonName"].as_s.must_equal("kop-probe")
    dump["subject_ordered"].as_a[0].as_a.map(&.as_s).must_equal(["commonName", "kop-probe"])
    dump["public_key_type"].as_s.must_equal("RSA")
    dump["signature_valid"].as_bool.must_equal(true)
    dump["public_key_data"].as_h.keys.must_equal(["size", "modulus", "exponent"])
    dump["key_usage"].raw.must_be_nil
    dump["extensions_by_oid"].as_h.must_be_empty
    dump["failed"].as_bool.must_equal(false)
    dump["changed"].as_bool.must_equal(false)
  end

  it "registers openssl_csr_info's idempotent rerun and check mode with the identical 27-key order" do
    # Real probes openssl_csr_info_exists and openssl_csr_info_check:
    # both capture the exact same 27-key list as the first query.
    skip("no openssl binary") unless tool_available?("openssl")

    tmp = PluginSpecHelper.tmp_path("csr-exists-check")
    FileUtils.mkdir_p(tmp)

    dumps = run_probe_dumps(<<-YAML, ["exists", "check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - command: "openssl genrsa -out #{tmp}/kop.key 2048"
            changed_when: false
          - command: >
              openssl req -new -key #{tmp}/kop.key -out #{tmp}/kop.csr
              -subj "/CN=kop-probe"
            changed_when: false
          - community.crypto.openssl_csr_info:
              path: #{tmp}/kop.csr
            register: r
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/exists.json
            changed_when: false
          - community.crypto.openssl_csr_info:
              path: #{tmp}/kop.csr
            check_mode: true
            register: r
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/check.json
            changed_when: false
      YAML

    dumps["exists"].as_h.keys.must_equal(CSR_INFO_KEYS)
    dumps["check"].as_h.keys.must_equal(CSR_INFO_KEYS)
    dumps["exists"]["changed"].as_bool.must_equal(false)
    dumps["check"]["changed"].as_bool.must_equal(false)
    dumps["exists"]["signature_valid"].as_bool.must_equal(true)
  end

  it "registers openssl_csr_info's missing-file failure as [failed, msg, changed, exception] with real's wording" do
    # Real probe openssl_csr_info_fail (path /var/tmp/kop_nosuch.csr):
    # [failed, msg, changed, exception], msg "Error while reading CSR
    # file from disk: [Errno 2] No such file or directory: '<path>'".
    skip("no openssl binary") unless tool_available?("openssl")

    tmp = PluginSpecHelper.tmp_path("csr-fail")
    FileUtils.mkdir_p(tmp)

    dumps = run_probe_dumps(<<-YAML, ["fail"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.crypto.openssl_csr_info:
              path: #{tmp}/kop_nosuch.csr
            register: r
            ignore_errors: true
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/fail.json
            changed_when: false
      YAML

    dump = dumps["fail"]
    dump.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
    dump["failed"].as_bool.must_equal(true)
    dump["msg"].as_s.must_equal(
      "Error while reading CSR file from disk: [Errno 2] No such file or directory: '#{tmp}/kop_nosuch.csr'"
    )
    dump["changed"].as_bool.must_equal(false)
    dump["exception"].as_s.must_equal("(traceback unavailable)")
  end
end

describe "kop_pkg_misc round 993004 keyorder: apache2_module failure" do
  it "registers the a2enmod failure as [rc, stdout, stderr, failed, msg, stdout_lines, stderr_lines, changed, exception]" do
    # Real probe apache2_module_fail (enable a nonexistent module):
    # real's a2enmod exits 1 with "ERROR: Module <name> does not exist!"
    # on stderr; the registered result carries the command-tool kwargs
    # lead, failed/msg mid-order, the controller's *_lines splits, then
    # changed and exception LAST. The exact captured msg names the
    # guessed identifier and the "identifier" option hint.
    tmp = PluginSpecHelper.tmp_path("apache2-fail")
    FileUtils.mkdir_p(tmp)

    dumps = run_probe_dumps(<<-YAML, ["fail"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.general.apache2_module:
              name: kop_bogus_module
              state: present
            environment:
              PATH: "#{tmp}/shim:/usr/bin:/bin"
            register: r
            ignore_errors: true
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/fail.json
            changed_when: false
      YAML

    dump = dumps["fail"]
    dump.as_h.keys.must_equal([
      "rc", "stdout", "stderr", "failed", "msg",
      "stdout_lines", "stderr_lines", "changed", "exception",
    ])
    dump["rc"].as_i.must_equal(1)
    dump["stdout"].as_s.must_equal("")
    dump["stderr"].as_s.must_equal("ERROR: Module kop_bogus_module does not exist!\n")
    dump["msg"].as_s.must_equal(
      "Failed to set module kop_bogus_module to enabled:\n\n" \
      "Maybe the module identifier (kop_bogus_module_module) was guessed incorrectly." \
      "Consider setting the \"identifier\" option."
    )
    dump["stdout_lines"].as_a.must_be_empty
    dump["stderr_lines"].as_a.map(&.as_s).must_equal(["ERROR: Module kop_bogus_module does not exist!"])
    dump["changed"].as_bool.must_equal(false)
    dump["exception"].as_s.must_equal("(traceback unavailable)")
  end

  before_each do
    # The shims the test's PATH points at: apache2ctl -M reports an
    # empty loaded-modules set, a2enmod rejects everything with real's
    # stderr bytes (captured verbatim in the round's cold_py.out).
    FileUtils.mkdir_p(PluginSpecHelper.tmp_path("apache2-fail/shim"))
    apache2ctl = File.join(PluginSpecHelper.tmp_path("apache2-fail/shim"), "apache2ctl")
    File.write(apache2ctl, "#!/bin/sh\nif [ \"$1\" = \"-M\" ]; then\n  echo \"Loaded Modules:\"\n  exit 0\nfi\nexit 64\n")
    File.chmod(apache2ctl, 0o755)
    a2enmod = File.join(PluginSpecHelper.tmp_path("apache2-fail/shim"), "a2enmod")
    File.write(a2enmod, "#!/bin/sh\nname=\"$1\"\necho \"ERROR: Module ${name} does not exist!\" >&2\nexit 1\n")
    File.chmod(a2enmod, 0o755)
  end
end

describe "kop_pkg_misc round 993004 keyorder: subversion failure" do
  it "registers the svn checkout failure as [cmd, rc, stdout, stderr, failed, msg, stdout_lines, stderr_lines, changed, exception]" do
    # Real probe subversion_fail (checkout a nonexistent file:// repo):
    # run_command(check_rc=True)'s own failure shape - cmd/rc/stdout/
    # stderr lead, failed/msg follow, the *_lines splits, then changed
    # and exception. The shim emits the captured svn stderr bytes, so
    # msg (rstripped stderr) and stderr match the capture verbatim.
    tmp = PluginSpecHelper.tmp_path("svn-fail")
    FileUtils.mkdir_p(tmp)

    dumps = run_probe_dumps(<<-YAML, ["fail"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.subversion:
              repo: file:///var/tmp/kop_nosuchrepo
              dest: #{tmp}/wc3
            environment:
              PATH: "#{tmp}/shim:/usr/bin:/bin"
            register: r
            ignore_errors: true
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/fail.json
            changed_when: false
      YAML

    dump = dumps["fail"]
    dump.as_h.keys.must_equal([
      "cmd", "rc", "stdout", "stderr", "failed", "msg",
      "stdout_lines", "stderr_lines", "changed", "exception",
    ])
    dump["cmd"].as_s.must_include("--non-interactive --no-auth-cache --trust-server-cert checkout -r HEAD file:///var/tmp/kop_nosuchrepo")
    dump["rc"].as_i.must_equal(1)
    dump["stdout"].as_s.must_equal("")
    dump["stderr"].as_s.must_equal(
      "svn: E170013: Unable to connect to a repository at URL 'file:///var/tmp/kop_nosuchrepo'\n" \
      "svn: E180001: Unable to open repository 'file:///var/tmp/kop_nosuchrepo'\n"
    )
    dump["msg"].as_s.must_equal(
      "svn: E170013: Unable to connect to a repository at URL 'file:///var/tmp/kop_nosuchrepo'\n" \
      "svn: E180001: Unable to open repository 'file:///var/tmp/kop_nosuchrepo'"
    )
    dump["stdout_lines"].as_a.must_be_empty
    dump["stderr_lines"].as_a.map(&.as_s).must_equal([
      "svn: E170013: Unable to connect to a repository at URL 'file:///var/tmp/kop_nosuchrepo'",
      "svn: E180001: Unable to open repository 'file:///var/tmp/kop_nosuchrepo'",
    ])
    dump["changed"].as_bool.must_equal(false)
    dump["exception"].as_s.must_equal("(traceback unavailable)")
  end

  before_each do
    FileUtils.mkdir_p(PluginSpecHelper.tmp_path("svn-fail/shim"))
    svn = File.join(PluginSpecHelper.tmp_path("svn-fail/shim"), "svn")
    File.write(svn, "#!/bin/sh\necho \"svn: E170013: Unable to connect to a repository at URL 'file:///var/tmp/kop_nosuchrepo'\" >&2\necho \"svn: E180001: Unable to open repository 'file:///var/tmp/kop_nosuchrepo'\" >&2\nexit 1\n")
    File.chmod(svn, 0o755)
  end
end

describe "kop_pkg_misc round 993004 keyorder: java_cert (keytool shim)" do
  @java_cert_keystore : String? = nil
  @java_cert_cert : String? = nil
  @java_cert_missing : String? = nil

  it "registers the fresh import as [changed, msg, rc, cmd, stdout, error, diff, stdout_lines, failed]" do
    # Real probe java_cert_import: exit_json(changed=True, msg=, rc=,
    # cmd=, stdout=, error=, diff=) - msg is the empty stdout (kept),
    # keytool's prompts/receipt ride on stderr as `error`, and the
    # controller backfills failed last. cmd is the ARGV list.
    dump = run_java_cert_probe("import")

    dump.as_h.keys.must_equal([
      "changed", "msg", "rc", "cmd", "stdout", "error", "diff", "stdout_lines", "failed",
    ])
    dump["changed"].as_bool.must_equal(true)
    dump["msg"].as_s.must_equal("")
    dump["rc"].as_i.must_equal(0)
    dump["cmd"].as_a.map(&.as_s).must_equal([
      "keytool", "-importcert", "-noprompt",
      "-keystore", @java_cert_keystore.not_nil!,
      "-file", @java_cert_cert.not_nil!,
      "-alias", "kopcert",
    ])
    dump["stdout"].as_s.must_equal("")
    dump["error"].as_s.must_equal("Enter keystore password:  Re-enter new password: Certificate was added to keystore\n")
    dump["diff"]["before"].as_s.must_equal("\n")
    dump["diff"]["after"].as_s.must_equal("kopcert\n")
    dump["stdout_lines"].as_a.must_be_empty
    dump["failed"].as_bool.must_equal(false)
  end

  it "registers the same-cert rerun as just [changed, failed]" do
    # Real probe java_cert_exists (import the same cert again): the
    # digest matches, result stays the empty dict - registered shape is
    # only changed: false + failed: false.
    dump = run_java_cert_probe("exists")

    dump.as_h.keys.must_equal(["changed", "failed"])
    dump["changed"].as_bool.must_equal(false)
    dump["failed"].as_bool.must_equal(false)
  end

  it "registers the check-mode second-alias import as just [changed, failed] with changed: true" do
    # Real probe java_cert_check (import a second alias in check mode):
    # check mode exits changed=true without running the mutation - the
    # registered shape is only [changed, failed].
    dump = run_java_cert_probe("check")

    dump.as_h.keys.must_equal(["changed", "failed"])
    dump["changed"].as_bool.must_equal(true)
    dump["failed"].as_bool.must_equal(false)
  end

  it "registers the alias removal as [changed, msg, rc, cmd, stdout, error, diff, stdout_lines, failed]" do
    # Real probe java_cert_remove (state: absent on the imported alias):
    # same import-family shape, diff before "kopcert\n" / after null,
    # keytool's bare password prompt rides on stderr as `error`.
    dump = run_java_cert_probe("remove")

    dump.as_h.keys.must_equal([
      "changed", "msg", "rc", "cmd", "stdout", "error", "diff", "stdout_lines", "failed",
    ])
    dump["changed"].as_bool.must_equal(true)
    dump["msg"].as_s.must_equal("")
    dump["rc"].as_i.must_equal(0)
    dump["cmd"].as_a.map(&.as_s).must_equal([
      "keytool", "-delete", "-noprompt",
      "-keystore", @java_cert_keystore.not_nil!,
      "-alias", "kopcert",
    ])
    dump["error"].as_s.must_equal("Enter keystore password:  ")
    dump["diff"]["before"].as_s.must_equal("kopcert\n")
    dump["diff"]["after"].raw.must_be_nil
    dump["failed"].as_bool.must_equal(false)
  end

  it "registers the unreadable-cert failure as [rc, cmd, failed, msg, changed, exception]" do
    # Real probe java_cert_fail (import a nonexistent cert): the
    # openssl x509 extraction fails (PEM attempt, then the captured DER
    # fallback), fail_json(msg=..., rc=, cmd=) with kwargs lead - cmd is
    # the DER-fallback ARGV - and the controller backfills changed then
    # exception.
    dump = run_java_cert_probe("fail")

    dump.as_h.keys.must_equal(["rc", "cmd", "failed", "msg", "changed", "exception"])
    dump["rc"].as_i.must_equal(1)
    cmd = dump["cmd"].as_a.map(&.as_s)
    cmd.first.must_equal("/usr/bin/openssl")
    cmd[-2..].must_equal(["-inform", "der"])
    cmd.must_include(@java_cert_missing.not_nil!)
    dump["msg"].as_s.starts_with?("Internal module failure, cannot extract certificate, error: ").must_equal(true)
    dump["changed"].as_bool.must_equal(false)
    dump["exception"].as_s.must_equal("(traceback unavailable)")
  end

  # Replays the probe role's java_cert sequence (import -> exists ->
  # check -> remove, plus the missing-cert failure) in ONE engine run so
  # the shim keystore state evolves exactly like the capture's. The
  # engine child gets the shim PATH: real's test_keytool probes keytool
  # with a bare execvpe-style lookup inside the plugin process before any
  # shell command runs, so the task `environment:` exports never reach
  # it. The shim is a text-file "keystore" whose -list output is a real
  # PEM certificate (the plugin sha256-digests it through real openssl
  # to decide idempotency).
  private def run_java_cert_probe(probe : String) : JSON::Any
    tmp = PluginSpecHelper.tmp_path("java-cert")
    FileUtils.mkdir_p(File.join(tmp, "shim"))
    keystore = File.join(tmp, "kop_ks.jks")
    cert = File.join(tmp, "shim", "kop_cert.pem")
    missing = File.join(tmp, "kop_nosuch.pem")
    @java_cert_keystore = keystore
    @java_cert_cert = cert
    @java_cert_missing = missing

    File.delete(keystore) if File.exists?(keystore)
    unless File.exists?(cert)
      Process.run("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
                              "-keyout", File.join(tmp, "kop_cert.key"), "-out", cert,
                              "-days", "2", "-subj", "/CN=kop-probe"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
    end
    File.exists?(cert).must_equal(true)

    env = {
      "PATH"              => "#{File.join(tmp, "shim")}:#{ENV["PATH"]}",
      "KOP_KEYSTORE_FILE" => keystore,
      "KOP_CERT_FILE"     => cert,
    }

    yaml = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - community.general.java_cert:
              cert_path: #{cert}
              keystore_path: #{keystore}
              keystore_pass: kopKeystorePass1
              keystore_create: true
              cert_alias: kopcert
              state: present
            register: r
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/import.json
            changed_when: false
          - community.general.java_cert:
              cert_path: #{cert}
              keystore_path: #{keystore}
              keystore_pass: kopKeystorePass1
              keystore_create: true
              cert_alias: kopcert
              state: present
            register: r
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/exists.json
            changed_when: false
          - community.general.java_cert:
              cert_path: #{cert}
              keystore_path: #{keystore}
              keystore_pass: kopKeystorePass1
              keystore_create: true
              cert_alias: kopcert2
              state: present
            check_mode: true
            register: r
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/check.json
            changed_when: false
          - community.general.java_cert:
              cert_path: #{cert}
              keystore_path: #{keystore}
              keystore_pass: kopKeystorePass1
              cert_alias: kopcert
              state: absent
            register: r
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/remove.json
            changed_when: false
          - community.general.java_cert:
              cert_path: #{missing}
              keystore_path: #{keystore}
              keystore_pass: kopKeystorePass1
              keystore_create: true
              cert_alias: kopfail
              state: present
            register: r
            ignore_errors: true
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/fail.json
            changed_when: false
      YAML
    dumps = run_probe_dumps(yaml, ["import", "exists", "check", "remove", "fail"], env)
    dumps[probe]
  end

  before_each do
    FileUtils.mkdir_p(PluginSpecHelper.tmp_path("java-cert/shim"))
    keytool = File.join(PluginSpecHelper.tmp_path("java-cert/shim"), "keytool")
    File.write(keytool, <<-SCRIPT)
      #!/bin/sh
      STORE="$KOP_KEYSTORE_FILE"
      CERT="$KOP_CERT_FILE"
      [ -n "$STORE" ] || exit 1
      prev=""
      for a in "$@"; do
        case "$prev" in
          -keystore) KS="$a" ;;
          -alias) ALIAS="$a" ;;
        esac
        prev="$a"
      done
      case "$1" in
        "") exit 0 ;;
        -list)
          if [ -f "$KS" ] && grep -qxF "$ALIAS" "$KS"; then
            cat "$CERT"
            exit 0
          fi
          exit 1 ;;
        -importcert)
          echo "$ALIAS" >> "$KS"
          echo "Enter keystore password:  Re-enter new password: Certificate was added to keystore" >&2
          exit 0 ;;
        -delete)
          grep -vxF "$ALIAS" "$KS" > "$KS.tmp"; mv "$KS.tmp" "$KS"
          printf 'Enter keystore password:  ' >&2
          exit 0 ;;
      esac
      exit 1
    SCRIPT
    File.chmod(keytool, 0o755)
  end
end

describe "kop_pkg_misc round 993004 keyorder: synchronize (delegate_to same host)" do
  @sync_tmp : String? = nil

  it "registers the push as [changed, msg, rc, cmd, stdout_lines, failed]" do
    skip("no rsync binary") unless tool_available?("rsync")

    dump = run_synchronize_probes["push"]

    dump.as_h.keys.must_equal(["changed", "msg", "rc", "cmd", "stdout_lines", "failed"])
    dump["changed"].as_bool.must_equal(true)
    dump["msg"].as_s.must_include("cd+++++++++ ./")
    dump["msg"].as_s.must_include(">f+++++++++ a")
    dump["rc"].as_i.must_equal(0)
    cmd = dump["cmd"].as_s
    cmd.must_include("--delay-updates -F --compress --archive")
    cmd.must_include("#{@sync_tmp.not_nil!}/src/")
    cmd.must_include("#{@sync_tmp.not_nil!}/dst/")
    # delegate_to-same-host: plain local paths, no remote-shell munging.
    cmd.wont_include("@")
    cmd.wont_include("--rsh")
    cmd.wont_include("-S none")
    cmd.wont_include(" -i ")
    # rsync >= 3.2.7 prints its own "created directory <dst>" line on
    # STDOUT when the destination dir is missing (its guard gained
    # `|| stdout_format_has_i` next to INFO_GTE(NAME); the real host's
    # rsync 3.2.3 printed it only at -v, so the capture carries no such
    # line). The probe keeps dst missing like the real role does, so the
    # version artifact is filtered here instead of papered over by
    # pre-creating dst (which would also drop the cd+++++++++ ./ line
    # the capture does carry).
    lines = dump["stdout_lines"].as_a.map(&.as_s).reject(&.starts_with?("created directory "))
    lines.must_equal(["cd+++++++++ ./", ">f+++++++++ a"])
    dump["failed"].as_bool.must_equal(false)
  end

  it "registers the idempotent rerun with real's empty msg key kept" do
    skip("no rsync binary") unless tool_available?("rsync")

    dump = run_synchronize_probes["exists"]

    dump.as_h.keys.must_equal(["changed", "msg", "rc", "cmd", "stdout_lines", "failed"])
    dump["changed"].as_bool.must_equal(false)
    dump["msg"].as_s.must_equal("")
    dump["stdout_lines"].as_a.must_be_empty
  end

  it "registers the check-mode rerun (nothing left to change) with the same shape" do
    skip("no rsync binary") unless tool_available?("rsync")

    dump = run_synchronize_probes["check"]

    dump.as_h.keys.must_equal(["changed", "msg", "rc", "cmd", "stdout_lines", "failed"])
    dump["changed"].as_bool.must_equal(false)
    dump["cmd"].as_s.must_include("--dry-run")
  end

  it "registers the missing-source failure as [rc, cmd, failed, msg, changed, exception]" do
    skip("no rsync binary") unless tool_available?("rsync")

    dump = run_synchronize_probes["fail"]

    dump.as_h.keys.must_equal(["rc", "cmd", "failed", "msg", "changed", "exception"])
    dump["rc"].as_i.must_equal(23)
    dump["msg"].as_s.must_include("No such file or directory")
    dump["changed"].as_bool.must_equal(false)
    dump["exception"].as_s.must_equal("(traceback unavailable)")
  end

  # The probe role's synchronize sequence (push -> push again -> push in
  # check mode -> push a nonexistent source), delegate_to:
  # "{{ inventory_hostname }}" like every probe task. The check probe
  # runs after two real pushes, so its dry run finds nothing to change -
  # exactly like the capture. dst is NOT pre-created: the real probe
  # role only creates src (tasks/main.yml has no dst task), and the
  # captured cd+++++++++ ./ itemize line is rsync CREATING dst - a
  # pre-created dst would drop that line entirely.
  private def run_synchronize_probes : Hash(String, JSON::Any)
    tmp = PluginSpecHelper.tmp_path("synchronize")
    @sync_tmp = tmp
    FileUtils.mkdir_p(File.join(tmp, "src"))
    File.write(File.join(tmp, "src", "a"), "kop-probe-payload\n")

    run_probe_dumps(<<-YAML, ["push", "exists", "check", "fail"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.posix.synchronize:
              src: #{tmp}/src/
              dest: #{tmp}/dst/
              mode: push
            delegate_to: "{{ inventory_hostname }}"
            register: r
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/push.json
            changed_when: false
          - ansible.posix.synchronize:
              src: #{tmp}/src/
              dest: #{tmp}/dst/
              mode: push
            delegate_to: "{{ inventory_hostname }}"
            register: r
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/exists.json
            changed_when: false
          - ansible.posix.synchronize:
              src: #{tmp}/src/
              dest: #{tmp}/dst/
              mode: push
            delegate_to: "{{ inventory_hostname }}"
            check_mode: true
            register: r
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/check.json
            changed_when: false
          - ansible.posix.synchronize:
              src: #{tmp}/nosuch_src/
              dest: #{tmp}/dst/
              mode: push
            delegate_to: "{{ inventory_hostname }}"
            register: r
            ignore_errors: true
          - copy:
              content: "{{ r | to_json }}"
              dest: KRIKRI_DUMP_DIR/fail.json
            changed_when: false
      YAML
  end
end

describe "SynchronizeActionPlugin delegate_to same-host rsync locality (round 993004)" do
  # Unit-level pin of the action plugin's delegate_to: "<inventory
  # hostname>" decision itself (the probe role's spelling on every
  # synchronize task): when the delegate IS the task's own host, rsync
  # must run ON that host with two plain local paths - no --rsh, no
  # `ssh -S none`, no private-key -i, no user@host: qualification on
  # either end, whichever way the module actually gets there.
  it "hands the params back unchanged for on-host module dispatch when the same-host delegate is non-local" do
    # Real's dest_is_local case: delegate_to naming the task's own host
    # returns use_delegate=true and the action plugin munges NOTHING -
    # the module runs on that host and rsync syncs the two plain paths
    # there (verified live vs ansible-core 2.19 + ansible.posix).
    task_host = Krikri::Host.new("kop-sync-self-host")
    plugin = Krikri::SynchronizeActionPlugin.new({
      "src"  => "/tmp/kop-sync-self-src/",
      "dest" => "/tmp/kop-sync-self-dst/",
    }, Hash(String, JSON::Any).new, task_host, nil, task_host)
    result = plugin.execute

    result.success?.must_equal(true)
    result.final_result.must_be_nil
    result.modified_params.must_equal({
      "src"  => "/tmp/kop-sync-self-src/",
      "dest" => "/tmp/kop-sync-self-dst/",
    })
  end

  it "runs rsync locally with plain paths when the same-host delegate's connection is local" do
    skip("no rsync binary") unless tool_available?("rsync")

    tmp = PluginSpecHelper.tmp_path("synchronize-unit-local")
    FileUtils.mkdir_p(File.join(tmp, "src"))
    File.write(File.join(tmp, "src", "a"), "kop-probe-payload\n")
    host = Krikri::Host.new("localhost")
    host.vars["ansible_connection"] = JSON::Any.new("local")
    plugin = Krikri::SynchronizeActionPlugin.new({
      "src"  => "#{tmp}/src/",
      "dest" => "#{tmp}/dst/",
      "mode" => "push",
    }, Hash(String, JSON::Any).new, host, nil, host)
    result = plugin.execute

    json = result.final_result || raise "expected a final result"
    json.as_h["changed"].as_bool.must_equal(true)
    json.as_h["rc"].as_i.must_equal(0)
    cmd = json.as_h["cmd"].as_s
    cmd.must_include("#{tmp}/src/")
    cmd.must_include("#{tmp}/dst/")
    cmd.wont_include("@")
    cmd.wont_include("--rsh")
    cmd.wont_include("-S none")
    cmd.wont_include(" -i ")
    File.read(File.join(tmp, "dst", "a")).must_equal("kop-probe-payload\n")
  end
end
