require "../minitest_helper"

# `x is version_compare(min, '>=')` - Ansible's older alias for the
# `version` test, still accepted by ansible-core 2.19.12 (verified live,
# round173, Rocky 9.6: the same playbook recaps ok=1 failed=0 there).
#
# ConditionalEvaluator only recognized `is version(...)`, so
# `version_compare` fell through to the generic comparison splitter,
# which mistook the `>=` INSIDE the quoted operator argument for a real
# comparison operator. That was silently benign while conditionals were
# lenient (it just evaluated false); once 0.9.548 made a bare undefined
# reference RAISE, the same misparse started hard-failing the task with
# "Error while evaluating conditional: '')' is undefined" - breaking the
# single most common version-gate idiom in real roles.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("version-compare", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "version_compare test alias" do
  it "evaluates version_compare() like version(), for literal and variable arguments" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          minver: "2.11"
        tasks:
          - name: version with var arg
            ansible.builtin.debug: {msg: "A-ran"}
            when: ansible_version.string is version(minver, '>=')
          - name: version_compare with literal arg
            ansible.builtin.debug: {msg: "C-ran"}
            when: ansible_version.string is version_compare('2.11', '>=')
          - name: version_compare with var arg
            ansible.builtin.debug: {msg: "D-ran"}
            when: ansible_version.string is version_compare(minver, '>=')
      YAML

    status.success?.must_equal(true)
    output.wont_include("Error while evaluating conditional")
    output.must_include("A-ran")
    output.must_include("C-ran")
    output.must_include("D-ran")
    output.must_include("failed=0")
  end

  # The compare-to argument was only ever unquoted, never resolved, so a
  # VARIABLE argument was version-compared as its own literal name.
  # Live-verified against ansible-core 2.19.12 (round173): identical
  # ok=2 skipped=1 for this playbook on both engines.
  it "resolves a variable compare-to argument instead of comparing its name" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          minver: "2.11"
        tasks:
          - name: var compare-to, true branch
            ansible.builtin.debug: {msg: "VAR-ARG-TRUE"}
            when: ansible_version.string is version(minver, '>=')
          - name: var compare-to, false branch
            ansible.builtin.debug: {msg: "SHOULD-NOT-PRINT"}
            when: ansible_version.string is version(minver, '<')
      YAML

    status.success?.must_equal(true)
    output.must_include("VAR-ARG-TRUE")
    output.wont_include("SHOULD-NOT-PRINT")
    output.must_include("skipped=1")
  end

  it "works inside an assert: that: as well" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          minver: "2.11"
        tasks:
          - name: version gate via assert
            ansible.builtin.assert:
              that:
                - ansible_version.string is version_compare(minver, '>=')
      YAML

    status.success?.must_equal(true)
    output.wont_include("Error while evaluating conditional")
    output.must_include("failed=0")
  end

  # Round 5210000 (bodsch.icingaweb2): trailing kwargs in a test call -
  # `is version('2.11', '<=', strict=True)` - parsed as a garbage
  # identifier ("Error while evaluating conditional: '', strict=True)'
  # is undefined") because the version-test handler only accepted
  # exactly two positional arguments. The full validation matrix below
  # is byte-pinned against ansible-core 2.19.11 (each verdict and error
  # message verified live, including Python's positional binding of the
  # 3rd/4th call arguments into strict/version_type).
  it "evaluates trailing kwargs: strict=True pads and skips the loose answer" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug: {msg: "STRICT-PAD-TRUE"}
            when: "'1.0' is version('1.0.0', '==', strict=True)"
          - debug: {msg: "LOOSE-PAD-FALSE"}
            when: "'1.0' is version('1.0.0', '==')"
          - debug: {msg: "STRICT-LT-TRUE"}
            when: "'1.0b1' is version('1.0', '<', strict=True)"
          - debug: {msg: "OPERATOR-KWARG-TRUE"}
            when: "'1.2.3' is version('2.11', operator='<=', strict=True)"
          - debug: {msg: "ONE-ARG-EQ-TRUE"}
            when: "'2.11' is version('2.11')"
          - debug: {msg: "VERSION-KWARG-TRUE"}
            when: "'1.2.3' is version(version='2.11', operator='<=')"
          - debug: {msg: "THIRD-POSITIONAL-STRICT"}
            when: "'1.2.3' is version('2.11', '<=', 'extra')"
      YAML

    status.success?.must_equal(true)
    output.must_include("STRICT-PAD-TRUE")
    output.wont_include("LOOSE-PAD-FALSE")
    output.must_include("STRICT-LT-TRUE")
    output.must_include("OPERATOR-KWARG-TRUE")
    output.must_include("ONE-ARG-EQ-TRUE")
    output.must_include("VERSION-KWARG-TRUE")
    output.must_include("THIRD-POSITIONAL-STRICT")
    output.must_include("failed=0")
  end

  it "fails the task with real's exact validation wordings" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug: {msg: "A"}
            when: "'1.2.3' is version('2.11', '<=', bogus=3)"
            ignore_errors: true
          - debug: {msg: "B"}
            when: "'1.2.3' is version('2.11', '<=', strict=True, version_type='loose')"
            ignore_errors: true
          - debug: {msg: "C"}
            when: "'1.2.3' is version('2.11', '~', strict=True)"
            ignore_errors: true
          - debug: {msg: "D"}
            when: "'' is version('1.0')"
            ignore_errors: true
          - debug: {msg: "E"}
            when: "'1.2.3' is version('')"
            ignore_errors: true
          - debug: {msg: "F"}
            when: "'1.2.3' is version('2.11', '<', version_type='bogus')"
            ignore_errors: true
          - debug: {msg: "G"}
            when: "'1.2.3.4' is version('1.2.3', '==', strict=True)"
            ignore_errors: true
          - debug: {msg: "H"}
            when: "'1.2.3' is version('2.11', version='2.12')"
            ignore_errors: true
          - debug: {msg: "I"}
            when: "'1.2.3' is version('2.11', '<=', operator='>=')"
            ignore_errors: true
          - debug: {msg: "J"}
            when: "'1.2.3' is version('2.11', '<', 'True', 'loose', 'x')"
            ignore_errors: true
          - debug: {msg: "K"}
            when: "'1.2.3' is version_compare('2.11', '~', strict=True)"
            ignore_errors: true
      YAML

    # Every failing task carries ignore_errors, so the play itself exits 0.
    status.success?.must_equal(true)
    output.must_include("version_compare() got an unexpected keyword argument 'bogus'")
    output.must_include("Cannot specify both 'strict' and 'version_type'")
    output.must_include("Invalid operator type (~). Must be one of '==', '=', 'eq', '<', 'lt', '<=', 'le', '>', 'gt', '>=', 'ge', '!=', '<>', 'ne'")
    output.must_include("Input version value cannot be empty")
    output.must_include("Version parameter to compare against cannot be empty")
    output.must_include("Invalid version type (bogus). Must be one of 'loose', 'strict', 'semver', 'semantic', 'pep440'")
    output.must_include("Version comparison failed: invalid version number '1.2.3.4'")
    output.must_include("version_compare() got multiple values for argument 'version'")
    output.must_include("version_compare() got multiple values for argument 'operator'")
    output.must_include("version_compare() takes from 2 to 5 positional arguments but 6 were given")
    # The alias spelling carries its own name in the framing.
    output.must_include("The test plugin 'ansible.builtin.version_compare' failed: Invalid operator type (~)")
    # Test-plugin failures carry the plain "Task failed: " framing, not
    # the conditional-evaluation wrapper.
    output.wont_include("Error while evaluating conditional: The test plugin")
  end

  it "compares version_type='semver' with real's grammar and prerelease ordering" do
    _status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debug: {msg: "SEMVER-PRE-TRUE"}
            when: "'1.0.0-rc1' is version('1.0.0', '<', version_type='semver')"
          - debug: {msg: "SHOULD-NOT-RUN"}
            when: "'1.2' is version('1.2.3', '==', version_type='semver')"
            ignore_errors: true
      YAML

    output.must_include("SEMVER-PRE-TRUE")
    # The Origin banner quotes the neighboring task NAME from the playbook
    # source, so only the rendered msg shape is asserted absent.
    output.wont_include("%q{\"msg\": \"SHOULD-NOT-RUN\"}")
    output.must_include("Version comparison failed: invalid semantic version '1.2'")
  end
end
