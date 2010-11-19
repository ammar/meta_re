require 'regexp_parser' # For the regexp lexer that this depends on
require 'delegate'      # Used the extended MatchData class
require 'enumerator'    # Work around for a strange "undefined each_slice method
                        # for Array" error that only seems to occur when being
                        # executed from within test/unit.

module MetaRegexp
  # For * (zero or more) and + (one or more) we need to define a default count
  # for repetition if one isn't specified. The number 12 is a great arbitrary
  # number. If more 'more' is needed it can be specified when new is called or
  # even better, use the {m,M} notation.
  DEFAULT_MORE_MAX = 12

  # A descendant of the built-in Regexp that wraps it with calls to parse and
  # compile to perform the expansion and alias resolution in its initialize
  # method. #match is overloaded to return the extended class for MatchData.
  class Regexp < ::Regexp
    def initialize(re, more_max = DEFAULT_MORE_MAX)
      # If the input is a Regexp object, the lexer (actually the scanner) uses
      # #source on it, which gets its string representation without any of the
      # options (m, i, and x). To include the options, #to_s should be called
      # on the object before passing it to MetaRegexp.new.
      tree = MetaRegexp.parse(Regexp::Lexer.scan(re, "ruby/#{RUBY_VERSION}"))
      super( MetaRegexp.compile(tree, more_max) )
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
    # number of matches (possibly zero) before and/or after the matches of
    # interest.
    #
    # This method does just that. Instead of taking a list of fixed indexes,
    # it takes before and after counts to be skipped.
    #
    # @example
    #
    #   re = MetaRegexp.new /((ca(b|ll|n|t))\s*)+./
    #   matches = re.match("can cat call cab")
    #
    #   # skip 1 before and 1 after every capture
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

  GROUP_TOKENS  = [:capture, :passive, :atomic, :options]
  ZERO_OR_ONE   = [:zero_or_one, :zero_or_one_reluctant, :zero_or_one_possessive]
  ZERO_OR_MORE  = [:zero_or_more, :zero_or_more_reluctant, :zero_or_more_possessive]
  ONE_OR_MORE   = [:one_or_more, :one_or_more_reluctant, :one_or_more_possessive]
  INTERVAL      = [:interval, :interval_reluctant, :interval_possessive]


  # Parses and collects any grouped expressions and their quantifiers into an
  # "expression tree", that gets passed to the compile method to produce a new
  # expanded regular expression string that can be used to create a new Regexp.
  #
  # The only tokens this parser cares about are the capturing group open tokens
  # (:capture, :passive, and :atomic), their balancing close tokens (:close),
  # and if present, the quantifiers, but only if they occur immediately after
  # a grouped pattern. If aliasing is enabled, all defined aliases, preceded by
  # the at sign '@' are resolved. All other tokens, are copied as is to the
  # output tree (pass thru)
  def self.parse(tokens, d = 0)
    tree = []
    in_group = (d == 0 ? false : true)

    while tokens[0] and (t = tokens.slice!(0))
      if t.type == :group and GROUP_TOKENS.include?(t.token)
        group = { :open => t.text, :group => self.parse(tokens, d+1) }
        tree << quantify(tokens, group)

      elsif t.type == :group and t.token == :close
        in_group = false
        break

      elsif self.aliasing? and t.type == :literal and t.text.include?('@')
        aa = t.text.scan(/@\w+|[^@]+/)
        aa.each_with_index do |s, i|
          if s[0].chr == '@' and self.alias(s[1..-1])
            tree << {
              :name  => s[1..-1],
              :alias => self.resolve(s[1..-1]),
            }
          else
            tree << { :copy => [s] }
          end
        end

      else
        copy = [t.text]
        while tokens[0] and not tokens[0].type == :group and not
          tokens[0].text.include?('@')
            copy << tokens.slice!(0).text
        end
        tree << { :copy => copy }
      end
    end; tree
  end

  # Called after every parsed group to check for and set min and max repetitions
  # for the group. This data is used by the compiler to generate the expanded
  # regular expression.
  def self.quantify(tokens, group)
    if tokens[0] and tokens[0].type == :quantifier
      t = tokens.slice!(0)
      case t.token
      when *ZERO_OR_ONE
        group[:min], group[:max] = 0, 1
      when *ZERO_OR_MORE
        group[:min], group[:max] = 0, :more
      when *ONE_OR_MORE
        group[:min], group[:max] = 1, :more
      when *INTERVAL
        case t.text
        when /\{(\d+),(\d+)\}/
          group[:min], group[:max] = $1.to_i, $2.to_i
        when /\{(\d+)\}/
          group[:min], group[:max] = $1.to_i, nil
        when /\{(\d+),\}/
          group[:min], group[:max] = $1.to_i, :more
        when /\{,(\d+)\}/
          group[:min], group[:max] = 0, $1.to_i
        end
      end
      group[:quantifier] = t
    end; group
  end

  # Compiles the output of the parse method into a new regular expression,
  # expanding all quantified grouped expressions.
  def self.compile(tree, more_max)
    out = ''
    tree.each do |node|
      if node.has_key?(:copy)
        node[:copy].each {|t| out << t}

      elsif node.has_key?(:alias)
        exp = ''
        exp << ('(?<' + node[:name] + '>') if self.name_groups?
        exp << self.compile(node[:alias], more_max)
        exp << ')' if self.name_groups?
        out << exp

      else
        exp = node[:open] + self.compile(node[:group], more_max) + ')'

        if node[:min]
          if node[:min] > 0
            node[:min].times {|i| out << exp}
          end

          node[:max] = more_max if node[:max] == :more
          if node[:max] and node[:max] > 0
            (node[:max] - node[:min]).times {|i| out << exp << '?'}
          end
        else
          out << exp
        end
      end
    end; out
  end

  @@aliases     = {}
  @@alias_stack = []

  @@aliasing_on = false
  @@name_groups = false

  # Enable/disable aliasing support in the parser.
  def self.aliasing(state = nil)
    @@aliasing_on = state unless state.nil?
  end

  # Returns true if aliasing is enabled, false otherwise.
  def self.aliasing?
    @@aliasing_on
  end

  # Enable/disable alias group names on compile (ruby >= 1.9 only)
  def self.name_groups(state = nil)
    raise "Alias group names requires ruby 1.9 or later" unless
      RUBY_VERSION >= '1.9'

    @@name_groups = state unless state.nil?
  end

  # Returns a true if aliases will be wrapped in named groups (ruby >= 1.9)
  def self.name_groups?
    @@name_groups
  end

  # Add, delete, get one, or get all aliases, depending on given arguments.
  # When called with a name and a value, a new alias is set, or an existing
  # one overwritten. The special value ':delete' is used to do just that.
  # Without a value, this method will return the value associated with the
  # named alias, if one exists, else t return nil. The special name ':*'
  # will return all defined aliases as a hash.
  def self.alias(name, value = nil)
    return unless name
    if value
      if value == :delete
        @@aliases[name.to_s] = nil
      else
        value = value.is_a?(Regexp) ? value.source : value
        @@aliases[name.to_s] = Regexp::Lexer.scan(value)
      end
    else
      if name == :*
        @@aliases
      else
        @@aliases[name.to_s]
      end
    end
  end

  # Alias resolution method. Called by parse for tokens with an at sign (@)
  # that match a defined alias. Since aliases can contain sub-aliases, this
  # calls the parse method to recursively resolve those as well. Returns a
  # sub-tree (an array of hashes) that the compile method expands.
  def self.resolve(name)
    if @@alias_stack.include?(name)
      raise ArgumentError,
        "#{self.name}: circular alias reference detected (@#{name}.)"
    end

    @@alias_stack << name
    sub = self.parse( @@aliases[name].dup ) # dup, it gets sliced
    @@alias_stack.pop

    sub
  end
end
