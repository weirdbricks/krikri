require "./playbook_parser"

module Krikri
  # `serial:` batch token that isn't an integer. Real ansible-playbook dies
  # on it: PlaybookExecutor._get_serialized_batches runs
  # helpers.pct_to_int over each token right before the play starts, and
  # int() raises an uncaught ValueError, so the run prints "[ERROR]:
  # Unexpected Exception, this is probably a bug: invalid literal for
  # int() with base 10: '<value>'" plus BOTH Python tracebacks on STDERR
  # and exits 250 with NO PLAY banner for that play (earlier plays' output
  # is already on stdout) - live-verified vs 2.21.6, issue #1446 (kpg's
  # `serial: kpg-many`, found last: it made the chaos diff look like an
  # apt_repository one). The frames are fixed for the release, so the
  # crash is counterfeited verbatim.
  class SerialValueError < Exception
    getter render : String

    def initialize(render : String)
      @render = render
      super(render.lines[0])
    end
  end

  # `serial:` - Ansible runs the WHOLE play against one batch of
  # hosts at a time instead of every host at once, which is what makes a
  # rolling restart rolling. This engine previously ignored the keyword
  # entirely, so `serial: 1` still hit every host simultaneously.
  module SerialBatches
    # `order:` - how hosts are sequenced before serial: batches them.
    # Verified against ansible-core 2.19.4 over an inventory listing
    # h3, h1, h2: inventory keeps that order, sorted gives h1 h2 h3,
    # reverse_sorted h3 h2 h1, and reverse_inventory h2 h1 h3 (the
    # inventory order reversed, NOT a sort).
    def self.order(hosts : Array(Host), order : String?) : Array(Host)
      case order
      when nil, "", "inventory" then hosts
      when "reverse_inventory"  then hosts.reverse
      when "sorted"             then hosts.sort_by(&.name)
      when "reverse_sorted"     then hosts.sort_by(&.name).reverse!
      when "shuffle"            then hosts.shuffle
      else                           hosts
      end
    end

    # Splits *hosts* according to the play's serial tokens. Each token is
    # either a count ("2") or a percentage of the TOTAL host count
    # ("50%", rounded up); the last token sizes every remaining batch.
    # Verified against ansible-core 2.19.4 for `1`, `2`, `"50%"` and
    # `[1, 2]` over four hosts.
    #
    # Like real's own loop, only the tokens actually reached are
    # converted: `serial: [4, bad]` over four hosts never looks at the
    # second entry (its first batch takes every host), so it does not
    # crash there either (live-verified vs 2.21.6).
    def self.split(hosts : Array(Host), serial : Array(String)) : Array(Array(Host))
      return [hosts] if serial.empty? || hosts.empty?

      total = hosts.size
      batches = [] of Array(Host)
      index = 0
      token_index = 0

      while index < total
        token = serial[token_index]? || serial.last
        size = batch_size(token, total)
        batches << hosts[index, size]
        index += size
        token_index += 1
      end

      batches
    end

    private def self.batch_size(token : String, total : Int32) : Int32
      size =
        if template_token?(token)
          # A token that is still a template is text this engine's
          # play-keyword handling never resolves (`serial: "{{ n }}"`
          # arrives verbatim, exactly like order:/strategy:), while real
          # post_validates it into an integer before batching. Keep the
          # long-standing one-batch fallback for those: crashing the whole
          # run on text real would never reach int() would be worse than
          # the batch-size difference that already exists there.
          total
        elsif token.ends_with?('%')
          # pct_to_int's percentage branch runs int() over the text with
          # EVERY '%' replaced, not just the trailing one: `serial: "50%%"`
          # is int("50") and batches by 50% while `"4x%%"` crashes on
          # int("4x"). A fractional percentage raises there too
          # (live-verified vs 2.21.6).
          percent_text = token.gsub('%', "")
          percent = percent_text.to_i? || raise SerialValueError.new(crash_render(percent_text, percent: true))
          (total * percent / 100.0).ceil.to_i
        else
          # pct_to_int's plain branch is int(value): a YAML float/bool
          # literal is int-able (int(2.5) is 2, int(True) is 1) and was
          # already reduced to that integer by the parser, so anything
          # still non-numeric here is a string real crashes on.
          token.to_i? || raise SerialValueError.new(crash_render(token, percent: false))
        end

      # A zero or negative batch would loop forever; Ansible treats
      # anything under one host per batch as one.
      size < 1 ? 1 : size
    end

    private def self.template_token?(token : String) : Bool
      token.includes?("{{") || token.includes?("{%")
    end

    # The stderr block real ansible-playbook prints for an unconvertible
    # serial token (rc=250, no recap). Verification is issue #1446's; the
    # install path and the tilde/caret runs are the kpg podman image's
    # (debian:trixie-slim, pip-installed ansible-core 2.21.6, Python
    # 3.13's PEP 657 anchors), captured per line.
    private def self.crash_render(value : String, percent : Bool) : String
      pkg = "/usr/local/lib/python3.13/dist-packages/ansible"
      event = "Unexpected Exception, this is probably a bug: invalid literal for int() with base 10: '#{value}'"
      failing_frame = if percent
                        "  File \"#{pkg}/utils/helpers.py\", line 29, in pct_to_int\n" \
                        "    value_pct = int(value.replace(\"%\", \"\"))\n"
                      else
                        "  File \"#{pkg}/utils/helpers.py\", line 32, in pct_to_int\n" \
                        "    return int(value)\n"
                      end
      String.build do |io|
        io << "[ERROR]: " << event << "\n\n"
        io << "Traceback (most recent call last):\n"
        io << "  File \"#{pkg}/cli/__init__.py\", line 663, in cli_executor\n"
        io << "    exit_code = cli.run()\n"
        io << "  File \"#{pkg}/cli/playbook.py\", line 152, in run\n"
        io << "    results = pbex.run()\n"
        io << "  File \"#{pkg}/executor/playbook_executor.py\", line 170, in run\n"
        io << "    batches = self._get_serialized_batches(play)\n"
        io << "  File \"#{pkg}/executor/playbook_executor.py\", line 281, in _get_serialized_batches\n"
        io << "    serial = pct_to_int(serial_batch_list[cur_item], all_hosts_len)\n"
        io << failing_frame
        io << "ValueError: invalid literal for int() with base 10: '#{value}'\n\n"
        io << "The above exception was the direct cause of the following exception:\n\n"
        io << "Traceback (most recent call last):\n"
        io << "  File \"#{pkg}/cli/__init__.py\", line 672, in cli_executor\n"
        io << "    raise AnsibleError(\"Unexpected Exception, this is probably a bug.\") from ex\n"
        io << "ansible.errors.AnsibleError: " << event << "\n\n"
      end
    end
  end
end
