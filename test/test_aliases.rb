require "test/unit"
require File.expand_path("../../lib/meta_re.rb", __FILE__)

# The URL regex generated in these test cases are not necessarily valid. These
# tests are meant to validate that alias substitution takes place at different
# levels of nesting, and that the substituted alias expressions get parsed
# and compiled as well.
# ----------------------------------------------------------------------------
class TestMetaRegexp < Test::Unit::TestCase

  def setup
    MetaRegexp.alias :test,       'RUBY'

    MetaRegexp.alias :var,        '@val'  # V circular ref.
    MetaRegexp.alias :val,        '@var'  # ^ circular ref.

    MetaRegexp.alias :domain,     '([a-z]+).([a-z]+).([a-z]+)'
    MetaRegexp.alias :directory,  '(\/?([a-z]+))'
    MetaRegexp.alias :content,    '((.+)\.(.+)$)'

    MetaRegexp.alias :name,       '([name0-9]+)'                # 1 level
    MetaRegexp.alias :value,      '([value0-9]+)'
    MetaRegexp.alias :filename,   '([file]+)'
    MetaRegexp.alias :tld,        '(?:([tld]+){1})'

    MetaRegexp.alias :scheme,     '(https?|ftps?)'
    MetaRegexp.alias :style_ext,  '(?:css|sass)'
    MetaRegexp.alias :img_ext1,   '(?:jpg|png)'
    MetaRegexp.alias :img_ext2,   '(?:gif|svg)'

    MetaRegexp.alias :fqdn,       '(?:(@name\.@name\.@tld))'    # 2 levels
    MetaRegexp.alias :path,       '(?:@name(?:\/?))+'
    MetaRegexp.alias :file,       '(?:(@filename)\.(@ext))'
    MetaRegexp.alias :query,      '(?:(?:(@name)=(@value)(?:&)?)+)'
    MetaRegexp.alias :uri,        '(?:(@path)/(@file)(?:\?)?(@query)?)'

    MetaRegexp.alias :ext,        '(?:@img_ext|@style_ext)'     # 3 levels
    MetaRegexp.alias :img_ext,    '(?:@img_ext1|@img_ext2)'
  end

  def teardown
  end


  # state
  def test_00_aliasing_is_off_by_default
    state = MetaRegexp.aliasing?
    assert_equal(false, state)
  end

  def test_01_aliases_pass_thru_when_aliasing_is_off
    re = MetaRegexp.new '@test (@test (@test))'
    assert_equal('(?-mix:@test (@test (@test)))', re.to_s)
  end

  def test_02_aliasing_gets_enabled_when_set_to_true
    MetaRegexp.aliasing true

    re = MetaRegexp.new '@test (@test (@test))'
    assert_equal('(?-mix:RUBY (RUBY (RUBY)))', re.to_s)
  end

  def test_03_aliasing_gets_disabled_when_set_to_false
    MetaRegexp.aliasing false

    re = MetaRegexp.new '@test (@test (@test))'
    assert_equal('(?-mix:@test (@test (@test)))', re.to_s)
  end

  def test_04_aliasing_gets_enabled_again # for the tests below
    MetaRegexp.aliasing true

    re = MetaRegexp.new '@test (@test (@test))'
    assert_equal('(?-mix:RUBY (RUBY (RUBY)))', re.to_s)
  end


  # parsing
  def test_unregistered_aliases_pass_thru_as_is
    re = MetaRegexp.new '@one (@unknown (@alias))'
    assert_equal('(?-mix:@one (@unknown (@alias)))', re.to_s)
  end

  def test_escaped_at_sign_passes_thru
    re = MetaRegexp.new '\@test (@test (\@test))'
    assert_equal('(?-mix:\@test (RUBY (\@test)))', re.to_s)
  end


  # substitution
  def test_registered_aliases_get_substituted
    re = MetaRegexp.new 'http://@domain/@directory/@content'
    assert_equal('(?-mix:http:\\/\\/([a-z]+).([a-z]+).([a-z]+)\\/(\\/?' +
                 '([a-z]+))\\/((.+)\\.(.+)$))', re.to_s)
  end

  def test_substitution_detects_circular_references
    assert_raise( ArgumentError ) { MetaRegexp.new('(@var)=(@val)') }
  end

  def test_substitutes_and_compiles_aliases_recursively
    re = MetaRegexp.new '@scheme://@fqdn/@uri'

    ms = re.match("http://n1.n2.tld/n3/n4/file.svg?a5=val1&a6=val2")

    filtered = ms.filter { |m| m =~ /[.\/=&]/ }.uniq

    assert_equal(["http", "n1", "n2", "tld", "n3", "n4", "file", "svg",
                  "a5", "val1", "a6", "val2"], filtered)
  end

end
