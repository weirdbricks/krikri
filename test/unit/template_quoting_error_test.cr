require "../minitest_helper"
require "../../src/krikri/yaml_source_map"
require "../../src/krikri/playbook_parser"

# ansible-core 2.19 refuses at load time (rc=4, the same Origin block
# shape as every other YAML error) a file where an unquoted template
# parses as a collection used AS a mapping key - `owner: {{ x }}` is a
# flow mapping whose key is itself a flow mapping. libyaml accepts the
# file, so the position comes from YamlSourceMap's event scan, not from
# a YAML::ParseException.
describe "Krikri::YamlSourceMap collection-as-key detection (template_quoting_error_test.cr)" do
  it "records the outer flow mapping's start for an unquoted template value" do
    content = <<-YAML
      - name: t
        template:
          owner: {{ x }}
      YAML

    map = Krikri::YamlSourceMap.scan(content)
    map.collection_key_pos.must_equal({3, 12})
  end

  it "records only the first occurrence when several unquoted values exist" do
    content = <<-YAML
      - name: t
        template:
          owner: {{ x }}
          group: {{ x }}
      YAML

    map = Krikri::YamlSourceMap.scan(content)
    map.collection_key_pos.must_equal({3, 12})
  end

  it "records nothing when templates are quoted or collections are plain values" do
    quoted = Krikri::YamlSourceMap.scan(<<-YAML)
      - name: t
        template:
          owner: "{{ x }}"
      YAML
    quoted.collection_key_pos.must_be_nil

    plain_values = Krikri::YamlSourceMap.scan(<<-YAML)
      - name: t
        template:
          params:
            a: 1
      YAML
    plain_values.collection_key_pos.must_be_nil
  end
end

