require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/tag_filter"
require "../../src/krikri/task_lister"

# Regression tests for the CLI-mode output-parity work: a task's effective
# tags are the union of its own tags, every enclosing block's tags AND the
# PLAY's tags - real ansible-playbook lists and selects on that union
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
