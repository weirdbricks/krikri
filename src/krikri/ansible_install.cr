module Krikri
  # Where ansible-core's package WOULD be installed on this host, spelled
  # the way ansible's own tracebacks spell it. Those frames embed the install
  # path, and a counterfeited traceback has to name a path; krikri never
  # READS an installation to derive it (that would make its output depend on
  # what the controller has installed - see KNOWN_MISSING.md's "krikri never
  # consults an installed ansible-core or collections tree"). The path comes
  # from this interpreter's own sysconfig, the same answer `pip install
  # ansible-core` would have targeted, and the Python version that decides
  # whether the traceback carries PEP 657 caret lines (Python 3.13 suppresses
  # them for a frame whose failing instruction is a plain call statement,
  # while 3.11/3.12 print one under every frame - live-verified vs
  # ansible-core 2.21.6 on Python 3.12.16 and 3.13.5 for issue #1540's
  # `serial:` crash).
  module AnsibleInstall
    # The install path the first counterfeited tracebacks were captured
    # from (the kpg podman image's debian:trixie-slim). Only used when no
    # Python interpreter can be found - a controller with none has no other
    # answer to give.
    CAPTURED_PACKAGE = "/usr/local/lib/python3.13/dist-packages/ansible"

    @@package_path : String?
    @@python_minor : Int32?

    # The `ansible` package directory (`.../site-packages/ansible`).
    def self.package_path : String
      @@package_path ||= purelib_package_path || CAPTURED_PACKAGE
    end

    # Minor version of the Python that owns that directory, read off the
    # path (`.../python3.12/...` -> 12). An unversioned distro directory
    # (`/usr/lib/python3/dist-packages`) leaves the interpreter unknown, and
    # 3.13 is assumed: it is what current distros ship, and it prints the
    # fewer caret lines, so an unknown host never gets extra output it might
    # not have.
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

    # Where a root `pip install ansible-core` would have put the package:
    # this interpreter's sysconfig purelib. Pure path computation - it
    # imports nothing from ansible and touches no installed package, so the
    # answer is the same on a controller that has ansible-core and one that
    # has never seen it.
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
  end
end
