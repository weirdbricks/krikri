module Krikri
  module PluginHelpers
    # Deb822RepositoryContent - pure logic for rendering a deb822_
    # repository:'s `.sources` file content. No I/O here - the plugin
    # itself handles file writing/signed_by fetching.
    #
    # Field ORDER is real ansible.builtin.deb822_repository's own
    # `for key, value in sorted(params.items())` - alphabetical by the
    # underlying PYTHON PARAM NAME, not by DEB822 field name and not any
    # fixed/declared order - verified directly against a real
    # `ansible-playbook -vvv` run's own `repo:` return value, not
    # assumed from source alone. This matters for idempotency: a file
    # real Ansible itself wrote and a file this plugin writes must line
    # up byte-for-byte, or a warm rerun against an already-real-Ansible-
    # managed file would spuriously report changed on line-order alone.
    module Deb822RepositoryContent
      # *fields* is {param_name => rendered_line}, already formatted by
      # the caller (bool -> "yes"/"no", lists space-joined, etc) - this
      # just handles the sort-by-param-name + join.
      def self.render(fields : Hash(String, String)) : String
        fields.to_a.sort_by(&.first).map(&.last).join('\n') + '\n'
      end
    end
  end
end
