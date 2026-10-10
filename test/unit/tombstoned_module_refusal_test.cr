require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# The parse-time tombstone refusal for collection-removed modules and
# action plugins. Real (probed by the orchestrator against
# ansible-core 2.19.11 - do not re-derive) refuses the WHOLE playbook
# at load time for a task using a module the collection's
# meta/runtime.yml plugin_routing.<leaf>.tombstone marks removed:
# rc=1 (NOT the generic couldn't-resolve rc=4), zero tasks run (not
# even `Gathering Facts`), even when the offending task sits behind
# `when: false`, with "[ERROR]: <message>" plus the task's Origin
# block on stderr. The check consults the RESOLVED name ahead of
# trusting krikri's own native-resolution result, so a tombstoned FQCN
# krikri also implements natively (community.crypto.openssl_certificate
# -> MODULE_ALIASES -> x509_certificate) refuses the load too.
#
# The message table is REMOVED_MODULE_TOMBSTONES
# (src/krikri/module_registry.cr), extended from the orchestrator's
# collection-reference data (.tombstones_ref.json): every entry there
# is type =="modules" (the data set has zero type =="action" entries;
# the one action-plugin tombstone real refuses at load is
# ansible.builtin.include, refused upstream of the table).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook_binary(pb : String) : {Process::Status, String, String}
  playbook = File.tempname("tombstone-refusal", ".yml")
  File.write(playbook, pb)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: out_io, error: err_io)
  {status, out_io.to_s, err_io.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "parse-time tombstone refusal for collection-removed modules" do
  it "raises RemovedModuleError with community.windows.win_domain_user's exact removal message" do
    # community.windows 3.0.0 tombstoned the module in favor of
    # microsoft.ad.user - ansible-playbook refuses the whole playbook
    # at load (probed real 2.19.11: rc=1, zero tasks run, even behind
    # a false when:).
    assert_raises_message(Krikri::RemovedModuleError,
      "The 'community.windows.win_domain_user' module has been removed. " \
      "Use microsoft.ad.user instead. This feature was removed from " \
      "collection 'community.windows' version 3.0.0.") do
      Krikri::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: removed module
              community.windows.win_domain_user:
                name: x
        YAML
      )
    end
  end

  it "raises RemovedModuleError for a natively-implemented FQCN ahead of native resolution (community.crypto.openssl_certificate)" do
    # The tombstone check must fire BEFORE krikri's own native/alias
    # resolution: MODULE_ALIASES maps community.crypto.openssl_certificate
    # onto the existing x509_certificate plugin binary, and real's
    # loader instead resolves the name and then consults the
    # collection's runtime.yml tombstone - so the load aborts (probed
    # real 2.19.11: rc=1, zero tasks, even behind when: false), it does
    # not run the implemented module. The check used to live inside the
    # `unless resolved` branch of parse_task, where this spelling
    # resolved and never reached it.
    assert_raises_message(Krikri::RemovedModuleError,
      "The 'community.crypto.openssl_certificate' module has been removed. " \
      "The 'community.crypto.openssl_certificate' module has been renamed " \
      "to 'community.crypto.x509_certificate'. This feature was removed " \
      "from collection 'community.crypto' version 2.0.0.") do
      Krikri::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: removed despite native implementation
              community.crypto.openssl_certificate:
                path: /tmp/cert.pem
              when: false
        YAML
      )
    end
  end

  it "still resolves the builtin-runtime spellings of openssl_certificate onto x509_certificate" do
    # The inverse guard: only the community.crypto FQCN spelling is
    # tombstoned by community.crypto itself. The bare,
    # ansible.builtin.- and ansible.legacy.-qualified spellings resolve
    # through ansible_builtin_runtime.yml's redirect onto
    # community.crypto.x509_certificate, which no tombstone kills - a
    # role like weareinteractive.openssl writing the bare form must
    # keep running the implemented module.
    bare = Krikri::PlaybookParser.parse_string(<<-YAML
      - hosts: all
        tasks:
          - name: builtin redirect spelling
            openssl_certificate:
              path: /tmp/cert.pem
      YAML
    )
    bare.plays[0].tasks[0].module_name.must_equal("community.crypto.x509_certificate")
  end

  it "keeps the community.docker.docker_compose tombstone message byte-identical" do
    # The one pre-existing custom-message tombstone entry: keep its
    # value exactly as it was through the table's collection-wide
    # extension.
    Krikri::PlaybookParser::REMOVED_MODULE_TOMBSTONES["community.docker.docker_compose"].must_equal(
      Krikri::PlaybookParser::DOCKER_COMPOSE_REMOVAL_MESSAGE)
  end

  it "refuses community.general.webfaction_app with its own removal message" do
    # A different warning_text shape from the reference data - the
    # table entries carry each collection's own byte-identical removal
    # text, not a re-composed one.
    assert_raises_message(Krikri::RemovedModuleError,
      "The 'community.general.webfaction_app' module has been removed. " \
      "This module relied on HTTPS APIs that do not exist anymore and " \
      "there is no clear path to update. This feature was removed from " \
      "collection 'community.general' version 9.0.0.") do
      Krikri::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: removed module
              community.general.webfaction_app:
                name: x
        YAML
      )
    end
  end

  it "refuses the removed include: action plugin with its load-time removal message (RemovedActionError)" do
    # The one action-plugin tombstone real refuses at playbook load
    # (ansible.builtin.include, removed from ansible-core after
    # 2023-05-16) - the failure even when the include's file is
    # perfectly valid, and the reference data has no other
    # type =="action" entries.
    assert_raises_message(Krikri::RemovedActionError,
      "The 'ansible.builtin.include' action plugin has been removed. " \
      "Use include_tasks or import_tasks instead. This feature was " \
      "removed from ansible-core in a release after 2023-05-16.") do
      Krikri::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: removed include action
              ansible.builtin.include: other.yml
        YAML
      )
    end
  end

  it "keeps the generic couldn't-resolve UnresolvedModuleError path for a NON-tombstoned removed name" do
    # ec2_remote_facts has no custom concern here: it is
    # REMOVED_MODULE_TOMBSTONED with nil (generic wording), and even a
    # name like kubernetes.core.helm_repository (tombstoned nowhere,
    # krikri simply hasn't ported it) must NOT take the RemovedModuleError
    # rc=1 path - the graceful unavailable_module flow it keeps.
    assert_raises_message(Krikri::UnresolvedModuleError,
      "couldn't resolve module/action 'ec2_remote_facts'. " \
      "This often indicates a misspelling, missing collection, or incorrect module path.") do
      Krikri::PlaybookParser.parse_string(<<-YAML
        - hosts: all
          tasks:
            - name: generic refusal
              ec2_remote_facts:
        YAML
      )
    end
    parsed = Krikri::PlaybookParser.parse_string(<<-YAML
      - hosts: all
        tasks:
          - name: unimplemented, unresolved - graceful, not refused
            kubernetes.core.helm_repository:
              repo_name: foo
      YAML
    )
    parsed.plays[0].tasks[0].unavailable_module.must_equal("kubernetes.core.helm_repository")
  end
