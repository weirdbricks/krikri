require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug spans the
# task-executor's role-relative src: resolution and the copy action's
# controller-side lookup, not the copy plugin binary itself.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(src_dir : String, playbook : String)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
  {status, output.to_s}
end

describe "copy:/template: src: with the subdir prefix baked in resolves against the role root" do
  it "copies src: templates/vimrc from <role>/templates/vimrc when the role ships no files/ dir" do
    # Real bug found benchmarking l3.dotfiles (round 5290001): its
    # tasks/vimrc.yml is `copy: {src: 'templates/vimrc'}` with the file
    # at <role>/templates/vimrc - the role ships no files/ dir at all,
    # so the old role_files_dir-anchored lookup never ran and the
    # controller-side roots search missed the role root entirely. Real's
    # _find_needle falls back to role_path + '/' + source after the
    # files/-dirs search, and krikri's own "Searched in:" error even
    # LISTED <role>/templates/vimrc among the candidates it never
    # actually opened. ansible-playbook 2.19.11 copies it fine.
    src_dir = File.tempname("copy-role-root-src")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "templates"))
    File.write(File.join(src_dir, "roles", "myrole", "templates", "vimrc"), "set number\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Copy vimrc via templates/ relative src
        ansible.builtin.copy:
          src: 'templates/vimrc'
          dest: #{File.join(src_dir, "vimrc-out")}
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status, output = run_playbook(src_dir, playbook)

    status.success?.must_equal(true, output.to_s)
    output.to_s.wont_include("Could not find or access")
    File.read(File.join(src_dir, "vimrc-out")).must_equal("set number\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "copies src: templates/vimrc from the role root even when a files/ dir exists" do
    # The files/-dir presence used to gate the role-root fallback in the
    # pre-resolution pass; with a files/ dir shipped (but no matching
    # file) the role-root candidate had to still win.
    src_dir = File.tempname("copy-role-root-src-with-files")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "templates"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "files"))
    File.write(File.join(src_dir, "roles", "myrole", "templates", "vimrc"), "set number\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Copy vimrc via templates/ relative src
        ansible.builtin.copy:
          src: 'templates/vimrc'
          dest: #{File.join(src_dir, "vimrc-out")}
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status, output = run_playbook(src_dir, playbook)

    status.success?.must_equal(true, output.to_s)
    File.read(File.join(src_dir, "vimrc-out")).must_equal("set number\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "renders src: templates/x.j2 from the role root via template:" do
    # Same fallback covers template: - real's _find_needle is shared,
    # only the searched subdir differs (templates/ vs files/).
    src_dir = File.tempname("template-role-root-src")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "templates"))
    File.write(File.join(src_dir, "roles", "myrole", "templates", "motd.j2"), "hello {{ ansible_hostname | default('world') }}\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Template motd via templates/ relative src
        ansible.builtin.template:
          src: 'templates/motd.j2'
          dest: #{File.join(src_dir, "motd-out")}
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status, output = run_playbook(src_dir, playbook)

    status.success?.must_equal(true, output.to_s)
    File.read(File.join(src_dir, "motd-out")).must_equal("hello world\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "fails a total miss with the RELATIVE src and the full Searched-in list" do
    # Real's _find_needle raises AnsibleFileNotFound naming the still-
    # relative src with the complete candidate list; the old absolute
    # fallback rewrite turned the same miss into the listless
    # absolute-src wording real never produces.
    src_dir = File.tempname("copy-role-root-src-miss")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "files"))
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Copy missing src
        ansible.builtin.copy:
          src: 'templates/absent.cfg'
          dest: #{File.join(src_dir, "absent-out")}
        ignore_errors: true
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    status, output = run_playbook(src_dir, playbook)

    status.success?.must_equal(true, output.to_s)
    searched = [
      File.join(src_dir, "roles", "myrole", "files", "templates", "absent.cfg"),
      File.join(src_dir, "roles", "myrole", "templates", "absent.cfg"),
      File.join(src_dir, "roles", "myrole", "tasks", "files", "templates", "absent.cfg"),
      File.join(src_dir, "roles", "myrole", "tasks", "templates", "absent.cfg"),
      File.join(src_dir, "files", "templates", "absent.cfg"),
      File.join(src_dir, "templates", "absent.cfg"),
    ].join("\n\t")
    output.to_s.must_include("Could not find or access 'templates/absent.cfg'\nSearched in:\n\t#{searched} on the Ansible Controller.")
    # the absolute fallback rewrite never leaks into the message
    output.to_s.wont_include("Could not find or access '#{File.join(src_dir, "roles")}")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "resolves a playbook-level src: against the playbook's own files/ dir" do
    # Same candidate list at playbook level: real's _find_needle searches
    # <task_dir>/files/<src> (the basedir entries) - the old roots list
    # only ever joined the playbook dir itself, so src: pf.txt with the
    # file at <playbook>/files/pf.txt failed here while ansible-playbook
    # copied it.
    src_dir = File.tempname("copy-playbook-files-src")
    Dir.mkdir_p(File.join(src_dir, "files"))
    File.write(File.join(src_dir, "files", "pf.txt"), "playbook file\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Copy playbook files/ src
            ansible.builtin.copy:
              src: pf.txt
              dest: #{File.join(src_dir, "pf-out")}
      YAML

    status, output = run_playbook(src_dir, playbook)

    status.success?.must_equal(true, output.to_s)
    File.read(File.join(src_dir, "pf-out")).must_equal("playbook file\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
