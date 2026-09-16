require "../spec_helper"
require "../../src/krikri/task_executor/result_display"

# Pins Krikri::result_failed_flag against real ansible-core's async
# fire-and-forget launch result, which puts INTEGER 0 (not false) in the
# "failed" key - Python truthiness makes that falsy, but a hard
# JSON::Any#as_bool cast crashes the executor on it. Confirmed via the
# podman-diff async_status cases (D3/D8).
describe "Krikri.result_failed_flag" do
  it "reads a JSON bool verbatim" do
    Krikri.result_failed_flag(JSON.parse(%({"failed": true}))).should be_true
    Krikri.result_failed_flag(JSON.parse(%({"failed": false}))).should be_false
  end

  it "treats integer 0/1 the way Python truthiness does" do
    Krikri.result_failed_flag(JSON.parse(%({"failed": 0}))).should be_false
    Krikri.result_failed_flag(JSON.parse(%({"failed": 1}))).should be_true
  end

  it "absent or non-boolean-non-int values mean not failed" do
    Krikri.result_failed_flag(JSON.parse(%({}))).should be_false
    Krikri.result_failed_flag(JSON.parse(%({"failed": null}))).should be_false
    Krikri.result_failed_flag(JSON.parse(%({"failed": "0"}))).should be_false
  end
end
