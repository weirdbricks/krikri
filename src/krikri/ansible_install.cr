module Krikri
  # Where ansible-core is installed on this host, spelled the way
  # ansible's own tracebacks spell it. Those frames embed the install
  # path, which moves with the way ansible-core was installed -
  # `pip install --user` lands in ~/.local/lib/python3.X/site-packages, a
  # root pip install in this interpreter's sysconfig purelib
  # (/usr/local/lib/python3.X/{site,dist}-packages, the leaf depending on
  # the distro) - and whose Python version decides whether the traceback
  # carries PEP 657 caret lines: Python 3.13 suppresses them for a frame
  # whose failing instruction is a plain call statement, while 3.11/3.12
  # print one under every frame (live-verified vs ansible-core 2.21.6 on
  # Python 3.12.16 and 3.13.5 for issue #1540's `serial:` crash).
  module AnsibleInstall
    # The install path the first counterfeited tracebacks were captured
    # from (the kpg podman image's debian:trixie-slim). Only used when
    # neither an ansible-core package nor a Python interpreter can be
    # found - a controller with neither has no other answer to give.
    CAPTURED_PACKAGE = "/usr/local/lib/python3.13/dist-packages/ansible"

    @@package_path : String?
    @@python_minor : Int32?

    # The `ansible` package directory (`.../site-packages/ansible`).
    def self.package_path : String
      @@package_path ||= discover_package_path || purelib_package_path || CAPTURED_PACKAGE
    end

    # Minor version of the Python running that install, read off its
    # package directory (`.../python3.12/...` -> 12). An unversioned
    # distro directory (`/usr/lib/python3/dist-packages`) leaves the
    # interpreter unknown, and 3.13 is assumed: it is what current
    # distros ship, and it prints the fewer caret lines, so an unknown
    # host never gets extra output it might not have.
    def self.python_minor : Int32
      @@python_minor ||= begin
        if match = package_path.match(%r{/python3\.(\d+)/})
          match[1].to_i
        else
          13
        end
      end
    end

    def self.caret_lines? : Bool
      python_minor < 13
    end

    private def self.discover_package_path : String?
      package_bases.each do |base|
        candidate = File.join(base, "ansible")
        return candidate if File.file?(File.join(candidate, "utils", "helpers.py"))
      end
      nil
    end

    # Where a root `pip install ansible-core` would have put the package:
    # this interpreter's sysconfig purelib. A host with no ansible-core
    # package of its own still has to name the path the reference engine
    # on the same distro reports - the kpg harness runs krikri in a
    # container that carries the distro's python3 but not the
    # pip-installed ansible-core its reference container has.
    private def self.purelib_package_path : String?
      return nil unless purelib = python_purelib
      return nil unless purelib.includes?("/python3")
      File.join(purelib, "ansible")
    end

    private def self.python_purelib : String?
      output = IO::Memory.new
      status = Process.run("python3",
        ["-c", "import sysconfig; print(sysconfig.get_paths()['purelib'])"],
        output: output, error: Process::Redirect::Close)
      return nil unless status.success?
      purelib = output.to_s.strip
      purelib.empty? ? nil : purelib
    rescue
      nil
    end

    # The package directories the `ansible-playbook` on PATH would import
    # from, in that interpreter's own sys.path order: a virtualenv named
    # by the shebang first (its site-packages shadows nothing else), then
    # pip's per-user tree, then a root pip install. The distro package
    # directory (/usr/lib/python3/dist-packages) is deliberately absent:
    # distros ship an ansible-core older than the one this engine
    # counterfeits (kpg's reference containers install 2.21.6 with pip
    # over the distro package), so its frames' paths are the pip one's
    # even where only the distro copy is present. Globbing `python3*`
    # rather than pinning a point release keeps every pip tree reachable
    # without knowing the interpreter's minor version.
    private def self.package_bases : Array(String)
      bases = [] of String
      if bin_dir = shebang_bin_dir
        Dir.glob("#{File.dirname(bin_dir)}/lib/python3*/site-packages").each do |candidate|
          bases << candidate if Dir.exists?(candidate)
        end
      end
      if home = ENV["HOME"]?
        Dir.glob("#{home}/.local/lib/python3*/site-packages").each do |candidate|
          bases << candidate if Dir.exists?(candidate)
        end
      end
      ["/usr/local/lib", "/opt"].each do |prefix|
        Dir.glob("#{prefix}/python3*").each do |pydir|
          ["site-packages", "dist-packages"].each do |leaf|
            candidate = File.join(pydir, leaf)
            bases << candidate if Dir.exists?(candidate)
          end
        end
      end
      bases.uniq
    end

    # The directory holding the interpreter of the `ansible-playbook` on
    # PATH (e.g. /opt/venv/bin for `#!/opt/venv/bin/python3`), or nil when
    # PATH holds none whose shebang names a Python interpreter.
    private def self.shebang_bin_dir : String?
      return nil unless path = ENV["PATH"]?
      path.split(':').each do |dir|
        next if dir.empty?
        candidate = File.join(dir, "ansible-playbook")
        next unless File.file?(candidate) && File::Info.executable?(candidate)
        begin
          first = File.open(candidate, &.read_line)
        rescue
          next
        end
        next unless first.starts_with?("#!") && first.includes?("python")
        return File.dirname(first.lchop("#!").strip)
      end
      nil
    end
  end
end