end

describe "parse-time tombstone refusal end to end (krikri-playbook binary)" do
  it "rc=1 with the [ERROR] + Origin block on stderr and zero tasks run for community.windows.win_domain_user" do
    # Whole-playbook-load refusal shape (probed real 2.19.11): not even
    # `Gathering Facts` runs, PLAY RECAP never prints, stderr carries
    # the message plus the task's Origin block.
    status, stdout, stderr = run_playbook_binary(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: removed module
            community.windows.win_domain_user:
              name: x
          - name: would-be-next
            ansible.builtin.debug: msg=hi
      YAML
    status.exit_code.must_equal(1, "stdout:\n#{stdout}\nstderr:\n#{stderr}")
    stderr.must_include("[ERROR]: The 'community.windows.win_domain_user' module has been removed. Use microsoft.ad.user instead. This feature was removed from collection 'community.windows' version 3.0.0.")
    stderr.must_include("Origin: ")
    stderr.must_include("tombstone-refusal")
    stderr.must_include("^ column ")
    stdout.wont_include("Gathering Facts")
    stdout.wont_include("TASK [")
    stdout.wont_include("PLAY RECAP")
  end

  it "rc=1 even behind `when: false` for the natively-implemented community.crypto.openssl_certificate FQCN" do
    status, stdout, stderr = run_playbook_binary(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: native-defeating tombstone
            community.crypto.openssl_certificate:
              path: /tmp/cert.pem
            when: false
      YAML
    status.exit_code.must_equal(1, "stdout:\n#{stdout}\nstderr:\n#{stderr}")
    stderr.must_include("The 'community.crypto.openssl_certificate' module has been removed.")
    stdout.wont_include("TASK [")
    stdout.wont_include("PLAY RECAP")
  end

  it "keeps the generic rc=4 end-of-run path for a genuinely-reached, non-tombstoned unimplemented module" do
    # The non-tombstoned unimplemented name must NOT take the tombstone
    # rc=1 path: run to a PLAY RECAP, then exit 4 via the runtime
    # reachable_unavailable_modules machinery (helm_repository is not
    # tombstoned anywhere - krikri simply hasn't ported it).
    status, stdout, _stderr = run_playbook_binary(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: unimplemented, genuinely reached
            kubernetes.core.helm_repository:
              repo_name: foo
          - name: still runs
            ansible.builtin.debug: msg=hi
      YAML
    status.exit_code.must_equal(4, "stdout:\n#{stdout}")
    stdout.must_include("PLAY RECAP")
    stdout.must_include("TASK [still runs]")
    _stderr.wont_include("module has been removed")
  end
end
