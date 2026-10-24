require "../minitest_helper"
require "file_utils"

# Double-templated constant terms whose sole {{ }} span re-renders to
# Python None (a null variable) vs ansible-playbook 2.19.11
# (live-verified): ansible-native typing keeps the constant's TYPE, so
# the file lookup receives real None - find_file_in_search_path warns
# "Invalid request to find a file that matches a \"null\" value" and the
# not-found error names None plainly - instead of krikri's old empty
# path (''), and a genuinely empty ('') term keeps the old message.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "lookup file null double-templated term" do
  it "reports None for a null-variable file term, keeps the empty-string term" do
    playbook = File.tempname("lookup-null", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          local_public_key:
        tasks:
          - debug: msg="null={{ lookup('file', '{{ local_public_key }}') }}"
            ignore_errors: true
          - debug: msg="empty={{ lookup('file', '') }}"
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("Invalid request to find a file that matches a \"null\" value")
    text.must_include("The lookup plugin 'file' failed: Unable to access the file None: File not found. Use -vvvvv to see paths searched.")
    text.must_include("The lookup plugin 'file' failed: Unable to access the file '': File not found. Use -vvvvv to see paths searched.")
  ensure
    if pb = playbook
      File.delete(pb) if File.exists?(pb)
    end
  end
end
