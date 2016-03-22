# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure(2) do |config|
  config.vm.box = "ubuntu/trusty64"

  config.vm.provision "shell", inline: <<-SHELL
    if ! dpkg -l | grep ruby2.2 > /dev/null; then
      apt-add-repository ppa:brightbox/ruby-ng
      apt-get update
      apt-get install ruby2.2 -y
    fi
    gem install bundler --no-ri --no-rdoc
    cp /vagrant/vagrant_example/.insecure_private_key /home/vagrant/.ssh/insecure_key
    chmod 400 /home/vagrant/.ssh/insecure_key
    chown vagrant:vagrant /home/vagrant/.ssh/insecure_key
    if ! grep "`ssh-keygen -y -f .ssh/insecure_key`" /home/vagrant/.ssh/authorized_keys ;then
      ssh-keygen -y -f .ssh/insecure_key >> .ssh/authorized_keys
    fi
    apt-get install git zip -y
  SHELL
end
