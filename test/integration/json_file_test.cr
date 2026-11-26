require "file_utils"
require "../minitest_helper"
require "../../src/krikri/param_sentinels"

# json_file - krikri's own JSON file editor (issue #1835), the JSON
# counterpart to ini_file. It has no ansible-playbook counterpart to diff
# against (ansible-core and community.general ship no file-editing JSON
# module), so these are plain regression specs rather than divergence
# corpus cases.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

# The param wire is strings-only: a non-string YAML scalar literal
# (`value: 5`) reaches a plugin carrying the parser's own marker, and a
# container arrives as text. Both shapes are reproduced here.
private def marked(json : String) : String
  Krikri::NON_STRING_PARAM_PREFIX + json
end

# Like PluginSpecHelper.tmp_path, but creates the file's parent directory
# (the per-test scratch subtree exists; a nested path under it does not).
private def tmp_file(name : String) : String
  path = PluginSpecHelper.tmp_path(name)
  Dir.mkdir_p(File.dirname(path))
  path
end

private def write_json(path : String, content : String) : Nil
  File.write(path, content)
end

describe "json_file plugin" do
  it "creates a missing file with the nested key, two-space indented" do
    path = tmp_file("json_file-create/new.json")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "logging.level", "value" => "debug"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("key added")
    File.read(path).must_equal("{\n  \"logging\": {\n    \"level\": \"debug\"\n  }\n}\n")
  end

  it "is idempotent on a second run" do
    path = tmp_file("json_file-idempotent.json")
    write_json(path, "{\n  \"a\": {\n    \"b\": 1\n  }\n}\n")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a.b", "value" => marked("1")})

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("ok")
  end

  it "keeps the document's key order and its own four-space indentation" do
    path = tmp_file("json_file-indent.json")
    write_json(path, "{\n    \"z\": 1,\n    \"a\": {\n        \"b\": 2\n    }\n}\n")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a.c", "value" => "x"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("{\n    \"z\": 1,\n    \"a\": {\n        \"b\": 2,\n        \"c\": \"x\"\n    }\n}\n")
  end

  it "leaves a compact single-line document compact" do
    path = tmp_file("json_file-compact.json")
    write_json(path, %({"a":1,"b":{"c":2}}))

    PluginSpecHelper.run("json_file", {"path" => path, "key" => "b.d", "value" => "x"})

    File.read(path).must_equal(%({"a":1,"b":{"c":2,"d":"x"}}))
  end

  it "honors an explicit indent override" do
    path = tmp_file("json_file-indent-override.json")

    PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => "b", "indent" => "4"})

    File.read(path).must_equal("{\n    \"a\": \"b\"\n}\n")
  end

  it "removes a key with state=absent and reports an absent path as unchanged" do
    path = tmp_file("json_file-absent.json")
    write_json(path, "{\n  \"a\": 1,\n  \"b\": 2\n}\n")

    removed = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "state" => "absent"})
    removed["changed"].as_bool.must_equal(true)
    removed["msg"].as_s.must_equal("key removed")
    File.read(path).must_equal("{\n  \"b\": 2\n}\n")

    missing = PluginSpecHelper.run("json_file", {"path" => path, "key" => "nope.deep", "state" => "absent"})
    missing["changed"].as_bool.must_equal(false)
  end

  it "updates an existing array element and appends at the end, failing past it" do
    path = tmp_file("json_file-array.json")
    write_json(path, %({"servers":[{"host":"a"},{"host":"b"}]}))

    updated = PluginSpecHelper.run("json_file", {"path" => path, "key" => "servers.1.host", "value" => "c"})
    updated["changed"].as_bool.must_equal(true)
    File.read(path).must_equal(%({"servers":[{"host":"a"},{"host":"c"}]}))

    appended = PluginSpecHelper.run("json_file", {"path" => path, "key" => "servers.2.host", "value" => "d"})
    appended["changed"].as_bool.must_equal(true)
    File.read(path).must_equal(%({"servers":[{"host":"a"},{"host":"c"},{"host":"d"}]}))

    refused = PluginSpecHelper.run("json_file", {"path" => path, "key" => "servers.9.host", "value" => "e"})
    refused["failed"].as_bool.must_equal(true)
    refused["msg"].as_s.must_include("out of range")
  end

  it "addresses a key containing a dot through the list form" do
    path = tmp_file("json_file-dotted-key.json")
    write_json(path, "{\n  \"a.b\": 1\n}\n")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => %(["a.b"]), "value" => marked("2")})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("{\n  \"a.b\": 2\n}\n")
  end

  it "writes a container-looking text as a JSON string under value_type=string" do
    path = tmp_file("json_file-value-type.json")
    write_json(path, "{\n  \"a\": 1\n}\n")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => %({"nested":true}), "value_type" => "string"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("{\n  \"a\": \"{\\\"nested\\\":true}\"\n}\n")
  end

  it "parses a container-looking value as a JSON object by default" do
    path = tmp_file("json_file-value-json.json")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => %({"nested":true})})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("{\n  \"a\": {\n    \"nested\": true\n  }\n}\n")
  end

  it "rejects a list-form key that does not parse as a list" do
    # A typo'd `key: "[a.b]"` used to fall through to the dot split and
    # write garbage keys ("[a" / "b]") into the file.
    path = tmp_file("json_file-bad-list-key.json")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "[a.b]", "value" => "x"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("not a JSON list of segments")
    File.exists?(path).must_equal(false)
  end

  it "rejects an empty key" do
    path = tmp_file("json_file-empty-key.json")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "", "value" => "x"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("segments must not be empty")
  end

  it "replaces a null intermediate with an object when setting below it" do
    path = tmp_file("json_file-null-parent.json")
    write_json(path, "{\n  \"a\": null\n}\n")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a.b", "value" => marked("1")})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("{\n  \"a\": {\n    \"b\": 1\n  }\n}\n")
  end

  it "treats a path through null as already absent" do
    path = tmp_file("json_file-null-absent.json")
    write_json(path, "{\n  \"a\": null\n}\n")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a.b", "state" => "absent"})

    result["changed"].as_bool.must_equal(false)
    File.read(path).must_equal("{\n  \"a\": null\n}\n")
  end

  it "rejects a top-level state combined with changes" do
    path = tmp_file("json_file-state-changes.json")

    result = PluginSpecHelper.run("json_file", {
      "path"    => path,
      "state"   => "absent",
      "changes" => %([{"key":"a","value":1}]),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("mutually exclusive: state|changes")
  end

  it "rejects value_type=string on an unquoted non-string literal" do
    path = tmp_file("json_file-value-type-mismatch.json")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => marked("5"), "value_type" => "string"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("value_type: string")
  end

  it "writes a JSON null for an explicit null value" do
    path = tmp_file("json_file-null.json")
    write_json(path, "{\n  \"a\": 1\n}\n")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => Krikri::NONE_SENTINEL})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("{\n  \"a\": null\n}\n")
  end

  it "applies every entry of a changes list, including its own state" do
    path = tmp_file("json_file-changes.json")
    write_json(path, "{\n  \"keep\": true,\n  \"drop\": 1\n}\n")
    changes = %([{"key":"a.b","value":2},{"key":"drop","state":"absent"},{"key":"c","value":[1,2]}])

    result = PluginSpecHelper.run("json_file", {"path" => path, "changes" => changes})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("{\n  \"keep\": true,\n  \"a\": {\n    \"b\": 2\n  },\n  \"c\": [\n    1,\n    2\n  ]\n}\n")
  end

  it "accepts a changes list rendered through Python's repr" do
    path = tmp_file("json_file-changes-repr.json")

    result = PluginSpecHelper.run("json_file", {"path" => path, "changes" => "[{'key': 'a', 'value': 'x'}]"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("{\n  \"a\": \"x\"\n}\n")
  end

  it "reports changed in check mode without writing" do
    path = tmp_file("json_file-check.json")
    write_json(path, "{\n  \"a\": 1\n}\n")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => marked("2"), "_ansible_check_mode" => "True"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("{\n  \"a\": 1\n}\n")
  end

  it "puts the before/after content in the diff when diff mode is on" do
    path = tmp_file("json_file-diff.json")
    write_json(path, "{\n  \"a\": 1\n}\n")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => marked("2"), "_ansible_diff" => "True"})

    diff = result["diff"]
    diff["before"].as_s.must_equal("{\n  \"a\": 1\n}\n")
    diff["after"].as_s.must_equal("{\n  \"a\": 2\n}\n")
  end

  it "takes a timestamped backup when backup is requested" do
    path = tmp_file("json_file-backup.json")
    write_json(path, "{\n  \"a\": 1\n}\n")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => marked("2"), "backup" => "True"})

    backup_file = result["backup_file"].as_s
    File.exists?(backup_file).must_equal(true)
    File.read(backup_file).must_equal("{\n  \"a\": 1\n}\n")
  end

  it "applies owner/group/mode on an unchanged-content run too" do
    path = tmp_file("json_file-mode.json")
    write_json(path, "{\n  \"a\": 1\n}\n")
    File.chmod(path, 0o644)

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => marked("1"), "mode" => "0600"})

    result["changed"].as_bool.must_equal(true)
    (File.info(path).permissions.value & 0o777).must_equal(0o600)
    # The content was already what was asked for, so no key edit ran.
    result["msg"].as_s.must_equal("ok")
  end

  it "fails without rewriting a document that is not valid JSON" do
    path = tmp_file("json_file-invalid.json")
    write_json(path, "{oops")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => "b"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Unable to parse")
    File.read(path).must_equal("{oops")
  end

  it "fails when the file is missing and create is false" do
    path = tmp_file("json_file-create-false.json")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => "b", "create" => "False"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("does not exist")
    File.exists?(path).must_equal(false)
  end

  it "rejects an unknown parameter instead of ignoring it" do
    path = tmp_file("json_file-unsupported.json")

    result = PluginSpecHelper.run("json_file", {"path" => path, "key" => "a", "value" => "b", "modes" => "0644"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Unsupported parameters for (json_file) module: modes")
    File.exists?(path).must_equal(false)
  end
end

private def run_playbook(playbook : String) : {Process::Status, String}
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
  {status, captured.to_s}
end

describe "json_file module resolution" do
  it "runs a bare json_file task instead of reporting it unimplemented" do
    path = tmp_file("json_file-playbook/conf.json")
    playbook = tmp_file("json_file-playbook/site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: set a nested key
            json_file:
              path: #{path}
              key: app.port
              value: 8080
      YAML

    status, output = run_playbook(playbook)

    output.wont_include("uses unimplemented plugin: json_file")
    output.wont_include("couldn't resolve module/action")
    status.exit_code.must_equal(0)
    # A non-string YAML literal keeps its native JSON type on the wire.
    File.read(path).must_equal("{\n  \"app\": {\n    \"port\": 8080\n  }\n}\n")
  end

  it "resolves the krikri.json_file fully-qualified spelling" do
    path = tmp_file("json_file-playbook/fqcn.json")
    playbook = tmp_file("json_file-playbook/fqcn.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: set a key through the FQCN spelling
            krikri.json_file:
              path: #{path}
              key: a
              value: b
      YAML

    status, output = run_playbook(playbook)

    output.wont_include("couldn't resolve module/action")
    status.exit_code.must_equal(0)
    File.read(path).must_equal("{\n  \"a\": \"b\"\n}\n")
  end

  it "writes a templated mapping as a JSON object" do
    path = tmp_file("json_file-playbook/rendered.json")
    playbook = tmp_file("json_file-playbook/render.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          settings:
            retries: 3
            loud: false
        tasks:
          - name: write the mapping
            json_file:
              path: #{path}
              key: app
              value: "{{ settings }}"
      YAML

    status, _output = run_playbook(playbook)

    status.exit_code.must_equal(0)
    File.read(path).must_equal("{\n  \"app\": {\n    \"retries\": 3,\n    \"loud\": false\n  }\n}\n")
  end

  it "does not write in --check mode and reports the change" do
    path = tmp_file("json_file-playbook/check.json")
    File.write(path, "{\n  \"a\": 1\n}\n")
    playbook = tmp_file("json_file-playbook/check.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: change a key
            json_file:
              path: #{path}
              key: a
              value: 2
      YAML

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "--check", playbook], output: captured, error: captured)

    status.exit_code.must_equal(0)
    captured.to_s.must_include("changed=1")
    File.read(path).must_equal("{\n  \"a\": 1\n}\n")
  end
end
