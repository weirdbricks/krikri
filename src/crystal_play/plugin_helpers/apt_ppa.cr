module CrystalPlay
  module PluginHelpers
    # AptPpa - pure logic for expanding a `ppa:owner/name` repo: shorthand
    # into a real `deb ...` source line and the Launchpad API/keyfile
    # naming that go with it. No I/O - plugins/apt_repository.cr does the
    # actual HTTP fetch, GPG key export, and file writes.
    #
    # All formulas here verified against real Ansible's own
    # UbuntuSourcesList class source (apt_repository.py), not assumed:
    # the expanded line shape, the Launchpad API URL, and the filename-
    # suggestion input (the *pre-expansion* "ppa:owner/name_codename"
    # string, not the expanded deb line - real Ansible's own
    # `_suggest_filename('%s_%s' % (line, self.codename))` call passes
    # the raw `ppa:` string, which happens to already produce the right
    # shape when run through the exact same generic
    # AptRepositoryLine.suggested_filename transform every other repo:
    # line already goes through - verified by tracing both languages'
    # logic side by side, not by guessing a special case was needed).
    module AptPpa
      PPA_URI = "https://ppa.launchpadcontent.net"
      LP_API  = "https://api.launchpad.net/1.0/~%s/+archive/%s"

      # Real Ansible tries these in order and uses the first that already
      # exists on the target - verified against its own APT_KEY_DIRS
      # constant.
      KEY_DIRS = ["/etc/apt/keyrings", "/etc/apt/trusted.gpg.d", "/usr/share/keyrings"]

      record Info, owner : String, name : String

      # Parses "ppa:owner/name" (name defaults to "ppa" when omitted, e.g.
      # "ppa:owner" alone - matches real Ansible's own `_expand_ppa`
      # default) - nil for anything not starting with "ppa:" or missing
      # an owner.
      def self.parse(repo : String) : Info?
        return nil unless repo.starts_with?("ppa:")

        rest = repo[4..]
        owner, _, name = rest.partition('/')
        return nil if owner.empty?

        Info.new(owner, name.empty? ? "ppa" : name)
      end

      def self.expand_line(info : Info, codename : String) : String
        "deb #{PPA_URI}/#{info.owner}/#{info.name}/ubuntu #{codename} main"
      end

      def self.api_url(info : Info) : String
        LP_API % {info.owner, info.name}
      end

      # The string real Ansible's own `_suggest_filename` is actually
      # called with for a ppa: line - not the expanded deb line (see the
      # class doc above).
      def self.filename_source(info : Info, codename : String) : String
        "ppa:#{info.owner}/#{info.name}_#{codename}"
      end

      # The exact (slightly quirky) keyfile name real Ansible's own
      # add_source builds: `os.path.basename(source)` on the expanded
      # `deb https://.../owner/name/ubuntu codename main` line just takes
      # everything after its last "/" - "ubuntu codename main" - with
      # spaces turned into hyphens, verified by tracing the Python source
      # rather than assumed. keydir is the caller's own choice of
      # KEY_DIRS entry (whichever one actually exists).
      def self.keyfile_name(info : Info, codename : String) : String
        "ubuntu-#{codename}-main-#{info.owner}-#{info.name}.gpg"
      end
    end
  end
end
