require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# snap left ansible-core for community.general years ago, but
# ansible-core's builtin runtime still redirects the FQCN spellings onto
# community.general.snap - real resolves and runs the module (failing on
# a missing snap CLI), it never skips. pitabwire.ansible_role_microceph
# (round 1791896374) writes `ansible.builtin.snap:`; the bare spelling
# resolves through MODULE_SEARCH_COLLECTIONS, only the FQCN spellings
# needed MODULE_ALIASES entries.
describe "snap alias" do
  {% for spelling in ["snap",
                      "ansible.builtin.snap",
                      "ansible.legacy.snap"] %}
    it "resolves {{spelling.id}} onto community.general.snap" do
      Krikri::PlaybookParser.resolve_module_name({{spelling}})
        .must_equal("community.general.snap")
    end
  {% end %}
end
