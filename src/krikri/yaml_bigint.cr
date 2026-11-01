# PyYAML (and therefore ansible) resolves an unquoted YAML integer
# scalar into a Python int, which is arbitrary precision - a literal
# like `123456789012345678901234567890` keeps all its digits and prints
# back exactly as written. Crystal's YAML core schema resolves the same
# scalar through Int64 first and falls through to Float64 on overflow,
# so the value prints as `1.2345678901234568e+29` and stops answering
# `is integer` - a divergence real roles hit whenever a playbook writes
# a wide unquoted literal (IDs, nonces, large counts). The same fall-
# through leaves hex (`0x1234567890abcdef1234`) and wide octal scalars
# as plain strings where PyYAML yields an int.
#
# This file reopens YAML::Schema::Core and, when the Int64 parse
# overflows on a literal that is unambiguously an integer, hands back
# Krikri's bigint sentinel string instead (see param_sentinels.cr).
# The sentinel is a String, so YAML::Any, the vault/yaml_value_to_json
# converters and every downstream consumer carry it through unchanged,
# while the engine side turns it into a real bigint value.
require "big"

require "./param_sentinels"

module YAML::Schema::Core
  # Same untyped signature as the stdlib definition it replaces: try the
  # Int64 parse first, then - only for a pure decimal integer literal
  # (underscores allowed, as PyYAML's int resolver allows) that overflowed
  # - the exact decimal digits, instead of letting it fall to Float64 and
  # lose digits. Leading-zero forms stay out of this branch: `0123` /
  # `-0123` are octal in YAML 1.1 and belong to the octal handling.
  private def self.parse_number?(string)
    if int = parse_int?(string)
      return int
    end
    if string.matches?(/\A[-+]?\d[\d_]*\z/) && !string.matches?(/\A[-+]?0\d/)
      digits = string.delete('_')
      digits = digits[1..] if digits.starts_with?('+')
      return Krikri.bigint_sentinel(digits)
    end
    parse_float?(string)
  end

  # Same untyped signature and body shape as the stdlib definition it
  # replaces (PullParser and Nodes::Scalar variants both delegate here,
  # and only plain-style scalars reach it, so quoted strings are
  # untouched): the two overflow branches fall back to a BigInt convert
  # for literals PyYAML would still call ints.
  def self.parse_scalar(string : String) : Nil | Bool | Int64 | Float64 | String | Time | Bytes
    if parse_null?(string)
      return nil
    end

    value = parse_bool?(string)
    return value unless value.nil?

    value = parse_float_infinity_and_nan?(string)
    return value if value

    parse_prefixed_scalar(string)
  end

  # Prefixes that either parse to a number or are strings otherwise.
  private def self.parse_prefixed_scalar(string : String) : Nil | Bool | Int64 | Float64 | String | Time | Bytes
    case string
    when /\A[-+]?0x/
      parse_hex_scalar(string)
    when .starts_with?("0."), .starts_with?('.')
      parse_float?(string) || string
    when .starts_with?('0')
      parse_octal_scalar(string)
    when .starts_with?('-'), .starts_with?('+')
      parse_number?(string) || string
    else
      parse_plain_scalar(string)
    end
  end

  private def self.parse_hex_scalar(string : String)
    value = string.to_i64?(base: 16, prefix: true)
    return value if value
    parse_big_base_literal?(string, 16, /\A[-+]?0[xX][0-9a-fA-F_]+\z/, 2)
  end

  private def self.parse_octal_scalar(string : String)
    return 0_i64 if string.size == 1
    value = string.to_i64?(base: 8, prefix: true, leading_zero_is_octal: true)
    return value if value
    parse_big_base_literal?(string, 8, /\A0[0-7_]+\z/, 1)
  end

  private def self.parse_plain_scalar(string : String)
    if string[0].ascii_number?
      value = parse_number?(string)
      return value if value

      value = parse_time?(string)
      return value if value
    end

    string
  end

  # Wide hex/octal fallback: when the literal is syntactically a valid
  # base-N integer (PyYAML's int resolver accepts underscores in these
  # forms too), convert through BigInt and hand back the decimal digits
  # as a sentinel string; anything else stays the plain string the
  # stdlib would have returned.
  private def self.parse_big_base_literal?(string, base : Int32, valid : Regex, prefix_size : Int32) : String
    return string unless valid.matches?(string)

    magnitude = string.delete('_')
    negative = magnitude.starts_with?('-')
    magnitude = magnitude[1..] if negative || magnitude.starts_with?('+')
    magnitude = magnitude[prefix_size..]
    value = BigInt.new(magnitude, base)
    value = -value if negative
    Krikri.bigint_sentinel(value.to_s)
  end
end
