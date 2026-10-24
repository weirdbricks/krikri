# Pure helpers for TaskExecutor#stage_script_src's remote staging: the
# per-task tmp dir shape and the remote one-shot mkdir+confirm script.
#
# Real ansible's script action plugin (2.19.11, issue #298) stages the
# transferred file via self._connection._shell.join_path(shell.tmpdir,
# basename) where shell.tmpdir is the shell plugin's mkdtemp dir:
# '<remote_tmp>/ansible-tmp-<time.time()>-<pid>-<rand48>' with
# remote_tmp defaulting to ~/.ansible/tmp, expanded ON THE REMOTE side
# (the generated one-shot script does `mkdir -p $(echo <remote_tmp>)` -
# the tilde only survives the trip unexpanded, so the command echoes the
# resolved absolute path back). Live-verified path shape:
# /root/.ansible/tmp/ansible-tmp-1792822794.6691642-3684055-8664083885542.
#
# The name rides the role-tester's ANSIBLE_REMOTE_TMP mask
# (/.ansible/tmp/ansible-tmp-[\d.\-]+...), so the timestamp/pid digits
# don't need ansible-exact fidelity - the sha-ish dir name shape does,
# and a krikri nightly `/tmp/.krikri-playbook-script-*` staging path did
# not (it never either matched the mask or got removed the same way).
module Krikri
  module PluginHelpers
    module ScriptRemoteStaging
      # 'ansible-tmp-%s-%s-%s' % (time.time(), os.getpid(), secrets.randbelow(2**48))
      # - all resolved controller-side, like the real shell plugin's
      # _generate_temp_dir_name (Python's randbelow is [0, n), so 64-bit
      # here unclipped). The fractional seconds keep a fixed 6 digits
      # (Python repr's vary; both satisfy the mask).
      def self.tmp_dir_name : String
        now = Time.utc
        "ansible-tmp-#{now.to_unix}.#{now.nanosecond // 1000}-#{Process.pid}-#{Random::Secure.rand(1_u64 << 48)}"
      end

      # The one ssh-script round trip real ansible's shell plugin builds
      # for a non-system tmpdir, mirroring its mkdtemp shape: a
      # `umask 077` subshell so BOTH the `mkdir -p` parents (e.g.
      # ~/.ansible, ~/.ansible/tmp) and the per-task dir itself come out
      # mode 0700 (real does exactly this umask trick, no separate
      # chmod), then `echo KRIKRI-TMPDIR=$(...)` - the echo resolves the
      # tilde LAUNCHES-NO-QUOTES the way the $() word expansion does,
      # and its answer is what the caller hands onward as the absolute
      # path (scp and the plugin both need the resolved path, not a tilde
      # spelled one). remote_tmp is embedded verbatim inside $(echo ...)
      # the same way real embeds basetmpdir there - a value with spaces
      # or metacharacters breaks identically upstream; not re-invented
      # here.
      def self.mkdir_script(tmp_base : String, dir_name : String) : String
        dir = "#{tmp_base}/#{dir_name}"
        String.build do |io|
          io << "{ umask 077 && mkdir -p $(echo " << tmp_base << ") && mkdir $(echo " << dir << ")"
          io << " && echo KRIKRI-TMPDIR=$(echo " << dir << "); }"
        end
      end

      # Fishes the `echo KRIKRI-TMPDIR=<abs-path>` answer out of the
      # mkdir script's stdout. nil when the round trip didn't say a dir
      # name (non-zero exit, unpredictable text, nothing echoed) - the
      # caller then falls back to the pre-existing /tmp staging.
      def self.parsed_tmpdir(stdout : String) : String?
        line = stdout.lines.find { |entry| entry.starts_with?("KRIKRI-TMPDIR=") } || return nil
        dir = line.lchop("KRIKRI-TMPDIR=").strip
        return nil if dir.empty? || !dir.starts_with?('/')
        dir
      end
    end
  end
end
