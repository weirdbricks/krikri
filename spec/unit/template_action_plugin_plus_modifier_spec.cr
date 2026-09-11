require "../spec_helper"
require "file_utils"
require "../../src/krikri/host"
require "../../src/krikri/template_action_plugin"

# Regression: gzevd.docuum's docuum.service.j2 uses `{%+ if ... +%}`
# around its optional service directives. A previous renderer workaround
# pre-stripped the `+` markers (`{%+`/`+%}` -> `{%`/`%}`) because Crinja
# 0.9.0 couldn't parse them at all; with trim_blocks on (the default
# here) that ate the newline the `+%}` was there to preserve, rendering
# `ExecStart=... StandardOutput=syslog` on ONE line - systemd then fed
# "StandardOutput=syslog" to docuum as a CLI argument, the service
# exited instantly and crash-looped into the start-limit `failed` state,
# and the WARM rerun's `systemd: state=started` failed outright while
# real Ansible reported ok. The vendored Crinja fork now parses `+`
# natively, so the workaround is strictly a regression - this spec pins
# the full plugin path (template: action, real file, trim_blocks on) to
# the correct newline-preserving behavior.
describe Krikri::TemplateActionPlugin do
  it "renders a `{%+ if ... +%}` template keeping the newlines" do
    tmp = File.tempname("plus-modifier", ".j2")
    File.write(tmp, "ExecStart=/usr/bin/docuum {%+ if true +%}\n" \
                    "StandardOutput=syslog\n" \
                    "{%+ endif +%}\n" \
                    "Restart=on-failure")

    plugin = Krikri::TemplateActionPlugin.new(
      {"src" => tmp, "dest" => "/tmp/plus-modifier-test"} of String => String,
      {} of String => JSON::Any,
      Krikri::Host.new("testhost")
    )
    result = plugin.execute

    result.success?.should be_true
    # The plugin appends a trailing newline to rendered content (real
    # Ansible's template output always ends with one) - hence the final \n.
    result.modified_params.not_nil!["content"].should eq(
      "ExecStart=/usr/bin/docuum \nStandardOutput=syslog\n\nRestart=on-failure\n"
    )
  ensure
    File.delete(tmp) if tmp && File.exists?(tmp)
  end
end
