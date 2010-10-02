# MetaRegexp
#
# Author: Ammar Ali
# Requires: Ruby '1.8.6'..'1.9.2' (at least that's what it was tested with)
# Copyright (c) 2010 Ammar Ali. Released under the same license as Ruby.
#
# This software is provided "as is" and without any express or implied
# warranties, including, without limitation, the implied warranties of
# merchantibility and fitness for a particular purpose.


require 'delegate'   # Used the extended MatchData class
require 'enumerator' # Work around for a strange "undefined each_slice method
                     # for Array" error that only seems to occur when being
                     # executed from within test/unit.

module MetaRegexp
  # For * (zero or more) and + (one or more) we need to define a default count
  # for repetition if one isn't specified. The number 12 is a great arbitrary
  # number. If more 'more' is needed it can be specified when new is called or
  # even better, use the {m,M} notation.
  DEFAULT_MORE_MAX = 12

  # A descendant of stdlib's Regexp that wraps the calls to parse and compile
  # in its initialize method. match is overloaded to return the extended class
  # for MatchData
  class Regexp < ::Regexp
    def initialize(input, more_max = DEFAULT_MORE_MAX)
      # Using Regexp #to_s instead of #source. Gets the regex string with all
      # options (m, i, and x). Both could be useful, maybe this should be an
      # option?
      parse_tree = MetaRegexp.parse(input.to_s.dup) # dup, it gets 'sliced'
      super( MetaRegexp.compile(parse_tree, more_max) )
    end

    # Override to return an instance of the extended MatchData
    def match(input)
      MetaRegexp::MatchData.new( super(input) )
    end
  end

  # A wrapper around ::MatchData that adds a few methods to 
  # Due to the fact that $~ has local scope, 
  class MatchData < DelegateClass(::MatchData)
    def initialize(match_data)
      super(match_data) # hook up delegate
    end

    # This acts a lot like the captures method from MatchData, with a couple
    # of additions.  If there are no matches it returns nil. If there is only
    # one match (the full match, and i.e. no captures), then it returns an
    # empty array.
    #
    # The optional argument 'compact' is a boolean, when it's true #compact is
    # called on the captures (to remove nils) before it is returned, otherwise,
    # any nil values will be kept. A nil value indicates that an optional (?)
    # expression did not match. In some situations the nil values will be useful
    # and meaningful, in other situations they are not. Most probably, the more
    # common of the two cases is to want the nil values removed, so it is set
    # as the default. 
    #
    # The optional filter block can be used to perform additional removals of
    # unwanted matches from the list returned by captures. The given block, if
    # any, is simply passed to the delete_if method of the array that will be
    # returned. If the block returns true for a given match, the match will be
    # excluded from the results.
    def filter(compact = true, &should_delete)
      return unless copy = to_a
      return unless copy.shift
      return [] if copy.empty?

      copy.compact! if compact == true
      copy.delete_if( &should_delete ) if block_given?

      copy
    end

    # MatchData's select method is a great way to select certain captures from
    # the matches by index. However, with repeating captures the number, and
    # and thus the indexes, of successful matches will be unknown.
    #
    # One repeating pattern of use when using repeating grouped patterns is to
    # add one or more grouped sub-patterns for matching surrounding characters,
    # like a comma (,) or whitespace (\s), or just to group alternative parts
    # within the main pattern. Since every grouping creates a backreference,
    # unless passive groups (?:xyz) are used, the match list will include the
    # matches for all of these sub-patterns, as it very well should.
    #
    # In such cases, and with a carefully crafted regular expression pattern,
    # the order of matches will be fixed and predictable, with the deepest
    # nested patterns appearing after shallower ones. This characteristic can
    # be taken advantage of to select matches of interest by skipping a fixed
    # number of matches (possibly zero) before and/or after the wanted ones.
    #
    # This method does just that. Instead of taking a list of fixed indexes,
    # it takes before and after counts to be skipped.
    #
    # @example
    #
    #   re = MetaRegexp.new /((ca(b|ll|n|t))\s*)+./
    #   matches = re.match("can cat call cab")
    #
    #   # skip 1 before and 1 after every match
    #   selected = matches.skip(1, 1)
    #   => ["can", "cat", "call", "cab"]
    #
    def skip(before = 0, after = 0)
      selected = []
      captures.each_slice( before + 1 + after ) do |slice|
        selected << slice.at(before)
      end; selected.compact
    end

    # Returns the last full match all by itself. Purely syntax sugar.
    def full_match
      to_a.first
    end
    alias :full :full_match
  end

  # Saves some typing and makes the module look and act like a class, to
  # complete the illusion.
  def self.new(input, more_max = DEFAULT_MORE_MAX)
    MetaRegexp::Regexp.new(input, more_max)
  end

  private

  # characters that the parser 'acts' on
  PARSE_CHARS = ['\\', '(', ')', '@'].freeze

  # characters allowed in alias names
  ALIAS_CHARS = (('a'..'z').to_a + ('0'..'9').to_a + ['_']).flatten.freeze

  # A simple recursive descent parser that identifies and collects any grouped
  # expressions and their quantifiers into an "expression tree", that is later
  # given to the compile method to produce a new expanded regular expression
  # string that can be passed to stdlib's Regexp.
  #
  # The only characters this parser cares about are the paranthesis, and if
  # present, the characters *, +, {, and }, but only if they occur immediately
  # after the grouped pattern. All other characters, including escaped versions
  # of *, + , { and }, are passed through as is.
  def self.parse(input, at_depth = 0)
    groups = []
    in_group = (at_depth == 0 ? false : true)

    while input[0] and (rc = input.slice!(/./)) do
      if rc == '\\'
        groups << { :c => (rc + (input[0] ? input.slice!(/./) : '')) }
        next

      elsif rc == '('
        group = { :g => self.parse(input, at_depth+1) }
        groups << self.quantify(input, group) 
        next

      elsif rc == ')'
        raise "#{self.name}: unexpected end of pattern group at '#{rc}'." if
          not in_group

        in_group = false
        break

      elsif rc == '@' and self.aliasing?
        groups << { :a => self._alias(input) }

      else
        exp = rc
        while input[0] and not PARSE_CHARS.include?(input[0].chr) do
          exp << input.slice!(/./)
        end
        groups << { :c => exp }
      end
    end

    if in_group == true
      raise "#{self.name}: premature end of grouped pattern."
    end

    groups
  end

  # This is where most of the work gets done. This method gets called for
  # every grouped pattern encountered by parse. Checks for and reads any
  # quantifier(s) following the given group, adding their values to the group
  # metadata (a Hash) in the tree. The values parsed by this method determine
  # the count a certain grouped pattern will be "emitted" during compilation,
  # and how many of those times are "required" (minimum matches) vs how many
  # are "optional" (maximum matches).
  #
  # The quantifiers that are recognized and parsed are *, +, and repetition
  # range {m,M}. There's nothing useful that can be done with the  zero or
  # one quantifier (?) so it is ignored.
  #
  # For ranged repetition, exact counts {N}, maximum only {,M} (min = *),
  # and full range {m,M} notations as supported.
  def self.quantify(input, group)
    return group unless input[0] and ['*', '+', '{'].include?(input[0].chr)

    have_min = false
    have_max = false

    read_start = false
    read_end = false
    read_len = 0

    while rc = input.slice!(/./) do
      read_len += 1

      if rc == '{'
        read_start = true
        next

      elsif rc == '}'
        if read_len == 0
          { :c => '{}' } # empty. put it back, Regexp allows it!
        end

        read_end = true
        break

      elsif rc == '+'
        group[:m] = 1
        group[:M] = :plus

        read_end = true
        break

      elsif rc == '*'
        group[:m] = 0
        group[:M] = :star

        read_end = true
        break

      elsif rc =~ /^[0-9]$/
        value = rc

        while input[0] and
          (input[0].chr =~ /[0-9]/) and
          (i = input.slice!(/./)) do
            value << i
            read_len += 1
        end

        if have_min
          group[:M] = value.to_i;
          have_max  = true
        else
          group[:m] = value.to_i;
          have_min  = true
        end

      elsif rc == ','
        unless have_min
          group[:m] = 0
          have_min  = true
        end
        next

      elsif rc =~ /\s/
        next

      else
        raise "#{self.name}: unexpected quantifier " +
          "character '#{rc}', expected '*', '+', '}', or 0-9"
      end
    end

    if read_start and not read_end
      raise "#{self.name}: premature end of quantifier at '#{rc}'."
    end

    # Apparently the standard Regexp allows these through, so do the same.
    #if read_start and read_end and (not have_min and not have_max)
    #  raise "#{self.name}: empty repetition quantifier."
    #end

    group
  end

  # Recompiles the text of the regex using the metadata collected by parse.
  # There are three types of "nodes" in given groups tree, :c for copied (pass
  # thru) character runs, :a for aliases, and finally :g for any grouped
  # expressions with quantifiers. The output of this method is a string that
  # is suitable for passing to #new of the standard Regexp class.
  def self.compile(groups, more_max = DEFAULT_MORE_MAX)
    out = ''
    groups.each do |g|
      if g.has_key?(:c)
        exp = g[:c]
        out << exp

      elsif g.has_key?(:a)
        exp = self.compile(g[:a], more_max)
        out << exp

      else
        exp = "(#{self.compile(g[:g], more_max)})"
        if g[:m]
          min = g[:m].to_i
          if min and min > 0
            min.times {|i| out << exp }
          end

          if g[:M]
            if g[:M] == :plus or g[:M] == :star
              max = more_max
            else
              max = g[:M].to_i
            end

            if max and max > 0
              (max - min).times {|i| out << exp << '?' }
            end
          end
        else
          out << exp
        end
      end
    end
    out
  end

  # Aliases, for lack of a better name at the moment
  @@aliases     = {}
  @@alias_stack = []
  @@aliasing_on = false

  # Enable/disable aliasing support in the parser.
  def self.aliasing(state = nil)
    @@aliasing_on = state unless state.nil?
  end

  # Returns a true if aliasing is enabled, false otherwise.
  def self.aliasing?
    @@aliasing_on
  end

  # Add, delete, get one, or get all aliases, depending on given arguments.
  # When called with a name and a value, a new alias is set, or an existing
  # one overwritten. The special value ':delete' is used to do just that.
  # Without a value, this method will return the value associated with the
  # named alias, if one exists, else nil. The special name ':*' will return
  # all defined aliases as a hash.
  def self.alias(name, value = nil)
    return unless name
    if value
      if value == :delete
        @@aliases[name.to_s] = nil
      else
        @@aliases[name.to_s] = value.to_s
      end
    else
      if name == :*
        @@aliases
      else
        @@aliases[name.to_s]
      end
    end
  end

  # Alias parsing and expansion method. This method is called by parse upon
  # encountering an at sign (@) to read the following characters and if they
  # match a named alias, replace with the definition of that alias, possibly
  # containing aliases as well. Grouped expressions inside aliases are also
  # parsed and expanded recursively. Returns a sub-tree (an array of hashes.)
  def self._alias(input)
    name = ''
    while input[0] and ALIAS_CHARS.include?(input[0].chr) do
      name << input.slice!(/./)
    end

    if @@aliases.has_key?(name)
      if @@alias_stack.include?(name)
        raise ArgumentError,
          "#{self.name}: circular alias reference detected (@#{name}.)"
      end

      @@alias_stack << name
      sub = self.parse( @@aliases[name].to_s.dup ) # dup, it gets sliced
      @@alias_stack.pop

      sub
    else
      [{:c => "@#{name}"}] # copy thru, as a sub-tree
    end
  end

end # module MetaRegexp
