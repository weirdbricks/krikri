# Ansible's controller-side local temp directory - DEFAULT_LOCAL_TMP.
#
# ansible's config manager creates it once per process as
# tempfile.mkdtemp(prefix='ansible-local-%s' % os.getpid(), dir=~/.ansible/tmp)
# (config/manager.py), so the name is `ansible-local-<pid><8 random
# [a-z0-9_]>`; every tempfile.mkstemp/mkdtemp call made inside it appends a
# bare `tmp` + 8 random characters component.
#
# krikri never stages anything there for a local connection - it hands the
# content to the module directly - but the path leaks into output real
# Ansible prints (the controller-side template and assemble diff
# after-headers, the same reason template_action_plugin used to grow its own
# copy of this), so it has to be synthesized with the same SHAPE. Only the
# shape is observable: the random parts can never match across runs.
module Krikri
  module LocalTmp
    extend self

    # tempfile._RandomNameSequence.characters - what Python's tempfile
    # draws its 8-character name tail from.
    SUFFIX_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_"

    def suffix : String
      String.build(8) { |io| 8.times { io << SUFFIX_CHARS[Random::Secure.rand(SUFFIX_CHARS.size)] } }
    end

    # ~/.ansible/tmp/ansible-local-<pid><random>
    def root : String
      File.join(Path.home.to_s, ".ansible", "tmp", "ansible-local-#{Process.pid}#{suffix}")
    end

    # tempfile.mkstemp(dir=DEFAULT_LOCAL_TMP) with no prefix/suffix:
    # `<root>/tmp<random>`, a file.
    def staged_file : String
      File.join(root, "tmp#{suffix}")
    end

    # tempfile.mkdtemp(dir=DEFAULT_LOCAL_TMP): `<root>/tmp<random>`, a
    # directory (the template action writes its rendered file one level
    # below it).
    def staged_dir : String
      File.join(root, "tmp#{suffix}")
    end
  end
end
