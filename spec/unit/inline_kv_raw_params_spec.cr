require "../spec_helper"
require "../../src/krikri/playbook_parser"

# Old-style inline `key=value key2=value2` module-argument shorthand
# (`apt: pkg=unzip={{ v }} state=present`, azavea.unzip's own "Install
# unzip" task, found by a real-host benchmark round): real Ansible's
# parse_kv puts "_raw_params" in the result ONLY when the string
# contains tokens with no "=" (leftover free-form text); a fully
# key=value string produces no "_raw_params" at all. krikri used to set
# it unconditionally, so every strictly-validating module (apt first
# among them) rejected the task with "Unsupported parameters ...
# _raw_params" even though both real params had been parsed fine.
describe Krikri::PlaybookParser do
  describe "old-style k=v inline task args (_raw_params suppression)" do
    it "splits a fully key=value string into separate params, with no _raw_params (apt)" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: old-style apt
          hosts: all
          gather_facts: false
          tasks:
            - name: Install unzip
              apt: pkg=unzip={{ unzip_version }} state=present
        YAML
      task = pb.plays[0].tasks[0]
      task.params["pkg"].should eq "unzip={{ unzip_version }}"
      task.params["state"].should eq "present"
      task.params.has_key?("_raw_params").should be_false
    end

    it "keeps a quoted multi-word value whole (debug)" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: old-style debug
          hosts: all
          gather_facts: false
          tasks:
            - name: say hi
              debug: msg="hello world again"
        YAML
      task = pb.plays[0].tasks[0]
      task.params["msg"].should eq "hello world again"
      task.params.has_key?("_raw_params").should be_false
    end

    it "still emits _raw_params for leftover non-kv tokens, alongside the parsed k=v params" do
      # Same split real Ansible makes (parse_kv, check_raw=false): the kv
      # token becomes a param AND the bare token becomes _raw_params.
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: mixed string
          hosts: all
          gather_facts: false
          tasks:
            - name: mixed
              apt: pkg=unzip badtoken
        YAML
      task = pb.plays[0].tasks[0]
      task.params["pkg"].should eq "unzip"
      task.params["_raw_params"].should eq "badtoken"
    end

    it "still emits _raw_params when the whole string is a bare value (dnf free-form-name fallback)" do
      pb = Krikri::PlaybookParser.parse_string(<<-YAML)
        - name: bare name
          hosts: all
          gather_facts: false
          tasks:
            - name: install
              dnf: somepackage
        YAML
      task = pb.plays[0].tasks[0]
      task.params["_raw_params"].should eq "somepackage"
    end

    it "applies the same rule on the ad-hoc -a path" do
      full_kv = Krikri::PlaybookParser.parse_adhoc_params("apt", "pkg=unzip state=present")
      full_kv["pkg"].should eq "unzip"
      full_kv["state"].should eq "present"
      full_kv.has_key?("_raw_params").should be_false

      mixed = Krikri::PlaybookParser.parse_adhoc_params("apt", "pkg=unzip badtoken")
      mixed["pkg"].should eq "unzip"
      mixed["_raw_params"].should eq "badtoken"
    end

    it "leaves command/shell raw handling untouched" do
      cmd = Krikri::PlaybookParser.parse_adhoc_params("ansible.builtin.command", "echo hello")
      cmd["cmd"].should eq "echo hello"
      cmd.has_key?("_raw_params").should be_false
    end
  end
end
