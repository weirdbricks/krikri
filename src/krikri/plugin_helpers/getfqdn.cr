module Krikri
  module PluginHelpers
    # socket.getfqdn() emulation for the hostname plugin's returned facts.
    #
    # The reason this is NOT a `hostname -f` call: Python's
    # socket.getfqdn() forward-resolves the name to an address and then
    # REVERSE-resolves that address, so the answer reflects what NSS
    # (/etc/hosts, DNS) says about the address, not the machine's own
    # view of its name; `hostname -f` is a forward lookup of the queried
    # name and echoes that view back. The two diverge exactly when a role
    # colocates its hostname on the 127.0.0.1 /etc/hosts line
    # (oasis_roles.hostname's pattern, issue #585): real ansible-playbook
    # then reports ansible_fqdn as "localhost"/"localhost.localdomain"
    # and keeps re-reporting changed, while a `hostname -f`-based value
    # stays at the short name and makes krikri falsely idempotent there.
    #
    # `getent` reads the same NSS sources Python's socket module does,
    # without assuming python3 exists on the managed node.
    module Getfqdn
      # socket.getfqdn()'s final step over one `getent hosts <ip>` line
      # ("<ip> <canonical> [alias ...]"): the canonical name is checked
      # first (Python's `aliases.insert(0, hostname)`), then the aliases in
      # order, and the first entry containing a dot wins.
      #
      # When every name on the line is dotless, CPython's `name = hostname`
      # branch returns the reverse lookup's own canonical name - NOT the
      # machine's current hostname: a role can add a line like
      # `127.0.1.1 testhost <machine-name>` whose canonical name ("testhost")
      # is unrelated to the machine name, and ansible-playbook then reports
      # ansible_fqdn = "testhost". A System.hostname fallback instead would
      # report the machine name and keep a later
      # `hostname: name={{ ansible_fqdn }}` task ok where ansible reports
      # changed every run. "" stays reserved for a line with no name field
      # at all (gethostbyaddr failing), which the caller maps to its
      # fallback.
      def self.from_getent_hosts(output : String) : String
        fields = output.split
        return "" if fields.size < 2

        fields[1..].each do |name|
          return name if name.includes?(".")
        end
        fields[1]
      end

      # CPython's socket.getfqdn(name): forward-resolve the name to an
      # address, then reverse-resolve that address and parse the reverse
      # line. When gethostbyaddr fails, CPython returns the queried name
      # itself - that fallback belongs to the caller; "" here only means
      # "no usable resolver answer", so the caller can tell the two cases
      # apart.
      def self.lookup(name : String) : String
        ip = capture("getent", ["ahosts", name]).split("\n").first?.try(&.split.first?)
        return "" if ip.nil? || ip.empty?

        reverse = capture("getent", ["hosts", ip]).split("\n").first?
        return "" unless reverse

        from_getent_hosts(reverse)
      end

      # Run *command* with *args* directly (no shell), capturing stdout
      # only (stderr discarded). Returns "" if the binary can't be found
      # or execution otherwise fails - the same helper shape the hostname
      # and facts plugins use.
      private def self.capture(command : String, args : Array(String) = [] of String) : String
        output = IO::Memory.new
        Process.run(command, args, output: output, error: Process::Redirect::Close)
        output.to_s
      rescue
        ""
      end
    end
  end
end
