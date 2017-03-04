require 'sinatra'
require 'sinatra-websocket'
require 'em-hiredis'

module SinatraWebsocket
  # Add company_id to websocket connection
  class Connection
    attr_accessor :company_id
  end
end



set :server, :thin
set :port, '8080'
set :public_folder, File.dirname(__FILE__) + '/public'

# An array of all websocket connections
set :sockets, []
# A hash of all websocket connections for a specific company
set :registered_sockets, {}

EM.run {
  redis = EM::Hiredis.connect('redis://localhost:32768')
  redis.pubsub.subscribe("foo") { |msg|
    p [:sub1, msg]
  }

  redis.pubsub.psubscribe("f*") { |msg|
    p [:sub2, msg]
  }
}

get '/' do
  send_file 'public/index.html'
end

get '/websocket' do
  if !request.websocket?
    send_file 'public/index.html'
  else
    request.websocket do |ws|
      ws.onopen do
        settings.sockets << ws
      end
      ws.onmessage do |msg|
        EM.next_tick do
          if msg =~ /registering:/
            company_id = msg.match(/registering:(.*)/i).captures[0]
            puts 'New company registration for company_id: ' + company_id
            ws.company_id = company_id
            unless settings.registered_sockets.key?(company_id)
              settings.registered_sockets[company_id] = []
            end
            redis.subscribe('pubsub-' + company_id, &redis_message_handler)
            settings.registered_sockets[company_id] << ws
            ws.send('registration ok for ' + company_id)
          else
            puts 'Websocket message received: ' + msg
            if ws.company_id
              # Message was received for a specific company_id,
              # publish it to the redis pubsub for that company
              redis.publish('pubsub-' + company_id, msg)
            end
          end
        end
      end
      ws.onclose do
        # TODO: check if the socket was registered and remove it from that hash.
        settings.sockets.delete(ws)
      end
    end
  end
end
