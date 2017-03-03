require 'sinatra'
require 'sinatra-websocket'

module SinatraWebsocket
  class Connection
    attr_accessor :company_id
  end
end

set :server, :thin
set :port, '8080'
set :sockets, []
set :registered_sockets, {}
set :public_folder, File.dirname(__FILE__) + '/public'

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
            settings.registered_sockets[company_id] << ws
            ws.send('registration ok for ' + company_id)
          else
            puts 'Websocket message received: ' + msg
            if ws.company_id
              # Message was received for a specific company_id, send it around
              settings.registered_sockets[ws.company_id].each do |conn|
                conn.send(msg) if conn != ws
              end
            end
          end
        end
      end
      ws.onclose do
        settings.sockets.delete(ws)
      end
    end
  end
end