describe "Krikri::PlaybookParser.check_template_quoting (template_quoting_error_test.cr)" do
  it "raises the quoting YamlSyntaxError at the collection key's position" do
    content = <<-YAML
      - name: t
        template:
          owner: {{ x }}
      YAML
    path = PluginSpecHelper.tmp_path("tasks.yml")

    ex = assert_raises(Krikri::YamlSyntaxError) do
      Krikri::PlaybookParser.check_template_quoting(path, content)
    end
    ex.line.must_equal(3)
    ex.column.must_equal(12)
    ex.message.must_equal("Invalid YAML in #{File.expand_path(path)}: " \
                          "This may be an issue with missing quotes around a template block. at line 3, column 12")
  end

  it "renders Ansible's quoting refusal with the template-shaped worked example" do
    content = <<-YAML
      - name: t
        template:
          owner: {{ x }}
      YAML
    path = PluginSpecHelper.tmp_path("tasks.yml")

    ex = assert_raises(Krikri::YamlSyntaxError) do
      Krikri::PlaybookParser.check_template_quoting(path, content)
    end
    ex.render.must_equal(
      "[ERROR]: YAML parsing failed: This may be an issue with missing quotes around a template block.\n" \
      "Origin: #{File.expand_path(path)}:3:12\n" \
      "\n" \
      "1 - name: t\n" \
      "2   template:\n" \
      "3     owner: {{ x }}\n" \
      "             ^ column 12\n" \
      "\n" \
      "\n" \
      "For example:\n" \
      "\n" \
      "    raw: {{ some_var }}\n" \
      "\n" \
      "Should be:\n" \
      "\n" \
      "    raw: \"{{ some_var }}\"\n" \
      "\n"
    )
  end

  it "renders a lone colon in a multi-line scalar without the hint" do
    ex = Krikri::YamlSyntaxError.new("pb.yml", "- name: x\n\n- name: Create\n    name: y\n",
      YAML::ParseException.new("mapping values are not allowed in this context", 4, 9, nil))
    ex.render.must_equal(
      "[ERROR]: YAML parsing failed: Mapping values are not allowed in this context.\n" \
      "Origin: #{File.expand_path("pb.yml")}:4:9\n" \
      "\n" \
      "2\n" \
      "3 - name: Create\n" \
      "4     name: y\n" \
      "          ^ column 9\n" \
      "\n"
    )
  end

  it "renders libyaml's missing-colon error with the colon message and worked example" do
    ex = Krikri::YamlSyntaxError.new("pb.yml", "- name: \"1.1.5 Ensure noexec\n  block\n    template:\n",
      YAML::ParseException.new("could not find expected ':' at line 3, column 13, while scanning a simple key at line 2, column 3", 3, 13, nil))
    ex.render.must_equal(
      "[ERROR]: YAML parsing failed: Colons in unquoted values must be followed by a non-space character.\n" \
      "Origin: #{File.expand_path("pb.yml")}:3:13\n" \
      "\n" \
      "1 - name: \"1.1.5 Ensure noexec\n" \
      "2   block\n" \
      "3     template:\n" \
      "              ^ column 13\n" \
      "\n" \
      "\n" \
      "For example:\n" \
      "\n" \
      "    raw: echo 'name: ansible'\n" \
      "\n" \
      "Should be:\n" \
      "\n" \
      "    raw: \"echo 'name: ansible'\"\n" \
      "\n"
    )
  end

  it "applies the colon heuristic to a block-collection error on a mis-indented key line" do
    # rothgar.tomcat_and_java's tasks/main.yml:10 (issue #816): the task's
    # key lands at column 1 (its single-quoted wget value spans the
    # following lines), so libyaml reports its block-collection error at
    # 3:1 - nowhere near the `Cookie: ` colon ansible-core's error layer
    # finds on that line and reports instead, with the Origin and caret
    # re-pointed at the colon itself.
    content = "# Full URLs can be found here https://ivan-site.com/2012/05/download-oracle-java-jre-jdk-using-a-script/\n" \
              "- name: Download Java {{ java_version }}\n" \
              "shell: 'wget -q --no-cookies --no-check-certificate --header \"Cookie: oraclelicense=accept-securebackup-cookie\"\n" \
              "    \"http://download.oracle.com/otn-pub/java/jdk/\"\n" \
              "    -O /tmp/java.tgz'\n" \
              "  register: jdk_downloaded\n"
    ex = Krikri::YamlSyntaxError.new("pb.yml", content,
      YAML::ParseException.new("did not find expected '-' indicator at line 3, column 1, while parsing a block collection at line 2, column 1", 3, 1, nil))
    ex.render.must_equal(
      "[ERROR]: YAML parsing failed: Colons in unquoted values must be followed by a non-space character.\n" \
      "Origin: #{File.expand_path("pb.yml")}:3:69\n" \
      "\n" \
      "1 # Full URLs can be found here https://ivan-site.com/2012/05/download-oracle-java-jre-jdk-using-a-script/\n" \
      "2 - name: Download Java {{ java_version }}\n" \
      "3 shell: 'wget -q --no-cookies --no-check-certificate --header \"Cookie: oraclelicense=accept-securebackup-cookie\"\n" \
      "#{" " * 70}^ column 69\n" \
      "\n" \
      "\n" \
      "For example:\n" \
      "\n" \
      "    raw: echo 'name: ansible'\n" \
      "\n" \
      "Should be:\n" \
      "\n" \
      "    raw: \"echo 'name: ansible'\"\n" \
      "\n"
    )
  end

  it "keeps the colon error's worked example byte-identical" do
    ex = Krikri::YamlSyntaxError.new("pb.yml", "this: is: bad: [\n",
      YAML::ParseException.new("mapping values are not allowed in this context", 1, 9, nil))
    ex.render.must_equal(
      "[ERROR]: YAML parsing failed: Colons in unquoted values must be followed by a non-space character.\n" \
      "Origin: #{File.expand_path("pb.yml")}:1:9\n" \
      "\n" \
      "1 this: is: bad: [\n" \
      "          ^ column 9\n" \
      "\n" \
      "\n" \
      "For example:\n" \
      "\n" \
      "    raw: echo 'name: ansible'\n" \
      "\n" \
      "Should be:\n" \
      "\n" \
      "    raw: \"echo 'name: ansible'\"\n" \
      "\n"
    )
  end
end
