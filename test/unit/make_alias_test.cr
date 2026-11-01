require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# make was never in ansible-core, but ansible-core's builtin runtime
# redirects the FQCN spellings onto community.general.make - real
# resolves and runs the module, it never skips (issue #708). The bare
# spelling resolves through MODULE_SEARCH_COLLECTIONS, only the FQCN
# spellings needed MODULE_ALIASES entries.
describe "make alias" do
  {% for spelling in ["make",
                      "ansible.builtin.make",
                      "ansible.legacy.make"] %}
    it "resolves {{ spelling.id }} onto community.general.make" do
      Krikri::PlaybookParser.resolve_module_name({{ spelling }})
        .must_equal("community.general.make")
    end
  {% end %}
end
