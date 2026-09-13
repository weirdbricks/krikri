require "../spec_helper"

# Proactive parameter-coverage pass for the deb822_repository plugin,
# verified field-by-field against the real module's own source
# (ansible/modules/deb822_repository.py):
#
# - format_field_name maps name → X-Repolib-Name, uris → URIs, and every
#   other param via param.replace('_', '-').title() (types → Types,
#   inrelease_path → Inrelease-Path, ...).
# - List-typed params (uris/suites/components/types/architectures/
#   languages/targets/exclude/include) are documented LIST types, so a
#   real YAML list arrives here as a JSON-array-shaped STRING after
#   task-param substitution; a comma-separated scalar is accepted too
#   (real Ansible's check_type_list backward compat).
# - Bool-typed params are written as literal yes/no, only when given.
# - inrelease_path IS written to the file (real module never pops it,
#   unlike mode/state) as "Inrelease-Path:".
# - Fields are emitted sorted by the underlying PYTHON param name
#   (`for key, value in sorted(params.items())`), pinned by the
#   full-render fixture below.
# - The result carries the rendered content back as `repo:`, matching
#   the real module's own documented RETURN block - which is also what
#   makes these check-mode specs able to assert exact rendering without
#   root (the real write path needs /etc/apt/sources.list.d/).
#
# Not covered here (needs root, verified live instead): the real file
# write itself and state=absent's keyring cleanup under /etc/apt/keyrings.
describe "deb822_repository param coverage" do
  it "space-joins a JSON-array-shaped list param (a real YAML list after task-param substitution)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "param-audit-list-shape",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "components" => "[\"main\", \"contrib\", \"non-free\"]",
      "check_mode" => "true",
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    result["repo"].as_s.should contain("Components: main contrib non-free")
  end

  it "space-joins a JSON-array-shaped types: into one Types: field" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "param-audit-types-list",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "types"      => "[\"deb\", \"deb-src\"]",
      "check_mode" => "true",
    })

    result["repo"].as_s.should contain("Types: deb deb-src")
  end

  it "still accepts a comma-separated scalar for a list param (real Ansible's check_type_list backward compat)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "param-audit-comma-scalar",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "components" => "main,contrib",
      "check_mode" => "true",
    })

    result["repo"].as_s.should contain("Components: main contrib")
  end

  it "space-joins architectures/languages/targets list shapes too" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"          => "param-audit-arch-list",
      "uris"          => "https://example.com/repo",
      "suites"        => "stable",
      "architectures" => "[\"amd64\", \"i386\"]",
      "languages"     => "[\"en\", \"de\"]",
      "targets"       => "[\"deb\"]",
      "check_mode"    => "true",
    })

    result["repo"].as_s.should contain("Architectures: amd64 i386")
    result["repo"].as_s.should contain("Languages: en de")
    result["repo"].as_s.should contain("Targets: deb")
  end

  it "writes bool params as yes/no only when given" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "param-audit-bools",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "trusted"    => "true",
      "enabled"    => "false",
      "pdiffs"     => "yes",
      "check_mode" => "true",
    })

    repo = result["repo"].as_s
    repo.should contain("Trusted: yes")
    repo.should contain("Enabled: no")
    repo.should contain("Pdiffs: yes")
    repo.should_not contain("Allow-Insecure")
    repo.should_not contain("By-Hash")
  end

  it "defaults Types: to deb when types is omitted (real module's own argument_spec default)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "param-audit-types-default",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "check_mode" => "true",
    })

    result["repo"].as_s.should contain("Types: deb")
  end

  it "writes inrelease_path as Inrelease-Path: (real module never pops it from params)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"           => "param-audit-inrelease",
      "uris"           => "https://example.com/repo",
      "suites"         => "stable",
      "inrelease_path" => "stable/InRelease",
      "check_mode"     => "true",
    })

    result["repo"].as_s.should contain("Inrelease-Path: stable/InRelease")
  end

  it "writes the ansible-core 2.21 include: param (Exclude:/: Include: fields)" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "param-audit-include",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "include"    => "[\"goodpkg\"]",
      "check_mode" => "true",
    })

    repo = result["repo"].as_s
    repo.should contain("Include: goodpkg")
    repo.should_not contain("Exclude:")
  end

  it "renders the full field set sorted by the underlying param name, byte-for-byte" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"                        => "param-audit-full",
      "allow_downgrade_to_insecure" => "false",
      "allow_insecure"              => "false",
      "allow_weak"                  => "false",
      "architectures"               => "[\"amd64\", \"i386\"]",
      "by_hash"                     => "true",
      "check_date"                  => "true",
      "check_valid_until"           => "false",
      "components"                  => "[\"main\", \"contrib\"]",
      "date_max_future"             => "86400",
      "enabled"                     => "true",
      "include"                     => "[\"goodpkg\"]",
      "inrelease_path"              => "stable/InRelease",
      "languages"                   => "[\"en\", \"de\"]",
      "pdiffs"                      => "false",
      "signed_by"                   => "ABCD1234EFGH5678ABCD1234EFGH5678ABCD1234",
      "suites"                      => "stable",
      "targets"                     => "[\"deb\"]",
      "trusted"                     => "true",
      "types"                       => "[\"deb\", \"deb-src\"]",
      "uris"                        => "https://example.com/repo",
      "check_mode"                  => "true",
    })

    result["repo"].as_s.should eq(
      "Allow-Downgrade-To-Insecure: no\n" \
      "Allow-Insecure: no\n" \
      "Allow-Weak: no\n" \
      "Architectures: amd64 i386\n" \
      "By-Hash: yes\n" \
      "Check-Date: yes\n" \
      "Check-Valid-Until: no\n" \
      "Components: main contrib\n" \
      "Date-Max-Future: 86400\n" \
      "Enabled: yes\n" \
      "Include: goodpkg\n" \
      "Inrelease-Path: stable/InRelease\n" \
      "Languages: en de\n" \
      "X-Repolib-Name: param-audit-full\n" \
      "Pdiffs: no\n" \
      "Signed-By: ABCD1234EFGH5678ABCD1234EFGH5678ABCD1234\n" \
      "Suites: stable\n" \
      "Targets: deb\n" \
      "Trusted: yes\n" \
      "Types: deb deb-src\n" \
      "URIs: https://example.com/repo\n"
    )
  end

  it "normalizes a name with spaces into the real module's filename slug" do
    result = PluginSpecHelper.run("deb822_repository", {
      "name"       => "Param Audit Slug",
      "uris"       => "https://example.com/repo",
      "suites"     => "stable",
      "check_mode" => "true",
    })

    msg = result["msg"].as_s
    msg.should contain("Param-Audit-Slug.sources")
    msg.should_not contain("Param Audit Slug")
  end
end
