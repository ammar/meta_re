require "test/unit"
require File.expand_path("../../lib/meta_re.rb", __FILE__)

class TestMetaRegexp < Test::Unit::TestCase

  # Basic parse and compile
  # --------------------------------------------------------------------------

  def test_parse_passes_escaped_characters_as_is
    re = MetaRegexp.new('must \+ \(pass\)\(them\) \.\s+ \(thru\)')
    assert_equal('must \+ \(pass\)\(them\) \.\s+ \(thru\)', re.source)
  end

  def test_parse_passes_non_quantified_groups_as_is
    re = MetaRegexp.new(/(groups) (without) (quantifiers)/)
    assert_equal('(?-mix:(groups) (without) (quantifiers))', re.source)
  end

  # ?: pass thru
  def test_parse_passes_optional_groups_as_is
    re = MetaRegexp.new(/ruby (has)? many (gems)?/)
    assert_equal('(?-mix:ruby (has)? many (gems)?)', re.source)
  end

  # *: default 'more' count
  def test_parse_star_quantifier
    re = MetaRegexp.new(/does (this)* work/mi)
    assert_equal('(?mi-x:does (this)?(this)?(this)?(this)?(this)?(this)?' +
                 '(this)?(this)?(this)?(this)?(this)?(this)? work)',
                 re.source)
  end

  # *: override 'more' count
  def test_parse_star_quantifier_with_max_more
    re = MetaRegexp.new(/does (this)* work/mi, 2)
    assert_equal('(?mi-x:does (this)?(this)? work)', re.source)
  end

  # +: default 'more' count
  def test_parse_plus_quantifier
    re = MetaRegexp.new(/does (this)+ work/xi)
    assert_equal('(?ix-m:does (this)(this)?(this)?(this)?(this)?(this)?' +
                 '(this)?(this)?(this)?(this)?(this)?(this)? work)', re.source)
  end

  # +: override 'more' count
  def test_parse_plus_quantifier_with_more_max
    re = MetaRegexp.new(/does (this)+ work/i, 2)
    assert_equal('(?i-mx:does (this)(this)? work)', re.source)
  end

  # {m,M}: min and max
  def test_parse_full_range_quantifier
    re = MetaRegexp.new(/read (again(, and)?){1,4}/)
    ts = "read again, and again, and again, and again"

    assert_equal('(?-mix:read (again(, and)?)(again(, and)?)?' +
                 '(again(, and)?)?(again(, and)?)?)', re.source)
  end

  # {N}: exact count repetition
  def test_parse_exact_count_quantifier
    re = MetaRegexp.new(/read (again(, and)?){4}/)
    ts = "read again, and again, and again, and again"

    assert_equal('(?-mix:read (again(, and)?)(again(, and)?)' +
                 '(again(, and)?)(again(, and)?))', re.source)
  end

  # {,M}: max only (min = 0)
  def test_parse_maximum_only_quantifier
    re = MetaRegexp.new('read (again(, and)?){,4}')
    ts = "read again, and again, and again, and again"

    assert_equal('read (again(, and)?)?(again(, and)?)?' +
                 '(again(, and)?)?(again(, and)?)?', re.source)
  end



  # Parse errors
  # --------------------------------------------------------------------------

  def test_parse_premature_end_raises_error
    assert_raise( RuntimeError ) { MetaRegexp.new('(a(b(c))') }
  end

  def test_parse_premature_quantifier_end_raises_error
    assert_raise( RuntimeError ) { MetaRegexp.new('(a(b){2,)') }
  end

  # TODO: figure out what is really happening with empty {} in ::Regexp.
  # It seems that it is allowed, but makes its quantified unmatchable? A
  # zero-or-zero match? For now, stdlib Regexp allows empty {}, so let it
  # through.
  def test_parse_empty_range_quantifier_does_not_raise_error
    re = nil
    assert_nothing_raised( RuntimeError ) { 
      re = MetaRegexp.new('(range(is(empty){}))')
    }
    assert_equal('(range(is(empty)))', re.source)
  end



  # Compatibility with the standard Regexp
  # --------------------------------------------------------------------------

  def test_meta_regexp_is_a_kind_of_regexp
    assert_kind_of ::Regexp, MetaRegexp.new('a')
  end

  def test_match_method_returns_wrapped_match_data
    assert_kind_of(MetaRegexp::MatchData,
                   MetaRegexp.new('[a-z]+').match('me'))
  end

  def test_accepts_string_argument
    assert_equal('as+is', MetaRegexp.new('as+is').source)
  end

  def test_accepts_regexp_argument
    assert_equal('ca[bnt](s)(s)', MetaRegexp.new('ca[bnt](s){2}').source)
  end



  # Compatibility with standard MatchData
  # --------------------------------------------------------------------------

  def test_match_data_delegates_to_std_match_data
    re = MetaRegexp.new('ruby')
    md = re.match("this is ruby")

    assert_equal([8,12], md.offset(0))
  end



  # MatchData: .filter
  # --------------------------------------------------------------------------

  def test_filter_compacts_by_default
    re = MetaRegexp.new(/^((two|four)\s+legs\s+(bad|good)(?:, |\.)?)+$/i)
    md = re.match("Four legs good, two legs bad.")

    assert(md.filter.any?{|m| not m.nil?}, "filter should compact by default")
  end

  def test_filter_without_compact # is the same as captures
    re = MetaRegexp.new('^(\d{3}\s*)+$')
    md = re.match("123 234 345 456")

    assert_equal(md.captures, md.filter(false)) 
  end

  def test_filter_with_block_only
    re = MetaRegexp.new('^Given I have (\s*( and)?(the)?\s*(\w+),?)+$')

    md = re.match("Given I have this, that, and the otherthing")
    cs = md.filter(false) {|m| m.nil? or m =~ /^\s+|,$/ }

    assert_equal(["this", "that", "and", "the", "otherthing"], cs)
  end

  def test_filter_with_compact_and_block
    re = MetaRegexp.new('^Given I have (\s*( and)?(the)?\s*(\w+),?)+$')

    md = re.match("Given I have this, that, and the otherthing")
    cs = md.filter {|m| m =~ /^\s+|\s+$|,$|^and$|^the$/ }

    assert_equal(["this", "that", "otherthing"], cs)
  end



  # MatchData: .skip_every
  # --------------------------------------------------------------------------

  def test_skip_without_arguments
    re = MetaRegexp.new /((ca(b|ll|n|t))\s*)+/

    md = re.match("can cat call cab")

    assert_equal(md.filter, md.skip) # same as filter (without nils)
  end

  def test_skip_with_before_and_after
    re = MetaRegexp.new /((ca(b|ll|n|t))\s*)+/
    md = re.match("can cat call cab")

    assert_equal(["can", "cat", "call", "cab"], md.skip(1,1))
  end


  def test_full_match_return_first_of_matches
    re = MetaRegexp.new /((ca(b|ll|n|t))\s*)+/
    md = re.match("can cat call cab")

    assert_equal("can cat call cab", md.full_match)
  end

end
