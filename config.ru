require 'sequenceserver'

# Serve SequenceServer under a subpath, e.g. https://host/seqserv
SequenceServer::Routes.set :root_path_prefix, '/seqserv'
SequenceServer.init

map '/seqserv' do
  run SequenceServer
end
