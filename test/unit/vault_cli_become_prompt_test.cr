require "../minitest_helper"
require "../../src/krikri/vault_cli"

# The -K prompt's wording is ansible parity: cli/__init__.py adds the
# "[defaults to SSH password]" suffix only when -k is also asking for the
# connection password (issue #1689).
describe "Krikri::VaultCli.become_prompt" do
  it "appends ansible's [defaults to SSH password] only when -k is also prompting" do
    Krikri::VaultCli.become_prompt(true).must_equal("BECOME password[defaults to SSH password]: ")
    Krikri::VaultCli.become_prompt(false).must_equal("BECOME password: ")
  end
end
