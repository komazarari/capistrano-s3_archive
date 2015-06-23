server 'localhost',
       user: 'vagrant',
       roles: ['web', 'app'],
       ssh_options: {
         auth_methods: ['publickey'],
         keys: '/home/vagrant/.ssh/insecure_key'
       }
