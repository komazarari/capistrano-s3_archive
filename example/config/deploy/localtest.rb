set :deploy_to, '/var/tmp/myapp'

server "localhost", roles: [:app]
