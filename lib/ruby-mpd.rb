require 'socket'
require 'thread'

require 'ruby-mpd/version'
require 'ruby-mpd/exceptions'
require 'ruby-mpd/song'
require 'ruby-mpd/parser'
require 'ruby-mpd/playlist'

require 'ruby-mpd/plugins/information'
require 'ruby-mpd/plugins/playback_options'
require 'ruby-mpd/plugins/controls'
require 'ruby-mpd/plugins/queue'
require 'ruby-mpd/plugins/playlists'
require 'ruby-mpd/plugins/database'
require 'ruby-mpd/plugins/stickers'
require 'ruby-mpd/plugins/outputs'
require 'ruby-mpd/plugins/reflection'
require 'ruby-mpd/plugins/channels'

# @!macro [new] error_raise
#   @raise (see #send_command)
# @!macro [new] returnraise
#   @return [Boolean] returns true if successful.
#   @macro error_raise

# The main class/namespace of the MPD client.
class MPD
  include Parser

  include Plugins::Information
  include Plugins::PlaybackOptions
  include Plugins::Controls
  include Plugins::Queue
  include Plugins::Playlists
  include Plugins::Database
  include Plugins::Stickers
  include Plugins::Outputs
  include Plugins::Reflection
  include Plugins::Channels

  # The version of the MPD protocol the server is using.
  attr_reader :version

  # Initialize an MPD object with the specified hostname and port.
  # When called without arguments, 'localhost' and 6600 are used.
  def initialize(hostname = 'localhost', port = 6600)
    @hostname = hostname
    @port = port
    reset_vars

    @mutex = Mutex.new
    @callbacks = {}
  end

  # Initialize instance variables on new object, or on disconnect.
  def reset_vars
    @socket = nil
    @version = nil
    @tags = nil
  end
  private :reset_vars

  # This will register a block callback that will trigger whenever
  # that specific event happens.
  #
  #   mpd.on :volume do |volume|
  #     puts "Volume was set to #{volume}!"
  #   end
  #
  # One can also define separate methods or Procs and whatnot,
  # just pass them in as a parameter.
  #
  #  method = Proc.new {|volume| puts "Volume was set to #{volume}!" }
  #  mpd.on :volume, &method
  #
  # @param [Symbol] event The event we wish to listen for.
  # @param [Proc, Method] block The actual callback.
  # @return [void]
  def on(event, &block)
    @callbacks[event] ||= []
    @callbacks[event].push block
  end

  # Triggers an event, running it's callbacks.
  # @param [Symbol] event The event that happened.
  # @return [void]
  def emit(event, *args)
    return unless @callbacks[event]
    @callbacks[event].each do |handle|
      handle.call *args
    end
  end

  # Constructs a callback loop thread and/or resumes it.
  # @return [Thread]
  def callback_thread
    @cb_thread ||= Thread.new(self) do |mpd|
      old_status = {}
      while true
        status = mpd.status rescue {}

        status[:connection] = mpd.connected?

        status[:time] = [nil, nil] if !status[:time] # elapsed, total
        status[:audio] = [nil, nil, nil] if !status[:audio] # samp, bits, chans

        status[:song] = mpd.current_song

        status.each do |key, val|
          next if val == old_status[key] # skip unchanged keys
          # convert arrays to splat arguments
          val.is_a?(Array) ? emit(key, *val) : emit(key, val)
        end

        old_status = status
        sleep 0.1

        if !status[:connection] && !Thread.current[:stop]
          sleep 2
          mpd.connect rescue nil
        end

        Thread.stop if Thread.current[:stop]
      end
    end
    @cb_thread[:stop] = false
    @cb_thread.run if @cb_thread.stop?
  end
  private :callback_thread

  # Connect to the daemon.
  #
  # When called without any arguments, this will just connect to the server
  # and wait for your commands.
  #
  # When called with +callbacks: true+ as an argument, this will enable callbacks by starting
  # a seperate polling thread, which will also automatically reconnect if disconnected
  # for whatever reason.
  #
  # @return [true] Successfully connected.
  # @raise [MPDError] If connect is called on an already connected instance.
  def connect(opts = {callbacks: false})
    raise ConnectionError, 'Already connected!' if self.connected?

    @socket = File.exists?(@hostname) ? UNIXSocket.new(@hostname) : TCPSocket.new(@hostname, @port)

    # by protocol, we need to get a 'OK MPD <version>' reply
    # should we fail to do so, the connection was unsuccessful
    if response = @socket.gets
      @version = response.chomp.gsub('OK MPD ', '') # Read the version
    else
      reset_vars
      raise ConnectionError, 'Unable to connect (possibly too many connections open)'
    end

    if opts == true || opts == false
      warn "Using 'true' or 'false' as an argument to #connect has been deprecated, and will be removed in the future!"
      opts = {callbacks: opts}
    end

    callback_thread if opts[:callbacks]
    return true
  end

  # Check if the client is connected.
  #
  # @return [Boolean] True only if the server responds otherwise false.
  def connected?
    return false if !@socket

    ret = send_command(:ping) rescue false
    return ret
  end

  # Disconnect from the MPD daemon. This has no effect if the client is not
  # connected. Reconnect using the {#connect} method. This will also stop
  # the callback thread, thus disabling callbacks.
  # @return [Boolean] True if successfully disconnected, false otherwise.
  def disconnect
    @cb_thread[:stop] = true if @cb_thread

    return false if !@socket

    @socket.puts 'close'
    @socket.close
    reset_vars
    return true
  end

  # Kills the MPD process.
  # @macro returnraise
  def kill
    send_command :kill
  end

  # Used for authentication with the server.
  # @param [String] pass Plaintext password
  # @macro returnraise
  def password(pass)
    send_command :password, pass
  end

  # Ping the server.
  # @macro returnraise
  def ping
    send_command :ping
  end

  # Used to send a command to the server, and to recieve the reply.
  # Reply gets parsed. Synchronized on a mutex to be thread safe.
  #
  # Can be used to get low level direct access to MPD daemon. Not
  # recommended, should be just left for internal use by other
  # methods.
  #
  # @return (see #handle_server_response)
  # @raise [MPDError] if the command failed.
  def send_command(command, *args)
    raise ConnectionError, "Not connected to the server!" if !@socket

    @mutex.synchronize do
      begin
        @socket.puts convert_command(command, *args)
        response = handle_server_response
        return parse_response(command, response)
      rescue Errno::EPIPE
        reset_vars # kill the socket and reset
        raise ConnectionError, 'Broken pipe (got disconnected)'
      end
    end
  end

  private

  # Handles the server's response (called inside {#send_command}).
  # Repeatedly reads the server's response from the socket.
  #
  # @return (see Parser#build_response)
  # @return [true] If "OK" is returned.
  # @raise [MPDError] If an "ACK" is returned.
  def handle_server_response
    msg = ''
    while true
      case line = @socket.gets
      when "OK\n", nil
        break
      when /^ACK/
        error = line
        break
      else
        msg << line
      end
    end

    if !error
      return msg
    else
      err = error.match(/^ACK \[(?<code>\d+)\@(?<pos>\d+)\] \{(?<command>.*)\} (?<message>.+)$/)
      raise SERVER_ERRORS[err[:code].to_i], "[#{err[:command]}] #{err[:message]}"
    end
  end

  SERVER_ERRORS = {
    1 => NotListError,
    2 => ServerArgumentError,
    3 => IncorrectPassword,
    4 => PermissionError,
    5 => ServerError,

    50 => NotFound,
    51 => PlaylistMaxError,
    52 => SystemError,
    53 => PlaylistLoadError,
    54 => AlreadyUpdating,
    55 => NotPlaying,
    56 => AlreadyExists
  }

end
