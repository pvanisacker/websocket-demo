require 'sinatra'
require 'sinatra-websocket'
require 'em-hiredis'

module SinatraWebsocket
  # Add company_id to websocket connection
  class Connection
    attr_accessor :company_id
  end
end

def run(opts)
  EM.run do
    server  = opts[:server] || 'thin'
    host    = opts[:host]   || '0.0.0.0'
    port    = opts[:port]   || '8080'
    web_app = opts[:app]

    dispatch = Rack::Builder.app do
      map '/' do
        run web_app
      end
    end

    Rack::Server.start({
      app:    dispatch,
      server: server,
      Host:   host,
      Port:   port,
      signals: false,
    })
  end
end

# The WebsocketApp
class WebsocketApp < Sinatra::Base
  def initialize
    super()
    @channel_prefix = 'pubsub-companyid-'
    @redis_message_handler = lambda do |channel, msg|
      puts "Receive on redis channel #{channel} #{msg}"
      channel_regex = /^#{@channel_prefix}(.*)/
      if channel =~ channel_regex
        company_id = channel.match(channel_regex).captures[0]
        settings.registered_sockets[company_id].each do |ws|
          ws.send(msg)
        end
      end
    end
  end

  configure do
    set :threaded, false
    set :public_folder, File.dirname(__FILE__) + '/public'

    # A hash of all websocket connections for a specific company
    set :registered_sockets, {}
    set :redis_psubscribe, nil
    set :redis_publish, nil
    set :redis_url, ENV['REDIS_URL']
  end

  get '/' do
    send_file 'public/index.html'
  end

  get '/healthcheck' do
    'All good'
  end

  get '/websocket' do
    if !request.websocket?
      send_file 'public/index.html'
    else
      # Create redis connections for subscribing
      if settings.redis_psubscribe.nil?
        settings.redis_psubscribe = EM::Hiredis.connect(settings.redis_url)
        settings.redis_psubscribe.pubsub.psubscribe(@channel_prefix + '*', &@redis_message_handler)
      end
      # Create redis connection for publishing
      settings.redis_publish = EM::Hiredis.connect(settings.redis_url) if settings.redis_publish.nil?

      request.websocket do |ws|
        ws.onopen do
          puts 'Websocket connection openend'
        end

        ws.onmessage do |msg|
          EM.next_tick do
            if msg =~ /registering:/
              # Received a request for registering a connection
              company_id = msg.match(/registering:(.*)/i).captures[0]
              puts 'New company registration for company_id: ' + company_id
              ws.company_id = company_id
              unless settings.registered_sockets.key?(company_id)
                settings.registered_sockets[company_id] = []
              end
              settings.registered_sockets[company_id] << ws
              ws.send('registration ok for ' + company_id)
            else
              # Received a normal websocket message
              unless ws.company_id.nil?
                # Message was received for a specific company_id,
                # publish it to the redis pubsub for that company
                channel = @channel_prefix + ws.company_id
                settings.redis_publish.pubsub.publish(channel, msg).errback do |e|
                  puts e
                end
                puts "Received websocket message for company #{ws.company_id}: #{msg}"
              end
            end
          end
        end

        ws.onclose do
          if ws.company_id && settings.registered_sockets.key?(ws.company_id)
            settings.registered_sockets[ws.company_id].delete(ws)
          end
          puts 'Websocket connection closed'
        end
      end
    end
  end
end

run app: WebsocketApp.new
