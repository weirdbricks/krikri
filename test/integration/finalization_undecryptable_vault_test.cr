require "../minitest_helper"
require "file_utils"

# An undecryptable vault variable referenced from a module arg fails arg
# finalization, and ansible-core 2.19.11 prints the four-level [ERROR]
# chain for it - even under no_log: true, since the failure happens
# before the result gets censored (live-captured on
# adlytaibi.sgws_config's sgws_authorize task, issue #196). The
# innermost stanza's Origin points at the `!vault` token of the
# variable's DEFINING vars file, not the task.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (undecryptable vault variable)" do
  it "prints the four-level block with the vault definition's origin for a no_log role task" do
    tempdir = File.tempname("final-block-vault").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "vaultrole")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    FileUtils.mkdir_p(File.join(role, "vars"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - vaultrole
      YAML
    tasks_file = File.join(role, "tasks", "sgws_authorize.yml")
    File.write(tasks_file, <<-YAML)
      ---
      - name: Get grid authorization token
        uri:
          url: https://{{ grid_admn }}/api/v2/authorize
          method: POST
          body: {
            "username": "{{ grid_user }}",
            "password": "{{ grid_pass }}",
            "cookie": true,
            "csrfToken": false
          }
          body_format: json
          validate_certs: false
        no_log: true
      YAML
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      ---
      - import_tasks: sgws_authorize.yml
      YAML
    vars_file = File.join(role, "vars", "main.yml")
    File.write(vars_file, <<-YAML)
      grid_admn: dc1-adm1.demo.netapp.com
      grid_user: root
      grid_pass: !vault |
                $ANSIBLE_VAULT;1.1;AES256
                33326464393233333431393536303237346434396539393463343861363337373835326332373032
                3461633736373532646136333731393663623734333430640a303633633663633435343832626134
                33303163316366356631383965626262626663323966666336386537663938383334636639313261
                3764646365633763610a333963643434336138343166633236666336643733343136316265613031
                3766
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("Task failed: Finalization of task args for 'ansible.builtin.uri' failed: Error while resolving value for 'body': Error rendering template: Attempt to use undecryptable variable: Attempting to decrypt but no vault secrets found.")
    text.must_include("Error while resolving value for 'body': Error rendering template.")
    text.must_include("Attempt to use undecryptable variable: Attempting to decrypt but no vault secrets found.")
    text.must_include("Origin: #{tasks_file}:2:3")
    text.must_include("Origin: #{tasks_file}:3:3")
    text.must_include("Origin: #{tasks_file}:6:11")
    text.must_include("Origin: #{vars_file}:3:12")
    text.must_include(%(fatal: [localhost]: FAILED! => {"censored": "the output has been hidden due to the fact that 'no_log: true' was specified for this result", "changed": false}))
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  # Same chain, but the undecryptable variable arrives through a
  # play-level vars_files: entry instead of a role's vars/ - real 2.19.11
  # points the vault-definition Origin at the vars_files path's `!vault`
  # token there too (issue #196).
  it "prints the four-level block with the vault definition's origin for a no_log task with a play-level vars_files entry" do
    tempdir = File.tempname("final-block-vault-vf").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    vars_file = File.join(tempdir, "vault_vars.yml")
    File.write(vars_file, <<-YAML)
      grid_admn: dc1-adm1.demo.netapp.com
      grid_user: root
      grid_pass: !vault |
                $ANSIBLE_VAULT;1.1;AES256
                33326464393233333431393536303237346434396539393463343861363337373835326332373032
                3461633736373532646136333731393663623734333430640a303633633663633435343832626134
                33303163316366356631383965626262626663323966666336386537663938383334636639313261
                3764646365633763610a333963643434336138343166633236666336643733343136316265613031
                3766
      YAML
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars_files:
          - #{vars_file}
        tasks:
          - name: Get grid authorization token
            uri:
              url: https://{{ grid_admn }}/api/v2/authorize
              method: POST
              body: {
                "username": "{{ grid_user }}",
                "password": "{{ grid_pass }}",
                "cookie": true,
                "csrfToken": false
              }
              body_format: json
              validate_certs: false
            no_log: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("Task failed: Finalization of task args for 'ansible.builtin.uri' failed: Error while resolving value for 'body': Error rendering template: Attempt to use undecryptable variable: Attempting to decrypt but no vault secrets found.")
    text.must_include("Error while resolving value for 'body': Error rendering template.")
    text.must_include("Attempt to use undecryptable variable: Attempting to decrypt but no vault secrets found.")
    text.must_include("Origin: #{playbook}:6:7")
    text.must_include("Origin: #{playbook}:7:7")
    text.must_include("Origin: #{playbook}:10:15")
    text.must_include("Origin: #{vars_file}:3:12")
    text.must_include(%(fatal: [localhost]: FAILED! => {"censored": "the output has been hidden due to the fact that 'no_log: true' was specified for this result", "changed": false}))
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
