module Krikri
  # Python codec names, for modules whose `encoding:` parameter has to
  # behave like Ansible's (replace:, and every file-reading module
  # that forwards the name to a Python `bytes.decode(encoding)`).
  #
  # Real resolves the name in CPython's own codec registry and raises
  # LookupError("unknown encoding: <name>") for a name it does not have -
  # a LookupError replace.py does not catch, so it reaches the user
  # through the module-crash wrapper ("Task failed: Module failed:
  # unknown encoding: 20"), not through fail_json. Deciding that verdict
  # from the host's iconv instead (the pre-2026 fallback: any name
  # Crystal's set_encoding rejects is reported as an unknown encoding)
  # gets it wrong in both directions: iconv does not take Python's
  # "latin-1"/"cp1252"/"us-ascii" spellings at all, so every one of
  # them - and every name Python has but this host's iconv lacks - was
  # reported as an unknown encoding.
  #
  # Both tables are generated from CPython 3.13's own registry (the
  # interpreter ansible-core 2.19.11 runs modules under):
  # `encodings.aliases` plus every codec module, filtered to the ones
  # `bytes.decode()` accepts. Names are compared in the normalized
  # spelling Python itself compares them in (lower-cased, every
  # non-alphanumeric run folded to "_"), so "Latin-1", "latin 1" and
  # "LATIN1" all resolve like Ansible's codecs.lookup().
  module PythonCodecs
    extend self

    ICONV_NAMES = {
      "037" => "cp037", "1026" => "1026", "1125" => "cp1125", "1140" => "cp1140", "1250" => "cp1250", "1251" => "cp1251",
      "1252" => "cp1252", "1253" => "cp1253", "1254" => "cp1254", "1255" => "cp1255", "1256" => "cp1256", "1257" => "cp1257",
      "1258" => "cp1258", "273" => "cp273", "424" => "cp424", "437" => "437", "500" => "500", "646" => "ascii",
      "775" => "cp775", "850" => "850", "852" => "852", "855" => "855", "857" => "857", "858" => "858",
      "860" => "860", "861" => "861", "862" => "862", "863" => "863", "864" => "864", "865" => "865",
      "866" => "866", "869" => "869", "8859" => "iso8859-1", "932" => "cp932", "936" => "gbk", "949" => "cp949",
      "950" => "cp950", "ansi_x3_4_1968" => "ascii", "ansi_x3_4_1986" => "ascii", "arabic" => "arabic",
      "ascii" => "ascii", "asmo_708" => "iso8859-6", "big5" => "big5", "big5_hkscs" => "big5hkscs", "big5_tw" => "big5", "big5hkscs" => "big5hkscs",
      "chinese" => "gb2312", "cp037" => "cp037", "cp1026" => "cp1026", "cp1051" => "hp-roman8", "cp1125" => "cp1125", "cp1140" => "cp1140",
      "cp1250" => "cp1250", "cp1251" => "cp1251", "cp1252" => "cp1252", "cp1253" => "cp1253", "cp1254" => "cp1254", "cp1255" => "cp1255",
      "cp1256" => "cp1256", "cp1257" => "cp1257", "cp1258" => "cp1258", "cp1361" => "cp1361", "cp273" => "cp273", "cp367" => "cp367",
      "cp424" => "cp424", "cp437" => "cp437", "cp500" => "cp500", "cp65001" => "utf-8", "cp737" => "cp737", "cp775" => "cp775",
      "cp819" => "cp819", "cp850" => "cp850", "cp852" => "cp852", "cp855" => "cp855", "cp856" => "cp856", "cp857" => "cp857",
      "cp858" => "cp858", "cp860" => "cp860", "cp861" => "cp861", "cp862" => "cp862", "cp863" => "cp863", "cp864" => "cp864",
      "cp865" => "cp865", "cp866" => "cp866", "cp866u" => "cp1125", "cp869" => "cp869", "cp874" => "cp874", "cp875" => "cp875",
      "cp932" => "cp932", "cp936" => "cp936", "cp949" => "cp949", "cp950" => "cp950", "cp_gr" => "cp869", "cp_is" => "cp861",
      "csascii" => "csascii", "csbig5" => "big5", "csibm037" => "csibm037", "csibm1026" => "csibm1026",
      "csibm273" => "csibm273", "csibm424" => "csibm424", "csibm500" => "csibm500", "csibm855" => "csibm855",
      "csibm857" => "csibm857", "csibm858" => "cp858", "csibm860" => "csibm860", "csibm861" => "cp861",
      "csibm863" => "csibm863", "csibm864" => "csibm864", "csibm865" => "csibm865", "csibm866" => "csibm866",
      "csibm869" => "csibm869", "csiso2022jp" => "csiso2022jp", "csiso2022kr" => "csiso2022kr", "csiso58gb231280" => "gb2312",
      "csisolatin1" => "csisolatin1", "csisolatin2" => "csisolatin2", "csisolatin3" => "csisolatin3", "csisolatin4" => "csisolatin4",
      "csisolatin5" => "csisolatin5", "csisolatin6" => "csisolatin6", "csisolatinarabic" => "csisolatinarabic", "csisolatincyrillic" => "csisolatincyrillic",
      "csisolatingreek" => "csisolatingreek", "csisolatinhebrew" => "csisolatinhebrew", "cskoi8r" => "cskoi8r", "cspc775baltic" => "cspc775baltic",
      "cspc850multilingual" => "cspc850multilingual", "cspc862latinhebrew" => "cspc862latinhebrew", "cspc8codepage437" => "cspc8codepage437", "cspcp852" => "cspcp852",
      "csshiftjis" => "csshiftjis", "cyrillic" => "cyrillic", "ebcdic_cp_be" => "cp500", "ebcdic_cp_ca" => "cp037",
      "ebcdic_cp_ch" => "cp500", "ebcdic_cp_he" => "cp424", "ebcdic_cp_nl" => "cp037", "ebcdic_cp_us" => "cp037",
      "ebcdic_cp_wt" => "cp037", "ecma_114" => "iso8859-6", "ecma_118" => "iso8859-7", "elot_928" => "elot_928",
      "euc_cn" => "gb2312", "euc_jisx0213" => "euc-jisx0213", "euc_jp" => "euc-jp", "euc_kr" => "euc-kr",
      "euccn" => "euccn", "eucgb2312_cn" => "gb2312", "eucjp" => "eucjp", "euckr" => "euckr", "gb18030" => "gb18030", "gb18030_2000" => "gb18030",
      "gb2312" => "gb2312", "gb2312_1980" => "gb2312", "gb2312_80" => "gb2312", "gbk" => "gbk", "greek" => "greek", "greek8" => "greek8",
      "hebrew" => "hebrew", "hkscs" => "big5hkscs", "hp_roman8" => "hp-roman8", "ibm037" => "ibm037",
      "ibm039" => "cp037", "ibm1026" => "ibm1026", "ibm1051" => "hp-roman8", "ibm1125" => "cp1125", "ibm1140" => "ibm1140", "ibm273" => "ibm273",
      "ibm367" => "ibm367", "ibm424" => "ibm424", "ibm437" => "ibm437", "ibm500" => "ibm500", "ibm775" => "ibm775", "ibm819" => "ibm819",
      "ibm850" => "ibm850", "ibm852" => "ibm852", "ibm855" => "ibm855", "ibm857" => "ibm857", "ibm858" => "ibm858", "ibm860" => "ibm860",
      "ibm861" => "ibm861", "ibm862" => "ibm862", "ibm863" => "ibm863", "ibm864" => "ibm864", "ibm865" => "ibm865", "ibm866" => "ibm866",
      "ibm869" => "ibm869", "iso2022_jp" => "iso2022jp", "iso2022_jp_2" => "iso2022jp2", "iso2022_kr" => "iso2022kr",
      "iso2022jp" => "iso2022jp", "iso2022jp_2" => "iso2022jp2", "iso2022kr" => "iso2022kr", "iso646_us" => "ascii",
      "iso8859" => "iso8859-1", "iso8859_1" => "iso8859-1", "iso8859_10" => "iso8859-10", "iso8859_11" => "iso8859-11",
      "iso8859_13" => "iso8859-13", "iso8859_14" => "iso8859-14", "iso8859_15" => "iso8859-15", "iso8859_16" => "iso8859-16",
      "iso8859_2" => "iso8859-2", "iso8859_3" => "iso8859-3", "iso8859_4" => "iso8859-4", "iso8859_5" => "iso8859-5",
      "iso8859_6" => "iso8859-6", "iso8859_7" => "iso8859-7", "iso8859_8" => "iso8859-8", "iso8859_9" => "iso8859-9",
      "iso_2022_jp" => "iso2022jp", "iso_2022_jp_2" => "iso2022jp2", "iso_2022_kr" => "iso2022kr", "iso_646_irv_1991" => "ascii",
      "iso_8859_1" => "iso8859-1", "iso_8859_10" => "iso8859-10", "iso_8859_10_1992" => "iso8859-10", "iso_8859_11" => "iso8859-11",
      "iso_8859_11_2001" => "iso8859-11", "iso_8859_13" => "iso8859-13", "iso_8859_14" => "iso8859-14", "iso_8859_14_1998" => "iso8859-14",
      "iso_8859_15" => "iso8859-15", "iso_8859_16" => "iso8859-16", "iso_8859_16_2001" => "iso8859-16", "iso_8859_1_1987" => "iso8859-1",
      "iso_8859_2" => "iso8859-2", "iso_8859_2_1987" => "iso8859-2", "iso_8859_3" => "iso8859-3", "iso_8859_3_1988" => "iso8859-3",
      "iso_8859_4" => "iso8859-4", "iso_8859_4_1988" => "iso8859-4", "iso_8859_5" => "iso8859-5", "iso_8859_5_1988" => "iso8859-5",
      "iso_8859_6" => "iso8859-6", "iso_8859_6_1987" => "iso8859-6", "iso_8859_7" => "iso8859-7", "iso_8859_7_1987" => "iso8859-7",
      "iso_8859_8" => "iso8859-8", "iso_8859_8_1988" => "iso8859-8", "iso_8859_9" => "iso8859-9", "iso_8859_9_1989" => "iso8859-9",
      "iso_celtic" => "iso8859-14", "iso_ir_100" => "iso8859-1", "iso_ir_101" => "iso8859-2", "iso_ir_109" => "iso8859-3",
      "iso_ir_110" => "iso8859-4", "iso_ir_126" => "iso8859-7", "iso_ir_127" => "iso8859-6", "iso_ir_138" => "iso8859-8",
      "iso_ir_144" => "iso8859-5", "iso_ir_148" => "iso8859-9", "iso_ir_157" => "iso8859-10", "iso_ir_166" => "tis-620",
      "iso_ir_199" => "iso8859-14", "iso_ir_226" => "iso8859-16", "iso_ir_58" => "gb2312", "iso_ir_6" => "ascii",
      "johab" => "johab", "koi8_r" => "koi8-r", "koi8_t" => "koi8-t", "koi8_u" => "koi8-u", "korean" => "euckr", "ks_c_5601" => "euckr",
      "ks_c_5601_1987" => "euckr", "ks_x_1001" => "euckr", "ksc5601" => "euckr", "ksx1001" => "euckr",
      "l1" => "l1", "l10" => "l10", "l2" => "l2", "l3" => "l3", "l4" => "l4", "l5" => "l5", "l6" => "l6", "l7" => "l7",
      "l8" => "l8", "l9" => "iso8859-15", "latin" => "iso8859-1", "latin1" => "latin1", "latin10" => "latin10", "latin2" => "latin2",
      "latin3" => "latin3", "latin4" => "latin4", "latin5" => "latin5", "latin6" => "latin6", "latin7" => "latin7", "latin8" => "latin8",
      "latin9" => "latin9", "latin_1" => "iso8859-1", "mac_cyrillic" => "mac-cyrillic", "maccyrillic" => "maccyrillic",
      "macintosh" => "macintosh", "ms1361" => "johab", "ms932" => "ms932", "ms936" => "ms936", "ms949" => "cp949", "ms950" => "cp950",
      "ms_kanji" => "ms_kanji", "mskanji" => "cp932", "pt154" => "pt154", "r8" => "r8", "rk1048" => "rk1048", "roman8" => "roman8",
      "ruscii" => "ruscii", "s_jis" => "shift_jis", "s_jisx0213" => "shift_jisx0213", "shift_jis" => "shift-jis",
      "shift_jisx0213" => "shift_jisx0213", "shiftjis" => "shift_jis", "shiftjisx0213" => "shiftjisx0213", "sjis" => "sjis",
      "sjisx0213" => "shift_jisx0213", "thai" => "iso8859-11", "tis620" => "tis620", "tis_620" => "tis-620",
      "tis_620_0" => "tis-620", "tis_620_2529_0" => "tis-620", "tis_620_2529_1" => "tis-620", "u7" => "utf-7",
      "u8" => "utf-8", "u_jis" => "eucjp", "uhc" => "uhc", "ujis" => "ujis", "unicode_1_1_utf_7" => "utf-7", "us" => "us",
      "us_ascii" => "ascii", "utf" => "utf-8", "utf7" => "utf7", "utf8" => "utf8", "utf8_ucs2" => "utf-8", "utf8_ucs4" => "utf-8",
      "utf_7" => "utf-7", "utf_8" => "utf-8", "windows_1250" => "cp1250", "windows_1251" => "cp1251",
      "windows_1252" => "cp1252", "windows_1253" => "cp1253", "windows_1254" => "cp1254", "windows_1255" => "cp1255",
      "windows_1256" => "cp1256", "windows_1257" => "cp1257", "windows_1258" => "cp1258", "windows_31j" => "cp932",
      "x_mac_japanese" => "shift_jis", "x_mac_korean" => "euckr", "x_mac_simp_chinese" => "gb2312", "x_mac_trad_chinese" => "big5",
    }

    UNTRANSLATABLE = Set.new(%w[
      charmap cp1006 cp154 cp720 csptcp154 cyrillic_asian euc_jis2004 euc_jis_2004 eucjis2004 eucjisx0213
      hz hz_gb hz_gb_2312 hzgb idna iso2022_jp_1 iso2022_jp_2004 iso2022_jp_3 iso2022_jp_ext iso2022jp_1
      iso2022jp_2004 iso2022jp_3 iso2022jp_ext iso_2022_jp_1 iso_2022_jp_2004 iso_2022_jp_3
      iso_2022_jp_ext jisx0213 kz1048 kz_1048 mac_arabic mac_centeuro mac_croatian mac_farsi mac_greek
      mac_iceland mac_latin2 mac_roman mac_romanian mac_turkish maccentraleurope macgreek maciceland
      maclatin2 macroman macturkish palmos ptcp154 punycode raw_unicode_escape s_jis_2004 shift_jis_2004
      shiftjis2004 sjis_2004 strk1048_2002 unicode_escape utf_8_sig
    ])

    # Whether Python's codecs.lookup() has a codec under this name.
    def known?(name : String) : Bool
      key = normalize(name)
      ICONV_NAMES.has_key?(key) || UNTRANSLATABLE.includes?(key)
    end

    # The spelling this host's iconv converts with, or nil for a codec
    # Python resolves but no iconv here can - callers keep reading and
    # writing the file's bytes verbatim in that case (the substitution
    # itself is byte-preserving, so the round trip still holds).
    def iconv_name(name : String) : String?
      ICONV_NAMES[normalize(name)]?
    end

    # codecs.lookup()'s own normalization (encodings.normalize_encoding):
    # lowercase, then every character that is not an ASCII letter or
    # digit becomes "_".
    private def normalize(name : String) : String
      String.build do |buffer|
        name.downcase.each_char do |char|
          buffer << (char.ascii_alphanumeric? ? char : '_')
        end
      end
    end
  end
end
