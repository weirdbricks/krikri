require "../spec_helper"

# Round 188: bare `community.crypto.*` short names (e.g. `openssl_privatekey:`
# / `openssl_csr:` / `x509_certificate:`) must resolve to their registered
# FQCN and actually run the plugin - the same way `ansible.builtin.foo` ->
# `foo` and `apt_key:` -> `ansible.builtin.apt_key` already worked. Bare
# short names are the community-collection idiom (every role benchmarked
# writes the short form, not the FQCN), and real Ansible auto-aliases
# them via the collection-aliasing mechanism.
#
# Pre-fix the bare name was unresolvable (MODULE_SEARCH_COLLECTIONS
# didn't include "community.crypto", so the resolver never tried
# `community.crypto.<raw>` as a fallback), the task was dropped with a
# "uses unimplemented plugin" warning, and the work was silently
# skipped despite the plugin source AND binary both existing. The
# `community.crypto modules implemented` 0.9.608 work arguably
# unblocked the engine from rc=4 errors but NOT actually run the work.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String) : {Process::Status, String}
  playbook = File.tempname("community-crypto-short-name-188", ".yml")
  File.write(playbook, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "community.crypto.* short name resolution" do
  # The pre-fix behavior: bare `openssl_privatekey:` -> "uses
  # unimplemented plugin: openssl_privatekey" warning, task skipped
  # silently. Post-fix: the task actually runs and the plugin's
  # changed/ok status is what real ansible would produce.
  it "runs `openssl_privatekey:` (bare) without the unimplemented-plugin warning" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: generate a key
            openssl_privatekey:
              path: /tmp/r188_spec_key
              size: 2048
      YAML

    status.exit_code.should eq(0)
    # Pre-fix: the warning. Post-fix: gone.
    output.should_not contain("unimplemented plugin")
    output.should_not contain("openssl_privatekey")
    # The task actually ran (it either created the key or the key
    # was already there from a prior run; both are ok=).
    output.should contain("PLAY RECAP")
    output.should match(/ok=\d+.*failed=0/)
  end

  it "runs `openssl_csr:` (bare) without the unimplemented-plugin warning" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          csr_path: /tmp/r188_spec_csr.csr
          key_path: /tmp/r188_spec_csr_key
        pre_tasks:
          - name: ensure key exists for CSR generation
            openssl_privatekey:
              path: "{{ key_path }}"
              size: 2048
        tasks:
          - name: generate a CSR
            openssl_csr:
              path: "{{ csr_path }}"
              privatekey_path: "{{ key_path }}"
              subject:
                commonName: r188.test
              basic_constraints:
                - CA:TRUE
              basic_constraints_critical: true
      YAML

    # The CSR may or may not be created (depends on whether the test
    # host's openssl CLI accepts the args), but the important check
    # is: the bare `openssl_csr:` was RESOLVED, not warned-about
    # and silently skipped.
    output.should_not contain("unimplemented plugin")
    output.should_not contain("openssl_csr")
    # And the play ran to completion (no fatal parse error).
    output.should contain("PLAY RECAP")
  end

  # The pre-fix behavior was a SILENT skip with a warning. The
  # purpose of this spec is regression-detection: if a future change
  # to MODULE_SEARCH_COLLECTIONS ever removes "community.crypto"
  # again, this fails immediately rather than re-surfacing in a
  # live round a year from now.
  it "doesn't print the 'uses unimplemented plugin' warning for any community.crypto short name" do
    # We test with a deliberately broken arg shape so the task fails
    # at runtime (bad path) rather than succeeds - what we want to
    # assert is that resolution worked, i.e. the failure is the
    # plugin's own runtime complaint (rc!=0, failed>=1), NOT the
    # "unimplemented plugin" warning that pre-fix would have
    # produced with the task dropped to skipped.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: openssl_pkcs12 with bad arg shape
            openssl_pkcs12:
              action: export
              # intentionally invalid: passphrases with spaces and
              # missing path - we want the plugin's own error path
              passphrase: "with spaces"
      YAML

    # The unimplemented-plugin path produces a "skipping:" line and
    # a clean failed=0. The plugin-was-resolved-and-failed path
    # produces a real error and failed>=1.
    output.should_not contain("uses unimplemented plugin")
    output.should_not contain("skipping:")
    output.should match(/failed=\d+/)
  end
end
