module Krikri
  module PluginHelpers
    # MultiextSplit - the staged-filename split Ansible's fetch_file
    # (ansible/module_utils/urls.py) applies to a URL basename before
    # handing it to tempfile.NamedTemporaryFile:
    # `prefix, ext = _split_multiext(os.path.basename(urlparse(url).path), count=2)`
    # - the last two suffix components of 3-4 chars each become the
    # tempfile's suffix, so helm-v3.3.0-linux-amd64.tar.gz stages as
    # helm-v3.3.0-linux-amd64<rand8>.tar.gz. os.path.splitext would keep
    # ".tar" in the prefix instead, and unarchive echoes the staged path
    # back as `src` (verified against ansible-core 2.19.11), so the
    # difference is visible in task output. Pure string logic, no I/O -
    # own file so a spec can require it directly without triggering
    # plugins/unarchive.cr's STDIN entry point (same shape as
    # SystemdCliFlags).
    module MultiextSplit
      def self.split(name : String) : {String, String}
        suffixes = name.ends_with?('.') ? [] of String : name.lstrip('.').split('.')[1..].map { |part| ".#{part}" }
        extension = ""
        stem = name
        suffixes.reverse.each_with_index do |sfx, i|
          break if i >= 2
          break unless sfx.size >= 3 && sfx.size <= 4
          extension = sfx + extension
          # Python's rstrip treats its argument as a CHARACTER SET, not a
          # literal suffix - Crystal's rstrip(String) has the same
          # semantics, which matters for names whose stem ends in
          # suffix-like characters (data.tar.gz -> "d", ".tar.gz").
          stem = stem.rstrip(sfx)
        end
        {stem, extension}
      end
    end
  end
end
