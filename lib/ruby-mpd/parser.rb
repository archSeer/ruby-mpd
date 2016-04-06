require 'time' # required for Time.iso8601
require 'set'

class MPD
  # Parser module, being able to parse messages to and from the MPD daemon format.
  # @todo There are several parser hacks. Time is an array in status and a normal
  #   string in MPD::Song, so we do`@time = options.delete(:time) { [nil] }.first`
  #   to hack the array return. Playlist names are strings, whilst in status it's
  #   and int, so we parse it as an int if it's parsed as non-zero (if it's 0 it's a string)
  #   and to fix numeric name playlists (123.m3u), we convert the name to_s inside
  #   MPD::Playlist too.
  module Parser
    private

    # Parses the command into MPD format.
    def convert_command(command, *params)
      params.map! do |param|
        case param
        when true, false
          param ? '1' : '0' # convert bool to 1 or 0
        when Range
          if param.end == -1 # negative means to end of range
            "#{param.begin}:"
          else
            "#{param.begin}:#{param.end + (param.exclude_end? ? 0 : 1)}"
          end
        when MPD::Song
          quotable_param param.file
        when MPD::Playlist
          quotable_param param.name
        when Hash # normally a search query
          param.each_with_object("") do |(type, what), query|
            query << "#{type} #{quotable_param what} "
          end.strip
        else
          quotable_param param
        end
      end
      [command, params].join(' ').strip
    end

    # MPD requires that certain parameters be double-quoted
    def quotable_param(value)
      return if value.nil?
      value = value.to_s
      value.empty? || (value=~/['"\s\\]/) ? %Q{"#{value.gsub('\\','\\\\\\\\').gsub('"','\\"')}"} : value
    end

    INT_KEYS = Set[
      :song, :artists, :albums, :songs, :uptime, :playtime, :db_playtime, :volume,
      :playlistlength, :xfade, :pos, :id, :date, :track, :disc, :outputid, :mixrampdelay,
      :bitrate, :nextsong, :nextsongid, :songid, :updating_db,
      :musicbrainz_trackid, :musicbrainz_artistid, :musicbrainz_albumid, :musicbrainz_albumartistid
    ]

    SYM_KEYS   = Set[:command, :state, :changed, :replay_gain_mode, :tagtype]
    FLOAT_KEYS = Set[:mixrampdb, :elapsed]
    BOOL_KEYS  = Set[:repeat, :random, :single, :consume, :outputenabled]

    # Commands where it makes sense to always explicitly return an array.
    RETURN_ARRAY = Set[:channels, :outputs, :readmessages, :list,
      :listallinfo, :find, :search, :listplaylists, :listplaylist, :playlistfind,
      :playlistsearch, :plchanges, :tagtypes, :commands, :notcommands, :urlhandlers,
      :decoders, :listplaylistinfo, :playlistinfo]

    # Commands that should always return MPD::Song instances
    SONG_COMMANDS = Set[:listallinfo,:playlistinfo,:find,:findadd,:search,
      :searchadd,:playlistfind,:playlistsearch,:plchanges,:listplaylistinfo]

    # Commands that should always return MPD::Playlist instances
    PLAYLIST_COMMANDS = Set[:listplaylists]

    # Parses key-value pairs into correct class.
    def parse_key(key, value)
      if INT_KEYS.include? key
        value.to_i
      elsif FLOAT_KEYS.include? key
        value == 'nan' ? Float::NAN : value.to_f
      elsif BOOL_KEYS.include? key
        value != '0'
      elsif SYM_KEYS.include? key
        value.to_sym
      elsif key == :playlist && !value.to_i.zero?
        # doc states it's an unsigned int, meaning if we get 0,
        # then it's a name string.
        value.to_i
      elsif key == :db_update
        Time.at(value.to_i)
      elsif key == :"last-modified"
        Time.iso8601(value)
      elsif key == :time
        if value.include?(':')
          value.split(':').map(&:to_i)
        else
          [nil, value.to_i]
        end
      elsif key == :audio
        value.split(':').map(&:to_i)
      else
        value.force_encoding('UTF-8')
      end
    end

    # Parses a single response line into a key-object (value) pair.
    def parse_line(line)
      key, value = line.split(/:\s?/, 2)
      key = key.downcase.to_sym
      return key, parse_key(key, value.chomp)
    end

    # This builds a hash out of lines returned from the server,
    # elements parsed into the correct type.
    #
    # The end result is a hash containing the proper key/value pairs
    def build_hash(string)
      return {} if string.nil?
      array_keys = {}

      string.lines.each_with_object({}) do |line, hash|
        key, object = parse_line(line)

        # if val appears more than once, make an array of vals.
        if hash.include? key
          # cannot use Array(hash[key]) or [*hash[key]] because Time instances get splatted
          # cannot check for is_a?(Array) because some values (time) are already arrays
          unless array_keys[key]
            hash[key] = [hash[key]] 
            array_keys[key] = true
          end
          hash[key] << object
        else # val hasn't appeared yet, map it.
          hash[key] = object # map obj to key
        end
      end
    end

    # Make chunks from string.
    # @return [Array<String>]
    def make_chunks(string)
      first_key = string.match(/\A(.+?):\s?/)[1]
      string.split(/\n(?=#{first_key})/).map(&:strip)
    end

    # Parses the response, determining per-command on what parsing logic
    # to use (build_response vs build a single grouped hash).
    #
    # @return [Array<Hash>, Array<String>, String, Integer] Parsed response.
    def parse_response(command, string)
      if command == :listall # Explicitly handle :listall (#files) -> always return a Hash
        return build_hash(string)
      elsif command == :listallinfo
        # We do not care about directories or playlists,
        # and leaving them in breaks the heuristic used by `make_chunks`.
        string.gsub! /^(?:directory|playlist): .+?\n(?:last-modified: .+?\n)?/i, ''
      end

      # return explicit array or true if the message is empty
      return RETURN_ARRAY.include?(command) ? [] : true if string.empty?

      build_response(command, string)
    end

    def parse_command_list(commands, string)
      [].tap do |results|
        string.split("list_OK\n").each do |str|
          command = commands.shift
          results << parse_response(command, str) unless str.empty?
        end
      end
    end

    # Parses the response into appropriate objects (either a single object,
    # or an array of objects or an array of hashes).
    #
    # @return [Array<Hash>, Array<String>, String, Integer] Parsed response.
    def build_response(command, string, force_hash=nil)
      chunks = make_chunks(string)

      make_song  = SONG_COMMANDS.include?(command)
      make_plist = PLAYLIST_COMMANDS.include?(command)
      make_hash  = force_hash || make_song || make_plist || chunks.any?{ |chunk| chunk.include? "\n" }

      list = chunks.inject([]) do |result, chunk|
        result << (make_hash ? build_hash(chunk) : parse_line(chunk)[1]) # parse_line(chunk)[1] is object
      end

      if make_song
        list.map! do |opts|
          if opts[:file] && opts[:file] =~ %r{^https?://}i
            opts = { file:opts[:file], time:[0] }
          end
          Song.new(@mpd, opts)
        end
      elsif make_plist
        list.map!{ |opts| Playlist.new(self,opts) }
      end

      # if list has only one element and not set to explicit array, return it, else return array
      (list.length == 1 && !RETURN_ARRAY.include?(command)) ? list.first : list
    end
  end
end
