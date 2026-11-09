require "../minitest_helper"
require "json"
require "../../src/krikri/onepassword_lookup"
require "../../src/krikri/variable_substitutor/expression_evaluator"
require "../../src/krikri/krikri_jinja_lookups"
require "../../src/krikri/krikri_jinja_filters"

# Issue #1059: lookup('community.general.onepassword', ...) degraded to
# the "undefined" sentinel (the task silently succeeded with the literal
# text "undefined" as the fetched key) for an INSTALLED collection - the
# dispatch chain had no arm for collection lookups and PythonLookupRunner
# deliberately does not reach inside installed collections - and never
# failed even when the item did not exist. Both dispatchers run against a
# stub `op` CLI whose canned responses are exactly what `op` prints; the
# failure shapes are live-verified against ansible-core 2.21 +
# community.general, whose plugin raises `AnsibleLookupError(str(err))`
# on stderr BYTES - the `b'...'` repr inside the failure message is
# ansible's own wording, reproduced byte for byte.
describe "community.general.onepassword lookup (onepassword_lookup_test.cr)" do
  exclusive! # PATH is replaced outright (a stub-only PATH), process-wide state

  PUBLIC_KEY = "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmQENBFstubKEY\n=krikri\n" \
               "-----END PGP PUBLIC KEY BLOCK-----\n"
  PASSWORD = "OctoberPoppyNuttyDraperySabbath"

  before_each do
    @old = {
      "PATH"                     => ENV["PATH"]?,
      "OP_SERVICE_ACCOUNT_TOKEN" => ENV["OP_SERVICE_ACCOUNT_TOKEN"]?,
      "OP_CONNECT_HOST"          => ENV["OP_CONNECT_HOST"]?,
      "OP_CONNECT_TOKEN"         => ENV["OP_CONNECT_TOKEN"]?,
    }
    ENV.delete("OP_SERVICE_ACCOUNT_TOKEN")
    ENV.delete("OP_CONNECT_HOST")
    ENV.delete("OP_CONNECT_TOKEN")
  end

  after_each do
    @old.try do |saved|
      saved.each do |key, value|
        if value
          ENV[key] = value
        else
          ENV.delete(key)
        end
      end
    end
  end

  # Writes a stub `op` into its own scratch dir and points PATH at it (and
  # nothing else): every command the lookup runs lands in op.log, the item
  # payload comes from item.json and a failing `op` prints stderr.txt.
  private def install_op(version : String, item_json : String? = nil, item_stderr : String? = nil) : String
    dir = PluginSpecHelper.tmp_path("onepassword-op")
    Dir.mkdir_p(dir)
    log = File.join(dir, "op.log")
    fixture = ""
    if item_json
      fixture = File.join(dir, "item.json")
      File.write(fixture, item_json)
    end
    stderr_fixture = File.join(dir, "stderr.txt")
    File.write(stderr_fixture, item_stderr) if item_stderr
    script = <<-SH
      #!/bin/bash
      echo "$@" >> "#{log}"
      if [ "$1" = "--version" ]; then
        echo "#{version}"
        exit 0
      fi
      case "$1 $2" in
        "account list")
          echo '[{"url":"my.1password.com","email":"user@example.com"}]'
          exit 0
          ;;
        "account get"|"get account")
          exit 0
          ;;
      esac
      if [ "$1" = "item" ] || [ "$1" = "get" ]; then
        if [ -n "#{fixture}" ]; then
          /bin/cat "#{fixture}"
          exit 0
        fi
        /bin/cat "#{stderr_fixture}" >&2
        exit 1
      fi
      exit 0
      SH
    op_path = File.join(dir, "op")
    File.write(op_path, script)
    File.chmod(op_path, 0o755)
    File.delete(log) if File.exists?(log)
    ENV["PATH"] = dir
    log
  end

  private def item_json_v2 : String
    {
      "id"       => "ywvdbojsguzgrgnokmcxtydgdv",
      "title"    => "Repro Item",
      "version"  => 1,
      "vault"    => {"id" => "bcqxysvcnejjrwzoqrwzcqjqxc", "name" => "DevOps"},
      "category" => "LOGIN",
      "fields"   => [
        {"id" => "username", "type" => "STRING", "purpose" => "USERNAME",
         "label" => "username", "value" => "repro.user"},
        {"id" => "public", "type" => "STRING", "label" => "public", "value" => PUBLIC_KEY},
        {"id" => "password", "type" => "CONCEALED", "purpose" => "PASSWORD",
         "label" => "password", "value" => PASSWORD},
      ],
    }.to_json
  end

  private def item_json_v1 : String
    {
      "uuid"         => "stubs1234567890abcdef",
      "templateUuid" => "001",
      "overview"     => {"title" => "Repro Item"},
      "details"      => {
        "notesPlain"      => "",
        "password"        => PASSWORD,
        "passwordHistory" => [] of String,
        "fields"          => [
          {"designation" => "username", "name" => "username", "type" => "T", "value" => "repro.user"},
          {"designation" => "password", "name" => "password", "type" => "P", "value" => PASSWORD},
          {"name" => "public", "type" => "S", "value" => PUBLIC_KEY},
        ],
        "sections" => [{"name" => "linked items", "title" => "Related Items"}],
      },
    }.to_json
  end

  # `op`'s own stderr for a missing item, and the exact Python bytes repr
  # of it ansible prints in the task failure (captured live from
  # ansible-core 2.21 + community.general against the same stub).
  private def missing_item_stderr : String
    "[ERROR] 2026/11/09 12:00:00 \"no-such-item-xyz\" isn't an item in the \"DevOps\" vault.\n"
  end

  private def missing_item_error : String
    "The lookup plugin 'community.general.onepassword' failed: " \
    "b'[ERROR] 2026/11/09 12:00:00 \"no-such-item-xyz\" isn\\'t an item in the \"DevOps\" vault.\\n'"
  end

  it "fails the task with the plugin's Python bytes-repr of op's stderr when the item is missing" do
    # ansible: "The lookup plugin 'community.general.onepassword' failed:
    # b'[ERROR] ... \"no-such-item-xyz\" isn\'t an item in the \"DevOps\"
    # vault.\n'", exit 2 - the old dispatch never failed at all (it
    # returned "undefined").
    install_op("2.30.0", item_stderr: missing_item_stderr)
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    error = assert_raises(Krikri::PythonLookupRunner::LookupError) do
      evaluator.evaluate("lookup('community.general.onepassword', 'no-such-item-xyz', " \
                         "field='public', vault='DevOps')")
    end
    error.message.must_equal(missing_item_error)
  end

  it "fails the same way through the krikri-jinja lookup() dispatch" do
    install_op("2.30.0", item_stderr: missing_item_stderr)
    error = assert_raises(Krikri::PythonLookupRunner::LookupError) do
      KrikriJinja.render("{{ lookup('community.general.onepassword', 'no-such-item-xyz', " \
                         "field='public', vault='DevOps') }}", {} of String => JSON::Any)
    end
    error.message.must_equal(missing_item_error)
  end

  it "returns the field value for a found item and runs the v2 item command shape" do
    log = install_op("2.30.0", item_json: item_json_v2)
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('community.general.onepassword', 'repro-item', " \
                       "field='public', vault='DevOps')").must_equal(PUBLIC_KEY)
    File.read_lines(log).must_equal([
      "--version",
      "account list",
      "account get",
      "item get repro-item --format json --vault=DevOps",
    ])
  end

  it "returns the field value through the krikri-jinja lookup() dispatch" do
    install_op("2.30.0", item_json: item_json_v2)
    KrikriJinja.render("{{ lookup('community.general.onepassword', 'repro-item', " \
                       "field='public', vault='DevOps') }}", {} of String => JSON::Any)
      .must_equal(PUBLIC_KEY)
  end

  it "defaults to the password field like the plugin's documented default" do
    install_op("2.30.0", item_json: item_json_v2)
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('community.general.onepassword', 'repro-item', " \
                       "vault='DevOps')").must_equal(PASSWORD)
  end

  it "reads the v1 CLI item payload shape" do
    log = install_op("1.12.3", item_json: item_json_v1)
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('community.general.onepassword', 'repro-item', " \
                       "field='public', vault='DevOps')").must_equal(PUBLIC_KEY)
    File.read_lines(log).must_equal([
      "--version",
      "get account",
      "get item repro-item --vault=DevOps",
    ])
  end

  it "fails with get_bin_path wording when no op binary exists" do
    dir = PluginSpecHelper.tmp_path("onepassword-empty")
    Dir.mkdir_p(dir)
    ENV["PATH"] = dir
    expected_paths = [dir] of String
    {"/sbin", "/usr/sbin", "/usr/local/sbin"}.each do |extra|
      expected_paths << extra if Dir.exists?(extra)
    end
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    error = assert_raises(Krikri::PythonLookupRunner::LookupError) do
      evaluator.evaluate("lookup('onepassword', 'no-such-item-xyz')")
    end
    # The wrapper prefix carries the name AS SPELLED - a bare `onepassword`
    # says 'onepassword' (ansible words the failure with the invoked name).
    error.message.must_equal(
      "The lookup plugin 'onepassword' failed: Unable to locate 'op' command line tool: " \
      "Failed to find required executable \"op\" in paths: #{expected_paths.join(':')}")
  end

  it "fails with the plugin's own unsupported-version message" do
    install_op("3.0.0")
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    error = assert_raises(Krikri::PythonLookupRunner::LookupError) do
      evaluator.evaluate("lookup('community.general.onepassword', 'repro-item')")
    end
    error.message.must_equal(
      "The lookup plugin 'community.general.onepassword' failed: op version 3.0.0 is unsupported")
  end

  it "keeps the generic errors= option from failing the task" do
    # ansible's errors='ignore' and errors='warn' both carry on with an
    # empty result (live-verified 2.21: "IGNORED=[]"/"WARNED=[]" in the
    # surrounding text) - only strict, the default, fails (the same split
    # the file/template lookups make).
    install_op("2.30.0", item_stderr: missing_item_stderr)
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('community.general.onepassword', 'no-such-item-xyz', " \
                       "field='public', vault='DevOps', errors='ignore')").must_equal("")
    evaluator.evaluate("lookup('community.general.onepassword', 'no-such-item-xyz', " \
                       "field='public', vault='DevOps', errors='warn')").must_equal("")
    KrikriJinja.render("IGNORED=[{{ lookup('community.general.onepassword', 'no-such-item-xyz', " \
                       "field='public', vault='DevOps', errors='ignore') }}]",
      {} of String => JSON::Any).must_equal("IGNORED=[]")
  end
end
