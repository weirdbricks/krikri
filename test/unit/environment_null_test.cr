require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# A bare `environment:` key with no value (lifeofguenter.nginx round
# 5250092's "Configure" task): ansible-playbook 2.19.11 treats a null
# environment as "no environment" and runs the task normally. krikri
# used to stringify the null into an empty environment_raw, which the
# executor's env finalization then JSON.parsed and crashed on
# ("unexpected token '<EOF>' at line 1, column 1") before the task
# ever ran.
describe "Krikri::PlaybookParser (environment_null_test.cr)" do
  it "parses a bare environment: key as no environment at all" do
    pb = Krikri::PlaybookParser.parse_string(<<-YAML)
      - hosts: all
        tasks:
          - name: Configure
            ansible.builtin.command: ./configure
            environment:
      YAML
    task = pb.plays[0].tasks[0]
    task.environment.must_equal(nil)
    task.environment_raw.must_equal(nil)
  end

  it "still parses the dict and string forms of environment:" do
    pb = Krikri::PlaybookParser.parse_string(<<-YAML)
      - hosts: all
        tasks:
          - name: dict form
            ansible.builtin.command: ./configure
            environment:
              PATH: /opt/bin
          - name: string form
            ansible.builtin.command: ./configure
            environment: "{{ proxy_env }}"
      YAML
    tasks = pb.plays[0].tasks
    tasks[0].environment.must_equal({"PATH" => "/opt/bin"})
    tasks[0].environment_raw.must_equal(nil)
    tasks[1].environment.must_equal(nil)
    tasks[1].environment_raw.must_equal("{{ proxy_env }}")
  end
end
