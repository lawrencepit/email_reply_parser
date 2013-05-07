require 'strscan'

# EmailReplyParser is a small library to parse plain text email content.  The
# goal is to identify which fragments are quoted, part of a signature, or
# original body content.  We want to support both top and bottom posters, so
# no simple "REPLY ABOVE HERE" content is used.
#
# Beyond RFC 5322 (which is handled by the [Ruby mail gem][mail]), there aren't
# any real standards for how emails are created.  This attempts to parse out
# common conventions for things like replies:
#
#     this is some text
#
#     On <date>, <author> wrote:
#     > blah blah
#     > blah blah
#
# ... and signatures:
#
#     this is some text
#
#     --
#     Bob
#     http://homepage.com/~bob
#
# Each of these are parsed into Fragment objects.
#
# EmailReplyParser also attempts to figure out which of these blocks should
# be hidden from users.
#
# [mail]: https://github.com/mikel/mail
class EmailReplyParser
  VERSION = "0.6"

  # Public: Splits an email body into a list of Fragments.
  #
  # text - A String email body.
  # from_address - from address of the email (optional)
  #
  # Returns an Email instance.
  def self.read(text, from_address = "")
    Email.new.read(text, from_address)
  end

  # Public: Get the text of the visible portions of the given email body.
  #
  # text - A String email body.
  # from_address - from address of the email (optional)
  #
  # Returns a String.
  def self.parse_reply(text, from_address = "")
    self.read(text.to_s, from_address).visible_text
  end

   ### Emails

  # An Email instance represents a parsed body String.
  class Email
    # Emails have an Array of Fragments.
    attr_reader :fragments

    def initialize
      @fragments = []
    end

    # Public: Gets the combined text of the visible fragments of the email body.
    #
    # Returns a String.
    def visible_text
      fragments.select{|f| !f.hidden?}.map{|f| f.to_s}.join("\n").rstrip
    end

    # Splits the given text into a list of Fragments.  This is roughly done by
    # reversing the text and parsing from the bottom to the top.  This way we
    # can check for 'On <date>, <author> wrote:' lines above quoted blocks.
    #
    # text - A String email body.
    # from_address - from address of the email (optional)
    #
    # Returns this same Email instance.
    def read(text, from_address = "")
      # parse out the from name if one exists and save for use later
      @from_name_raw = parse_raw_name_from_address(from_address)
      @from_name_normalized = normalize_name(@from_name_raw)
      @from_email = parse_email_from_address(from_address)

      text = normalize_text(text)

      # The text is reversed initially due to the way we check for hidden
      # fragments.
      text = text.reverse

      # This determines if any 'visible' Fragment has been found.  Once any
      # visible Fragment is found, stop looking for hidden ones.
      @found_visible = false

      # This instance variable points to the current Fragment.  If the matched
      # line fits, it should be added to this Fragment.  Otherwise, finish it
      # and start a new Fragment.
      @fragment = nil

      # Use the StringScanner to pull out each line of the email content.
      @scanner = StringScanner.new(text)
      while line = @scanner.scan_until(/\n/n)
        scan_line(line)
      end

      # Be sure to parse the last line of the email.
      if (last_line = @scanner.rest.to_s).size > 0
        scan_line(last_line, true)
      end

      # Finish up the final fragment.  Finishing a fragment will detect any
      # attributes (hidden, signature, reply), and join each line into a
      # string.
      finish_fragment

      @scanner = @fragment = nil

      # Now that parsing is done, reverse the order.
      @fragments.reverse!
      self
    end

  private
    EMPTY = "".freeze

    COMMON_REPLY_HEADER_REGEXES = [
      /^On(.+)wrote:$/nm,
      /\A\d{4}\/\d{1,2}\/\d{1,2}\s+.{1,80}\s<[^@]+@[^@]+>\Z/,
    ]

    # Line optionally starts with whitespace, contains two or more hyphens or
    # underscores, and ends with optional whitespace.
    # Example: '---' or '___' or '---   '
    MULTI_LINE_SIGNATURE_REGEX = /^\s*[-_]{2,}\s*$/

    # Line optionally starts with whitespace, followed by one hyphen, followed by a word character
    # Example: '-Sandro'
    ONE_LINE_SIGNATURE_REGEX = /^\s*-\w/

    ORIGINAL_MESSAGE_SIGNATURE_REGEX = /^[\s_-]+(Original Message)?[\s_-]+$/

    # No block-quotes (> or <), followed by up to three words, followed by "Sent from my".
    # Example: "Sent from my iPhone 3G"
    SENT_FROM_REGEX = /^Sent from my (\s*\w+){1,3}(\s*<.*>)?$/

    if defined?(Regexp::NOENCODING)
      SIGNATURE_REGEX = Regexp.new(Regexp.union(MULTI_LINE_SIGNATURE_REGEX, ONE_LINE_SIGNATURE_REGEX, ORIGINAL_MESSAGE_SIGNATURE_REGEX, SENT_FROM_REGEX).source, Regexp::NOENCODING)
    else
      SIGNATURE_REGEX = Regexp.new(Regexp.union(MULTI_LINE_SIGNATURE_REGEX, ONE_LINE_SIGNATURE_REGEX, ORIGINAL_MESSAGE_SIGNATURE_REGEX, SENT_FROM_REGEX).source)
    end

    # TODO: refactor out in a i18n.yml file
    # Supports English, French, Es-Mexican, Pt-Brazilian
    # Maps a label to a label-group
    QUOTE_HEADER_LABELS = Hash[*{
      :from => ["From", "De"],
      :to => ["To", "Para", "A"],
      :cc => ["CC"],
      :reply_to => ["Reply-To"],
      :date => ["Date", "Sent", "Enviado", "Enviada em", "Fecha"],
      :subject => ["Subject", "Assunto", "Asunto", "Objet"]
    }.map {|group, labels| labels.map {|label| [label.downcase, group]}}.flatten]

    # normalize text so it is easier to parse
    #
    # text - text to normalize
    #
    # Returns a String
    def normalize_text(text)
      # in 1.9 we want to operate on the raw bytes
      text = text.dup.force_encoding('binary') if text.respond_to?(:force_encoding)

      # Normalize line endings.
      text.gsub!("\r\n", "\n")

      # Check for multi-line reply headers. Some clients break up
      # the "On DATE, NAME <EMAIL> wrote:" line into multiple lines.
      if match = text.match(/^(On\s(.+)wrote:)$/m)
        # Remove all new lines from the reply header. as long as we don't have any double newline
        # if we do they we have grabbed something that is not actually a reply header
        text.gsub! match[1], match[1].gsub("\n", " ") unless match[1] =~ /\n\n/
      end

      # Some users may reply directly above a line of underscores.
      # In order to ensure that these fragments are split correctly,
      # make sure that all lines of underscores are preceded by
      # at least two newline characters.
      text.gsub!(/([^\n])(?=\n_{7}_+)$/m, "\\1\n")

      text
    end

    # Parse a person's name from an e-mail address
    #
    # email - email address.
    #
    # Returns a String.
    def parse_name_from_address(address)
      normalize_name(parse_raw_name_from_address(address))
    end

    def parse_raw_name_from_address(address)
      match = address.match(/^["']*([\w\s,]+)["']*\s*</)
      match ? match[1].strip.to_s : EMPTY
    end

    def parse_email_from_address(address)
      match = address.match /<(.*)>/
      match ? match[1] : address
    end

    # Normalize a name to First Last
    #
    # name - name to normailze.
    #
    # Returns a String.
    def normalize_name(name)
      if name.include?(',')
        make_name_first_then_last(name)
       else
        name
      end
    end

    def make_name_first_then_last(name)
      split_name = name.split(',')
      if split_name[0].include?(" ")
        split_name[0].to_s
      else
        split_name[1].strip + " " + split_name[0].strip
      end
    end

    ### Line-by-Line Parsing

    # Scans the given line of text and determines which fragment it belongs to.
    def scan_line(line, last = false)
      line.chomp!("\n")
      line.reverse!
      line.rstrip!

      # Mark the current Fragment as a signature if the current line is empty
      # and the Fragment starts with a common signature indicator.
      # Mark the current Fragment as a quote if the current line is empty
      # and the Fragment starts with a multiline quote header.
      scan_signature_or_quote if @fragment && line == EMPTY

      # We're looking for leading `>`'s to see if this line is part of a
      # quoted Fragment.
      is_quoted = !!(line =~ /^>+/n)

      # Note that a common reply header also counts as part of the quoted
      # Fragment, even though it doesn't start with `>`.
      unless @fragment &&
          ((@fragment.quoted? == is_quoted) ||
           (@fragment.quoted? && (line_is_reply_header?(line) || line == EMPTY)))
        finish_fragment
        @fragment = Fragment.new
        @fragment.quoted = is_quoted
      end

      @fragment.add_line(line)
      scan_signature_or_quote if last
    end

    def scan_signature_or_quote
      if signature_line?(@fragment.lines.first)
        @fragment.signature = true
        finish_fragment
      elsif multiline_quote_header_in_fragment?
        @fragment.quoted = true
        finish_fragment
      end
    end

    # Returns +true+ if the current block in the current fragment has
    # a multiline quote header, +false+ otherwise.
    #
    # The quote header we're looking for is mainly generated by Outlook
    # clients. It's considered a quote header if the first 4 folded lines
    # have one of the following forms:
    #
    # label: some text
    #  *label:* some text
    #
    # where a line like this:
    #
    # label: some text
    #   possibly indented text that belongs to the previous line
    #
    # is folded into:
    #
    # label: some text possibly indented text that belongs to the previous line
    #
    # and where label is a value from +QUOTE_HEADER_LABELS+ that appears
    # only once in the first 4 lines and where each group of a label
    # is represented at most once.
    def multiline_quote_header_in_fragment?
      folding = false
      label_groups = []
      @fragment.current_block.split("\n").each do |line|
        if line =~ /\A\s*\*?([^:]+):(\s|\*)/
          label = QUOTE_HEADER_LABELS[$1.downcase]
          if label
            return false if label_groups.include?(label)
            return true if label_groups.length == 3
            label_groups << label
            folding = true
          elsif !folding
            return false
          end
        elsif !folding
          return false
        else
          folding = true
        end
      end
      return false
    end

    # Detects if a given line is the beginning of a signature
    #
    # line - A String line of text from the email.
    #
    # Returns true if the line is the beginning of a signature, or false.
    def signature_line?(line)
      line =~ SIGNATURE_REGEX || line_is_signature_name?(line)
    end

    # Detects if a given line is a common reply header.
    #
    # line - A String line of text from the email.
    #
    # Returns true if the line is a valid header, or false.
    def line_is_reply_header?(line)
      COMMON_REPLY_HEADER_REGEXES.each do |regex|
        return true if line =~ regex
      end
      false
    end

    # Detects if the @from name is a big part of a given line and therefore the beginning of a signature
    #
    # line - A String line of text from the email.
    #
    # Returns true if @from_name is a big part of the line, or false.
    def line_is_signature_name?(line)
      regexp = generate_regexp_for_name()
      @from_name_normalized != "" && (line =~ regexp) && ((@from_name_normalized.size.to_f / line.size) > 0.25)
    end

    #generates regexp which always for additional words or initials between first and last names
    def generate_regexp_for_name
      name_parts = @from_name_normalized.split(" ")
      seperator = '[\w.\s]*'
      regexp = Regexp.new(name_parts.join(seperator), Regexp::IGNORECASE)
    end

    # Builds the fragment string, after all lines have been added.
    # It also checks to see if this Fragment is hidden.  The hidden
    # Fragment check reads from the bottom to the top.
    #
    # Any quoted Fragments or signature Fragments are marked hidden if they
    # are below any visible Fragments.  Visible Fragments are expected to
    # contain original content by the author.  If they are below a quoted
    # Fragment, then the Fragment should be visible to give context to the
    # reply.
    #
    #     some original text (visible)
    #
    #     > do you have any two's? (quoted, visible)
    #
    #     Go fish! (visible)
    #
    #     > --
    #     > Player 1 (quoted, hidden)
    #
    #     --
    #     Player 2 (signature, hidden)
    #
    def finish_fragment
      if @fragment
        @fragment.finish
        if !@found_visible
          if @fragment.quoted? || @fragment.signature? ||
              @fragment.reply_header? || @fragment.to_s.strip == EMPTY
            @fragment.hidden = true
          else
            @found_visible = true
          end
        end
        @fragments << @fragment
      end
      @fragment = nil
    end
  end

  # Represents a group of paragraphs in the email sharing common attributes.
  # Paragraphs should get their own fragment if they are a quoted area or a
  # signature.
  class Fragment < Struct.new(:quoted, :signature, :reply_header, :hidden)
    # Array of string lines that make up the content of this fragment.
    attr_reader :lines

    # Array of string lines that is being processed not having
    # an empty line.
    attr_reader :current_block

    # This is reserved for the joined String that is build when this Fragment
    # is finished.
    attr_reader :content

    def initialize
      self.quoted = self.signature = self.reply_header = self.hidden = false
      @lines = []
      @current_block = []
      @content = nil
    end

    alias quoted?    quoted
    alias signature? signature
    alias reply_header? reply_header
    alias hidden?    hidden

    def add_line(line)
      return unless line
      @lines.insert(0, line)
      if line == ""
        @current_block.clear
      else
        @current_block.insert(0, line)
      end
    end

    def current_block
      @current_block.join("\n")
    end

    # Builds the string content by joining the lines and reversing them.
    def finish
      @content = @lines.join("\n")
      @lines = @current_block = nil
    end

    def to_s
      @lines ? @lines.join("\n") : @content
    end

    def inspect
      "#{super.inspect} : #{to_s.inspect}"
    end
  end
end

