require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/tag_filter"
require "../../src/krikri/task_lister"

# Regression tests for the CLI-mode output-parity work: a task's effective
# tags are the union of its own tags, every enclosing block's tags AND the
# PLAY's tags - ansible-playbook lists and selects on that union
# (verified against 2.19.11: `--list-tasks` shows the play's tags on every
# task, `-t <play-tag>` runs the play's tasks, `--skip-tags <play-tag>`
# skips them and skips the play's fact gathering entirely).
describe "tag filter play-tag inheritance" do
  def play_with_tasks(tasks_yaml : String, play_tags : String = "deploy")
    content = "---\n- name: p\n  hosts: web1\n  tags: [#{play_tags}]\n  tasks:\n#{tasks_yaml}"
    Krikri::PlaybookParser.parse_string(content).plays[0]
  end

  it "selects a play-tagged task under -t with the play's tag" do
    play = play_with_tasks("    - name: t1\n      ansible.builtin.debug:\n        msg: x\n")
    kept = Krikri::TagFilter.apply(play.tasks, ["deploy"], [] of String, play.tags)
    kept.map(&.name).must_equal(["t1"])
  end

  it "skips a play-tagged task under --skip-tags with the play's tag" do
    play = play_with_tasks("    - name: t1\n      ansible.builtin.debug:\n        msg: x\n")
    kept = Krikri::TagFilter.apply(play.tasks, [] of String, ["deploy"], play.tags)
    kept.must_be_empty
  end

  it "inherits the play tag into a block's children for selection" do
    play = play_with_tasks("    - name: blk\n      block:\n        - name: inner\n          ansible.builtin.debug:\n            msg: x\n")
    kept = Krikri::TagFilter.apply(play.tasks, ["deploy"], [] of String, play.tags)
    kept.size.must_equal(1)
    kept[0].block_tasks.as(Array(Krikri::Task)).map(&.name).must_equal(["inner"])
  end

  # Verified live against 2.19.11: with the PLAY tagged deploy, a
  # `tags: [never]` task RUNS under `-t deploy` (the play tag joins the
  # task's effective tags, so `never` is satisfied by the explicit
  # selection) - while an untagged CLI invocation still skips it.
  it "lets the play's tag satisfy a tags: never task under -t" do
    play = play_with_tasks("    - name: guarded\n      ansible.builtin.debug:\n        msg: x\n      tags: [never]\n")
    kept = Krikri::TagFilter.apply(play.tasks, ["deploy"], [] of String, play.tags)
    kept.map(&.name).must_equal(["guarded"])
    Krikri::TagFilter.apply(play.tasks, [] of String, [] of String, play.tags).must_be_empty
  end
end

# What TagFilter hands to the RUN-time include paths (#filter_runtime_loaded
# in the executor): the statement's inherited context (everything outside
# the statement, never its own tags), plus the two selection quirks a
# dynamic vs static include needs. Expected behavior verified against
# ansible-core 2.19.11.
describe "tag filter runtime-include context" do
  it "stamps play tags as an include statement's inherited context, without its own tags" do
    content = <<-YAML
      ---
      - name: p
        hosts: web1
        tags: [deploy]
        tasks:
          - name: inc
            ansible.builtin.include_tasks: x.yml
            tags: [own]
      YAML
    play = Krikri::PlaybookParser.parse_string(content).plays[0]
    kept = Krikri::TagFilter.apply(play.tasks, ["deploy"], [] of String, play.tags)
    kept.map(&.name).must_equal(["inc"])
    kept[0].tags.must_equal(["own"])
    kept[0].inherited_tags.must_equal(["deploy"])
  end

  # The executor filters a runtime-loaded list once per load; the stamp is
  # a union, so a second pass over the same statement must not change it.
  it "keeps an already-stamped inherited context stable across a second pass" do
    content = <<-YAML
      ---
      - name: p
        hosts: web1
        tags: [deploy]
        tasks:
          - name: inc
            ansible.builtin.include_tasks: x.yml
      YAML
    play = Krikri::PlaybookParser.parse_string(content).plays[0]
    Krikri::TagFilter.apply(play.tasks, ["deploy"], [] of String, play.tags)
    Krikri::TagFilter.apply(play.tasks, ["deploy"], [] of String, play.tags)
    play.tasks[0].inherited_tags.must_equal(["deploy"])
  end

  # A static import_role: has no statement of its own in real Ansible -
  # its tags are pushed onto each role task instead - so the statement
  # must survive ANY selection or the whole role would vanish under a
  # --tags it doesn't carry.
  it "keeps a static import_role statement under an unrelated --tags" do
    task = Krikri::Task.new("import_role : r", "_include_role")
    task.is_static_import = true
    kept = Krikri::TagFilter.apply([task], ["nomatch"], [] of String, keep_static_imports: true)
    kept.size.must_equal(1)
  end

  # ...and without the execution-path flag (--list-tasks) the statement is
  # still selected like an ordinary task, as it always was.
  it "drops a static import_role statement from a listing under an unrelated --tags" do
    task = Krikri::Task.new("import_role : r", "_include_role")
    task.is_static_import = true
    Krikri::TagFilter.apply([task], ["nomatch"], [] of String).must_be_empty
  end

  # Control for the rule above: a DYNAMIC include_role statement is an
  # ordinary task and is selected by its own tags like anything else.
  it "drops a dynamic include_role statement that misses --tags" do
    task = Krikri::Task.new("include_role : r", "_include_role")
    task.tags = ["own"]
    Krikri::TagFilter.apply([task], ["nomatch"], [] of String).must_be_empty
  end

  # apply: {tags: [...]} on an include directive reaches the executor's
  # runtime filter through this field (parser side of the same feature).
  it "parses apply: tags on an include_tasks statement" do
    content = <<-YAML
      ---
      - name: p
        hosts: web1
        tasks:
          - name: inc
            ansible.builtin.include_tasks:
              file: x.yml
              apply:
                tags: [applied]
      YAML
    play = Krikri::PlaybookParser.parse_string(content).plays[0]
    play.tasks[0].include_apply_tags.must_equal(["applied"])
  end
end
