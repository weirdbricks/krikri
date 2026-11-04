require "../minitest_helper"

# A container-valued task param whose failing entry raises with a
# template ORIGIN - an attribute miss, "Syntax error in template: ...",
# "Error rendering template: ..." - splits its finalization chain into a
# fourth stanza exactly like the plain-undefined shape does (issue #803,
# live-captured against ansible-core 2.19.11). Stanza 3 shortens to
# "Error while resolving value for 'K'." with the container's own Origin
# (a block's FIRST entry line for block style, the flow value's first
# character for flow style), and stanza 4 carries the full inner message
# with the failing VALUE token's Origin - which the message text alone
# cannot always name, so the substitutor records the failing span and
# this is matched against the source entry that authored it.
#
# A lookup/filter-plugin RUNTIME failure does NOT split in real Ansible
# (it is not a template-origin error), and these tests pin that too so
# the new span plumbing never widens into it.
private CONTAINER_NOND_UNDEFINED_PROJECT_ROOT = File.expand_path("../..", __DIR__)
private CONTAINER_NOND_UNDEFINED_BINARY       = File.join(CONTAINER_NOND_UNDEFINED_PROJECT_ROOT, "bin", "krikri-playbook")
private CONTAINER_NOND_UNDEFINED_INVENTORY    = File.join(CONTAINER_NOND_UNDEFINED_PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def container_nond_undefined_run(playbook : String) : {String, Int32}
  output = IO::Memory.new
  status = Process.run(CONTAINER_NOND_UNDEFINED_BINARY, ["-i", CONTAINER_NOND_UNDEFINED_INVENTORY, playbook], output: output, error: output)
  {output.to_s, status.exit_code}
end

# The exact Origin block ansible prints (numbers right-aligned to the
# widest shown line, caret = prefix width + column - 1).
private def container_nond_undefined_origin(path : String, line : Int32, column : Int32, entries : Array({Int32, String})) : String
  width = entries.max_of { |entry| entry[0].to_s.size } || 1
  context = entries.map { |entry| "#{entry[0].to_s.rjust(width)} #{entry[1]}" }.join("\n")
  "Origin: #{path}:#{line}:#{column}\n\n#{context}\n#{" " * (width + column)}^ column #{column}\n"
end

private def container_nond_undefined_stanzas(path : String, key : String,
                                             third : {Int32, Int32, Array({Int32, String})},
                                             fourth_msg : String,
                                             fourth : {Int32, Int32, Array({Int32, String})}) : String
  "Error while resolving value for '#{key}'.\n" +
    container_nond_undefined_origin(path, third[0], third[1], third[2]) +
    "\n<<< caused by >>>\n\n" +
    fourth_msg + "\n" +
    container_nond_undefined_origin(path, fourth[0], fourth[1], fourth[2]) + "\n"
end

private def container_nond_undefined_playbook(name : String, body : String) : String
  playbook = File.tempname(name, ".yml")
  File.write(playbook, body)
  playbook
end

describe "task-arg finalization error block (non-undefined container failures)" do
  it "splits a single-entry block mapping on an attribute miss (issue #803)" do
    playbook = container_nond_undefined_playbook("container-attr", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: block mapping param
            set_fact:
              m:
                k: "{{ groups[(master_group | default('solr-master'))]|first }}"
      YAML
    text, status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "m",
      {8, 11, [{6, "      set_fact:"}, {7, "        m:"}, {8, "          k: \"{{ groups[(master_group | default('solr-master'))]|first }}\""}]},
      "object of type 'dict' has no attribute 'solr-master'",
      {8, 14, [{6, "      set_fact:"}, {7, "        m:"}, {8, "          k: \"{{ groups[(master_group | default('solr-master'))]|first }}\""}]}
    )
    text.must_include(expected)
    status.must_equal(2)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "points stanza 4 at the FAILING entry when the mapping has several" do
    playbook = container_nond_undefined_playbook("container-attr-multi", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: block mapping param
            set_fact:
              m:
                a: "literal"
                b: "{{ groups[(master_group | default('solr-master'))]|first }}"
      YAML
    text, _status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "m",
      {8, 11, [{6, "      set_fact:"}, {7, "        m:"}, {8, "          a: \"literal\""}]},
      "object of type 'dict' has no attribute 'solr-master'",
      {9, 14, [{7, "        m:"}, {8, "          a: \"literal\""}, {9, "          b: \"{{ groups[(master_group | default('solr-master'))]|first }}\""}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "locates the failing scalar item of a block list after the dash" do
    playbook = container_nond_undefined_playbook("container-attr-list", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: block list param
            set_fact:
              m:
                - "literal"
                - "{{ groups[(master_group | default('solr-master'))]|first }}"
      YAML
    text, _status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "m",
      {8, 11, [{6, "      set_fact:"}, {7, "        m:"}, {8, "          - \"literal\""}]},
      "object of type 'dict' has no attribute 'solr-master'",
      {9, 13, [{7, "        m:"}, {8, "          - \"literal\""}, {9, "          - \"{{ groups[(master_group | default('solr-master'))]|first }}\""}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "finds a leaf nested under a mapping key" do
    playbook = container_nond_undefined_playbook("container-attr-nested", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: nested mapping
            set_fact:
              m:
                outer:
                  inner: "{{ groups[(master_group | default('solr-master'))]|first }}"
      YAML
    text, _status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "m",
      {8, 11, [{6, "      set_fact:"}, {7, "        m:"}, {8, "          outer:"}]},
      "object of type 'dict' has no attribute 'solr-master'",
      {9, 20, [{7, "        m:"}, {8, "          outer:"}, {9, "            inner: \"{{ groups[(master_group | default('solr-master'))]|first }}\""}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "finds a leaf nested under a list item's own mapping" do
    playbook = container_nond_undefined_playbook("container-attr-list-map", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: list of dicts
            set_fact:
              l:
                - name: first
                  val: "{{ groups[(master_group | default('solr-master'))]|first }}"
                - name: second
                  val: ok
      YAML
    text, _status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "l",
      {8, 11, [{6, "      set_fact:"}, {7, "        l:"}, {8, "          - name: first"}]},
      "object of type 'dict' has no attribute 'solr-master'",
      {9, 18, [{7, "        l:"}, {8, "          - name: first"}, {9, "            val: \"{{ groups[(master_group | default('solr-master'))]|first }}\""}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "uses the item's own key colon for a dash-style mapping item" do
    playbook = container_nond_undefined_playbook("container-attr-dash-map", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: dict item dash
            set_fact:
              k:
                - a: 1
                - b: "{{ groups[(master_group | default('solr-master'))]|first }}"
      YAML
    text, _status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "k",
      {8, 11, [{6, "      set_fact:"}, {7, "        k:"}, {8, "          - a: 1"}]},
      "object of type 'dict' has no attribute 'solr-master'",
      {9, 16, [{7, "        k:"}, {8, "          - a: 1"}, {9, "          - b: \"{{ groups[(master_group | default('solr-master'))]|first }}\""}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "splits an undefined name consumed by a block tag under a block mapping" do
    playbook = container_nond_undefined_playbook("container-block-tag", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: block tag missing
            set_fact:
              m:
                a: "literal"
                b: "{% if zz_missing %}x{% else %}y{% endif %}"
      YAML
    text, _status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "m",
      {8, 11, [{6, "      set_fact:"}, {7, "        m:"}, {8, "          a: \"literal\""}]},
      "'zz_missing' is undefined",
      {9, 14, [{7, "        m:"}, {8, "          a: \"literal\""}, {9, "          b: \"{% if zz_missing %}x{% else %}y{% endif %}\""}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "splits an attribute miss consumed by a block tag via the message's named member" do
    playbook = container_nond_undefined_playbook("container-block-tag-attr", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        vars:
          deps: {}
        tasks:
          - name: block tag attribute
            set_fact:
              m:
                a: "literal"
                b: "{% if deps.missing %}x{% else %}y{% endif %}"
      YAML
    text, _status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "m",
      {10, 11, [{8, "      set_fact:"}, {9, "        m:"}, {10, "          a: \"literal\""}]},
      "object of type 'dict' has no attribute 'missing'",
      {11, 14, [{9, "        m:"}, {10, "          a: \"literal\""}, {11, "          b: \"{% if deps.missing %}x{% else %}y{% endif %}\""}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "splits on an unknown filter name (syntax error with a template origin)" do
    playbook = container_nond_undefined_playbook("container-unknown-filter", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: filter failure
            set_fact:
              a:
                x: "literal"
                y: "{{ ['a'] | random(seed='x') | notafilter }}"
      YAML
    text, _status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "a",
      {8, 11, [{6, "      set_fact:"}, {7, "        a:"}, {8, "          x: \"literal\""}]},
      "Syntax error in template: No filter named 'notafilter'.",
      {9, 14, [{7, "        a:"}, {8, "          x: \"literal\""}, {9, "          y: \"{{ ['a'] | random(seed='x') | notafilter }}\""}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "splits on an unknown test name" do
    playbook = container_nond_undefined_playbook("container-unknown-test", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: unknown test
            set_fact:
              m:
                a: "literal"
                b: "{{ 1 is nosuchtest }}"
      YAML
    text, _status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "m",
      {8, 11, [{6, "      set_fact:"}, {7, "        m:"}, {8, "          a: \"literal\""}]},
      "Syntax error in template: No test named 'nosuchtest'.",
      {9, 14, [{7, "        m:"}, {8, "          a: \"literal\""}, {9, "          b: \"{{ 1 is nosuchtest }}\""}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "splits on an operand TypeError, keeping ansible's Error rendering template text" do
    playbook = container_nond_undefined_playbook("container-operand", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: operand type
            set_fact:
              m:
                a: "literal"
                b: "{{ 'x' + 1 }}"
      YAML
    text, _status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "m",
      {8, 11, [{6, "      set_fact:"}, {7, "        m:"}, {8, "          a: \"literal\""}]},
      "Error rendering template: can only concatenate str (not \"int\") to str",
      {9, 14, [{7, "        m:"}, {8, "          a: \"literal\""}, {9, "          b: \"{{ 'x' + 1 }}\""}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "splits a single-line flow mapping at the failing element's token" do
    playbook = container_nond_undefined_playbook("container-flow-map", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: flow mapping attribute
            set_fact:
              m: {"a": "literal", "b": "{{ groups[(master_group | default('solr-master'))]|first }}"}
      YAML
    text, _status = container_nond_undefined_run(playbook)
    line7 = "        m: {\"a\": \"literal\", \"b\": \"{{ groups[(master_group | default('solr-master'))]|first }}\"}"
    expected = container_nond_undefined_stanzas(
      playbook, "m",
      {7, 12, [{5, "    - name: flow mapping attribute"}, {6, "      set_fact:"}, {7, line7}]},
      "object of type 'dict' has no attribute 'solr-master'",
      {7, 34, [{5, "    - name: flow mapping attribute"}, {6, "      set_fact:"}, {7, line7}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "splits a single-line flow list at the failing item's token" do
    playbook = container_nond_undefined_playbook("container-flow-list", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: flow list undefined
            set_fact:
              l: ["a", "{{ flow_missing }}"]
      YAML
    text, _status = container_nond_undefined_run(playbook)
    line7 = "        l: [\"a\", \"{{ flow_missing }}\"]"
    expected = container_nond_undefined_stanzas(
      playbook, "l",
      {7, 12, [{5, "    - name: flow list undefined"}, {6, "      set_fact:"}, {7, line7}]},
      "'flow_missing' is undefined",
      {7, 18, [{5, "    - name: flow list undefined"}, {6, "      set_fact:"}, {7, line7}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "splits a multi-line flow mapping at the failing element's token" do
    playbook = container_nond_undefined_playbook("container-flow-multiline", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: multiline flow mapping
            set_fact:
              m: {
                "a": "literal",
                "b": "{{ groups[(master_group | default('solr-master'))]|first }}"
              }
      YAML
    text, _status = container_nond_undefined_run(playbook)
    expected = container_nond_undefined_stanzas(
      playbook, "m",
      {7, 12, [{5, "    - name: multiline flow mapping"}, {6, "      set_fact:"}, {7, "        m: {"}]},
      "object of type 'dict' has no attribute 'solr-master'",
      {9, 16, [{7, "        m: {"}, {8, "          \"a\": \"literal\","}, {9, "          \"b\": \"{{ groups[(master_group | default('solr-master'))]|first }}\""}]}
    )
    text.must_include(expected)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "keeps the three-stanza block for a lookup-plugin runtime failure" do
    playbook = container_nond_undefined_playbook("container-lookup", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: unknown lookup in mapping
            set_fact:
              m:
                a: "literal"
                b: "{{ lookup('nosuchlookup', 'x') }}"
      YAML
    text, _status = container_nond_undefined_run(playbook)
    # The full message stays in stanza 3, whose Origin is the block's
    # first entry - no fourth "caused by" link (live-captured 2.19.11).
    text.must_include("Error while resolving value for 'm': The lookup plugin 'nosuchlookup' was not found.\nOrigin: #{playbook}:8:11\n")
    text.wont_include("<<< caused by >>>\n\nThe lookup plugin 'nosuchlookup'")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "keeps the three-stanza block for a flow-style scalar (non-container) param" do
    playbook = container_nond_undefined_playbook("container-scalar", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: operand type scalar
            ansible.builtin.debug:
              msg: "{{ 'x' + 1 }}"
      YAML
    text, _status = container_nond_undefined_run(playbook)
    text.must_include("Error while resolving value for 'msg': Error rendering template: can only concatenate str (not \"int\") to str\n")
    text.wont_include("<<< caused by >>>\n\nError rendering template: can only concatenate str")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
