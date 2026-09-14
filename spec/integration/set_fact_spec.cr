require "../spec_helper"

describe "set_fact plugin" do
  it "returns given params as ansible_facts, unchanged" do
    result = PluginSpecHelper.run("set_fact", {"greeting" => "hi"})

    result["changed"].as_bool.should be_false
    result["failed"]?.try(&.as_bool).should be_falsey
    result["ansible_facts"]["greeting"].as_s.should eq("hi")
  end

  it "coerces bool-looking and int-looking values, and leaves other strings alone" do
    result = PluginSpecHelper.run("set_fact", {
      "is_ready" => "true", "is_done" => "false", "count" => "3", "ratio" => "1.5", "name" => "web01",
    })

    facts = result["ansible_facts"]
    facts["is_ready"].as_bool.should be_true
    facts["is_done"].as_bool.should be_false
    facts["count"].as_i64.should eq(3)
    facts["ratio"].as_f.should eq(1.5)
    facts["name"].as_s.should eq("web01")
  end

  it "parses valid-JSON container text back into a real list/dict" do
    # A native container set_fact (`my_list: "{{ some_list }}"`) arrives
    # here as the double-quoted JSON text the evaluator serialized it to.
    facts = PluginSpecHelper.run("set_fact", {
      "my_list" => "[\"a\", \"b\", \"c\"]",
      "my_dict" => "{\"x\": \"y\"}",
    })["ansible_facts"]
    facts["my_list"].as_a.map(&.as_s).should eq(["a", "b", "c"])
    facts["my_dict"]["x"].as_s.should eq("y")
  end

  it "keeps a Python-repr-looking (single-quoted) string a plain string" do
    # Real ansible-core's native typing requires the template's whole
    # parsed AST to be exactly one output node wrapping one expression,
    # so block-tag output (or a plain quoted literal) that merely LOOKS
    # like a container is stored as a string, never re-parsed. Verified
    # live against real ansible-playbook 2.19.11 (both shapes):
    # `set_fact: repr_list: "['a', 'b']"` and a
    # `{% if false %}{{ x }}{% else %}['dummy']{% endif %}` block both
    # give `is string` -> True, and a later
    # `loop: "{{ repr_list }}"` hard-fails with "The `loop` value must
    # resolve to a 'list', not 'str'." The old single-quote repair pass
    # here turned both into real containers (found live via
    # HanXHX.debian_bootstrap's `dbs_repo_old` default, whose loop then
    # silently iterated where real Ansible fails the task).
    result = PluginSpecHelper.run("set_fact", {
      "my_list" => "['a', 'b', 'c']",
      "my_dict" => "{'x': 'y'}",
    })

    facts = result["ansible_facts"]
    facts["my_list"].as_s.should eq("['a', 'b', 'c']")
    facts["my_dict"].as_s.should eq("{'x': 'y'}")
  end

  it "does not coerce a leading-zero numeric-looking string (octal-style file mode) to an int" do
    # Real bug found live-verifying the Crinja convergence work against
    # dev-sec os_hardening: "0755".to_i64? happily parses as decimal 755,
    # silently dropping the leading zero - os_hardening's own dynamic
    # `set_fact: "{{ item.key }}": "{{ item.value }}"` round-trips every
    # os_mnt_*_dir_mode value through this coercion, and a downstream
    # `file: mode: "{{ ... }}"` fed the resulting int straight to a
    # chmod syscall applied it as octal 1363 instead of 0755 - corrupted
    # real directory permissions (/dev, /run, /var, /home, /tmp,
    # /dev/shm, /var/tmp) on a live host. "0" itself and a genuine float
    # like "0.5" must still coerce normally.
    result = PluginSpecHelper.run("set_fact", {
      "mode1" => "0755", "mode2" => "1777", "mode3" => "0700",
      "zero" => "0", "small_float" => "0.5",
    })

    facts = result["ansible_facts"]
    facts["mode1"].as_s.should eq("0755")
    facts["mode2"].as_i64.should eq(1777)
    facts["mode3"].as_s.should eq("0700")
    facts["zero"].as_i64.should eq(0)
    facts["small_float"].as_f.should eq(0.5)
  end

  it "does not turn cacheable: into a literal fact" do
    result = PluginSpecHelper.run("set_fact", {"greeting" => "hi", "cacheable" => "yes"})

    result["ansible_facts"].as_h.has_key?("cacheable").should be_false
  end
end
