require "../minitest_helper"
require "file_utils"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/role_loader"

# Issue #815 (lullis.certbot_nginx, round 298963492): a task whose `vars:`
# is a YAML SEQUENCE of single-key mappings - the shape real roles keep
# shipping - was silently dropped by krikri's `as_h?` read, so the play ran
# to completion (rc=2 on a downstream module failure, 24 output blocks)
# where ansible-core refuses the WHOLE playbook at load time:
#   [ERROR]: Vars in a Task must be specified as a dictionary.
#   Origin: <file>:<line>:<col of the vars VALUE's first char>
# rc=4, zero play output. The class name in the message is the loading
# object's own (Task/Handler/Block/Play/RoleInclude/TaskInclude/
# HandlerTaskInclude/IncludeRole/PlaybookInclude - live-verified vs
# 2.19.11), and the Origin points at the `vars:` VALUE (the first `-` of a
# sequence), not at the `vars:` key. An explicit null `vars:` stays legal.
describe "non-mapping task vars refusal (issue 815)" do
  it "refuses a task vars: sequence with Ansible's message" do
    content = "---\n- name: p\n  hosts: all\n  tasks:\n    - name: bad task\n      ansible.builtin.debug:\n        msg: hi\n      vars:\n        - public_domain: x\n"
    ex = assert_raises(Krikri::PlaybookParser::NonDictVarsError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.to_s.must_equal("Vars in a Task must be specified as a dictionary.")
    ex.render.lines.first.must_equal("[ERROR]: Vars in a Task must be specified as a dictionary.")
  end

  it "refuses a handler vars: sequence with the Handler class name" do
    content = "---\n- name: p\n  hosts: all\n  handlers:\n    - name: h\n      ansible.builtin.debug:\n        msg: hi\n      vars:\n        - foo: bar\n  tasks:\n    - name: t\n      ansible.builtin.debug:\n        msg: hi\n"
    ex = assert_raises(Krikri::PlaybookParser::NonDictVarsError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.to_s.must_equal("Vars in a Handler must be specified as a dictionary.")
  end

  it "refuses a handler block child vars: sequence as a Handler too" do
    # A block nested inside handlers/main.yml holds Handler children
    # (ansible loads handler lists through the Handler class at every
    # level), so the message names Handler - live-verified vs 2.19.11.
    content = "---\n- name: p\n  hosts: all\n  handlers:\n    - name: h\n      block:\n        - name: inner\n          ansible.builtin.debug:\n            msg: hi\n          vars:\n            - foo: bar\n  tasks:\n    - name: t\n      ansible.builtin.debug:\n        msg: hi\n"
    ex = assert_raises(Krikri::PlaybookParser::NonDictVarsError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.to_s.must_equal("Vars in a Handler must be specified as a dictionary.")
  end

  it "refuses a block vars: sequence with the Block class name" do
    content = "---\n- name: p\n  hosts: all\n  tasks:\n    - name: b\n      block:\n        - name: inner\n          ansible.builtin.debug:\n            msg: hi\n      vars:\n        - foo: bar\n"
    ex = assert_raises(Krikri::PlaybookParser::NonDictVarsError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.to_s.must_equal("Vars in a Block must be specified as a dictionary.")
  end

  it "refuses a play vars: sequence with the Play class name" do
    content = "---\n- name: p\n  hosts: all\n  vars:\n    - foo: bar\n  tasks:\n    - name: t\n      ansible.builtin.debug:\n        msg: hi\n"
    ex = assert_raises(Krikri::PlaybookParser::NonDictVarsError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.to_s.must_equal("Vars in a Play must be specified as a dictionary.")
  end

  it "refuses an include_tasks line vars: sequence as a TaskInclude" do
    content = "---\n- name: p\n  hosts: all\n  tasks:\n    - name: inc\n      ansible.builtin.include_tasks: other.yml\n      vars:\n        - foo: bar\n"
    ex = assert_raises(Krikri::PlaybookParser::NonDictVarsError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.to_s.must_equal("Vars in a TaskInclude must be specified as a dictionary.")
  end

  it "refuses an include_role line vars: sequence as an IncludeRole" do
    content = "---\n- name: p\n  hosts: all\n  tasks:\n    - name: irl\n      ansible.builtin.include_role:\n        name: somerole\n      vars:\n        - foo: bar\n"
    ex = assert_raises(Krikri::PlaybookParser::NonDictVarsError) do
      Krikri::PlaybookParser.parse_string(content)
    end
    ex.message.to_s.must_equal("Vars in a IncludeRole must be specified as a dictionary.")
  end

  it "accepts an explicit null vars: (Ansible runs the task)" do
    content = "---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      ansible.builtin.debug:\n        msg: hi\n      vars:\n"
    playbook = Krikri::PlaybookParser.parse_string(content)
    playbook.plays.size.must_equal(1)
    playbook.plays[0].tasks.size.must_equal(1)
  end

  it "renders the Origin at the vars VALUE's first char for a file-backed playbook" do
    # parse_string's fake path is not a file, so the Origin block only
    # renders when the playbook is parsed from disk - the layout real
    # prints is the [ERROR] line, Origin at the sequence's first `-`
    # (12:9 for this shape, live-verified vs 2.19.11) and the excerpt.
    dir = PluginSpecHelper.tmp_path("non_dict_vars_spec")
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
    Dir.mkdir_p(dir)
    path = File.join(dir, "play.yml")
    File.write(path, "---\n- name: p\n  hosts: all\n  gather_facts: false\n  tasks:\n    - name: first task runs fine\n      ansible.builtin.debug:\n        msg: before\n    - name: bad task\n      ansible.builtin.debug:\n        msg: after\n      vars:\n        - foo: bar\n")
    begin
      ex = assert_raises(Krikri::PlaybookParser::NonDictVarsError) do
        Krikri::PlaybookParser.parse(path)
      end
      ex.render.must_include("Origin: #{File.expand_path(path)}:13:9")
      ex.render.must_include("^ column 9")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "refuses a roles: entry vars: sequence as a RoleInclude" do
    dir = PluginSpecHelper.tmp_path("non_dict_vars_role_spec")
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
    role_dir = File.join(dir, "roles", "badvars")
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "tasks", "main.yml"),
      "- name: hello\n  ansible.builtin.debug:\n    msg: hi\n")
    begin
      ex = assert_raises(Krikri::PlaybookParser::NonDictVarsError) do
        Krikri::RoleLoader.load_roles(
          YAML.parse("- role: badvars\n  vars:\n    - foo: bar\n").as_a,
          Krikri::Play.new("test play", "all"), dir)
      end
      ex.message.to_s.must_equal("Vars in a RoleInclude must be specified as a dictionary.")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
