require "../minitest_helper"
require "../../src/krikri/variable_substitutor"

describe "PlusMinusOperandError#template_text" do
  # The five operand-type shapes real ansible-core 2.19.11 reports for a
  # TypeError from `+`/`-` inside a template (live-verified): each gets
  # its "Error rendering template: " prefix, while a genuinely undefined
  # NAME stays bare.
  OPERAND_TYPE_MESSAGES = [
    "unsupported operand type(s) for +: 'NoneType' and 'str'",
    "unsupported operand type(s) for -: 'NoneType' and 'int'",
    "can only concatenate str (not \"NoneType\") to str",
    "can only concatenate list (not \"str\") to list",
    "bad operand type for unary -: 'NoneType'",
  ]

  it "prefixes operand-type failure messages with Error rendering template" do
    OPERAND_TYPE_MESSAGES.each do |msg|
      err = Krikri::PlusMinusOperandError.new(msg)
      err.template_text.must_equal("Error rendering template: #{msg}")
    end
  end

  it "reports operand_type_failure? true only for operand-type messages" do
    OPERAND_TYPE_MESSAGES.each do |msg|
      err = Krikri::PlusMinusOperandError.new(msg)
      err.operand_type_failure?.must_equal(true)
    end
  end

  it "leaves an undefined-name message bare" do
    err = Krikri::PlusMinusOperandError.new("'undef_v' is undefined")
    err.template_text.must_equal("'undef_v' is undefined")
    err.operand_type_failure?.must_equal(false)
  end
end
