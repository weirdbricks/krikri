require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

# Issues #1448 and #1471: ansible-core post-validates a play's
# always_post_validate keywords when the play starts - after its
# vars_prompt answers but before its PLAY banner and hosts matching - so
# `gather_facts:`/`force_handlers:` values its strict boolean() refuses,
# and a `max_fail_percentage:` value its percent conversion refuses, abort
# the whole run (rc=4, nothing on stdout) with a two-link error block on
# stderr. Only those three qualify: every other bool play keyword is an
# inherited attribute that Play.post_validate skips.
describe "play keyword post-validation" do
  it "refuses a play whose gather_facts: value is not convertible to bool" do
    playbook = File.tempname("play-gather-facts-invalid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: kpg-maybe
        tasks:
          - name: Never runs
            ansible.builtin.debug:
              msg: INVALID-GATHER-FACTS-RAN
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: stdout, error: stderr)

    stderr_text = stderr.to_s
    status.exit_code.must_equal(4, stderr_text)
    # The play banner comes after the post-validation, so nothing ran.
    stdout.to_s.must_equal("", "real prints no play output for this refusal")
    stderr_text.must_include("[ERROR]: Error processing keyword 'gather_facts': The value 'kpg-maybe' could not be converted to 'bool'.")
    stderr_text.must_include("\nError processing keyword 'gather_facts'.\n")
    stderr_text.must_include("\nThe value 'kpg-maybe' could not be converted to 'bool'.\n")
    # Both chain links point at the keyword's value token.
    stderr_text.scan("Origin: #{File.expand_path(playbook)}:3:17").size.must_equal(2, stderr_text)
    stderr_text.must_include("<<< caused by >>>")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "refuses a play whose force_handlers: value is not convertible to bool" do
    playbook = File.tempname("play-force-handlers-invalid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        force_handlers: kpg-maybe
        tasks:
          - name: Never runs
            ansible.builtin.debug:
              msg: INVALID-HANDLERS-RAN
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: stdout, error: stderr)

    stderr_text = stderr.to_s
    status.exit_code.must_equal(4, stderr_text)
    stdout.to_s.must_equal("", "real prints no play output for this refusal")
    stderr_text.must_include("[ERROR]: Error processing keyword 'force_handlers': The value 'kpg-maybe' could not be converted to 'bool'.")
    stderr_text.scan("Origin: #{File.expand_path(playbook)}:4:19").size.must_equal(2, stderr_text)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "refuses a play whose max_fail_percentage: value is not convertible to percent" do
    playbook = File.tempname("play-max-fail-percentage-invalid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        max_fail_percentage: kpg-many
        tasks:
          - name: Never runs
            ansible.builtin.debug:
              msg: INVALID-PERCENT-RAN
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: stdout, error: stderr)

    stderr_text = stderr.to_s
    status.exit_code.must_equal(4, stderr_text)
    stdout.to_s.must_equal("", "real prints no play output for this refusal")
    stderr_text.must_include("[ERROR]: Error processing keyword 'max_fail_percentage': The value 'kpg-many' could not be converted to 'percent'.")
    stderr_text.must_include("\nThe value 'kpg-many' could not be converted to 'percent'.\n")
    stderr_text.scan("Origin: #{File.expand_path(playbook)}:4:24").size.must_equal(2, stderr_text)
    stderr_text.must_include("<<< caused by >>>")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "refuses the same play under --list-tasks, which validates before listing" do
    playbook = File.tempname("play-max-fail-percentage-list", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        max_fail_percentage: kpg-many
        tasks:
          - name: Never listed
            ansible.builtin.debug:
              msg: INVALID-PERCENT-LISTED
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["--list-tasks", "-c", "local", "-i", INVENTORY, playbook], output: stdout, error: stderr)

    stderr_text = stderr.to_s
    status.exit_code.must_equal(4, stderr_text)
    # Real validates before it records the listing, so not even the
    # "playbook:" header is printed.
    stdout_text = stdout.to_s
    stdout_text.wont_include("playbook:")
    stdout_text.wont_include("Never listed")
    stderr_text.must_include("Error processing keyword 'max_fail_percentage'.")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "reports the first unconvertible keyword in ansible's own order" do
    playbook = File.tempname("play-bool-and-percent-invalid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: kpg-maybe
        max_fail_percentage: kpg-many
        tasks:
          - name: Never runs
            ansible.builtin.debug:
              msg: BOTH-INVALID-RAN
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: stdout, error: stderr)

    stderr_text = stderr.to_s
    status.exit_code.must_equal(4, stderr_text)
    stderr_text.must_include("Error processing keyword 'gather_facts'.")
    stderr_text.wont_include("max_fail_percentage")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "aborts at the offending play, keeping the earlier play's output" do
    playbook = File.tempname("play-second-gather-facts-invalid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: First play task
            ansible.builtin.debug:
              msg: FIRST-PLAY-RAN
      - hosts: localhost
        connection: local
        gather_facts: kpg-maybe
        tasks:
          - name: Second play task
            ansible.builtin.debug:
              msg: SECOND-PLAY-RAN
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: stdout, error: stderr)

    stderr_text = stderr.to_s
    status.exit_code.must_equal(4, stderr_text)
    # Real validates each play as it is reached, so the first play ran and
    # the second never printed its banner.
    stdout_text = stdout.to_s
    stdout_text.must_include("FIRST-PLAY-RAN")
    stdout_text.wont_include("SECOND-PLAY-RAN")
    stderr_text.must_include("Error processing keyword 'gather_facts'.")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "still accepts convertible gather_facts: values" do
    playbook = File.tempname("play-gather-facts-valid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: no
        tasks:
          - name: Runs
            ansible.builtin.debug:
              msg: VALID-GATHER-FACTS-RAN
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(true, output_text)
    output_text.must_include("VALID-GATHER-FACTS-RAN")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "accepts a padded boolean string, which ansible's boolean() strips" do
    playbook = File.tempname("play-gather-facts-padded", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: " no "
        tasks:
          - name: Runs
            ansible.builtin.debug:
              msg: PADDED-GATHER-FACTS-RAN
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(true, output_text)
    output_text.must_include("PADDED-GATHER-FACTS-RAN")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "accepts a max_fail_percentage: with a percent sign, which real strips" do
    playbook = File.tempname("play-max-fail-percentage-valid", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        max_fail_percentage: 50%
        tasks:
          - name: Runs
            ansible.builtin.debug:
              msg: PERCENT-LIMIT-RAN
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    output_text = output.to_s
    status.success?.must_equal(true, output_text)
    output_text.must_include("PERCENT-LIMIT-RAN")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
