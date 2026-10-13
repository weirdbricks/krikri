require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# A static import_tasks: whose path references a variable undefined at
# PLAYBOOK-LOAD time is ansible-core's own whole-playbook refusal: the
# two-segment [ERROR] cause chain on STDERR with rc=4 (live-verified vs
# 2.19.11) - the task-level evaluation error (Origin at the task's own
# mapping, the static-import hint as help text) causing the bare
# undefined-variable error (Origin at the import_tasks VALUE itself).
describe "StaticImportUndefinedError render" do
  it "renders the exact two-segment Origin block for an undefined var in the import path" do
    root = PluginSpecHelper.tmp_path("static_undef_render")
    Dir.mkdir_p(root)
    path = File.join(root, "pb.yml")
    File.write(path, <<-YAML)
      - hosts: all
        gather_facts: true
        tasks:
          - import_tasks: "install-{{ ansible_os_family }}.yml"
      YAML

    ex = assert_raises(Krikri::StaticImportUndefinedError) do
      Krikri::PlaybookParser.parse(File.expand_path(path))
    end
    ex.message.to_s.must_equal(
      "Error when evaluating variable in import path 'install-{{ ansible_os_family }}.yml': " \
      "'ansible_os_family' is undefined\n" \
      "When using static imports, ensure that any variables used in their names are defined in " \
      "vars/vars_files or extra-vars passed in from the command line. Static imports cannot use " \
      "variables from facts or inventory sources like group or host vars.")

    origin = File.expand_path(path)
    expected = "[ERROR]: Error when evaluating variable in import path 'install-{{ ansible_os_family }}.yml': 'ansible_os_family' is undefined\n\n" \
               "Error when evaluating variable in import path 'install-{{ ansible_os_family }}.yml'.\n" \
               "Origin: #{origin}:4:7\n" \
               "\n" \
               "2   gather_facts: true\n" \
               "3   tasks:\n" \
               "4     - import_tasks: \"install-{{ ansible_os_family }}.yml\"\n" \
               "        ^ column 7\n" \
               "\n" \
               "When using static imports, ensure that any variables used in their names are defined in vars/vars_files\n" \
               "or extra-vars passed in from the command line. Static imports cannot use variables from facts or inventory\n" \
               "sources like group or host vars.\n" \
               "\n" \
               "<<< caused by >>>\n" \
               "\n" \
               "'ansible_os_family' is undefined\n" \
               "Origin: #{origin}:4:21\n" \
               "\n" \
               "2   gather_facts: true\n" \
               "3   tasks:\n" \
               "4     - import_tasks: \"install-{{ ansible_os_family }}.yml\"\n" \
               "                      ^ column 21\n" \
               "\n"
    ex.render.must_equal(expected)
  end
end
