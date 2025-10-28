require 'sequenceserver'

# Serve SequenceServer under a subpath, e.g. https://host/seqserv
SequenceServer.init(root_path_prefix: '/seqserv')

map '/seqserv' do
  run SequenceServer
end
