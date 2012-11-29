#!/usr/bin/env ruby
require 'rainbow'
require 'peach'
require 'json'
require 'clamp'
require 'net/ssh'
require 'net/scp'

class InitCommand < Clamp::Command
  option ["-r", "--role"], "ROLE", "Resource name to initilize", :required => true
  option ["-e", "--environment"], "ENVIRONMENT", "Which environment, e.g. production", :required => true
  option ["-z", "--zone"], "ZONE", "AWS availability zone to put node in", :required => true
  option ["-t", "--type"], "TYPE", "Type of instance, e.g. m1.large", :required => true
  def execute
    $api.addnode(zone, type, role, environment)
  end
end

class TerminateCommand < Clamp::Command
  option ["-z", "--zone"], "ZONE", "AWS availability zone to put node in", :required => true
  option ["-i", "--instance"], "INSTANCE", "Instance ID, e.g. i-12345678", :required => true
  def execute
    $api.terminatenode(instance, zone)
  end
end

class SshCommand < Clamp::Command
  option ["-r", "--role"], "ROLE", "Role name to ssh to", :required => true
  option ["-e", "--environment"], "ENVIRONMENT", "Which environment, e.g. production", :required => true
  option ["-i", "--instance"], "INSTANCE", "Node instance, leave blank to query avilable nodes", :require => false
  option ["-f", "--first"], :flag, "Just connect to first available instance", :require => false

  def execute
    if instance
      @ssh = $api.ssh(role, environment, instance)
    else
      nodes = $api.getenvroles(role, environment)
      if first? || nodes.size == 1
        puts "No instnace specified, but only one instance in cluster or first forced"
        @ssh = $api.ssh(role, environment, nodes.first['instance'])
      else
        puts "No instance specified, querying list."
        nodes.each_index do |i|
          puts "#{i}: #{nodes[i]['instance']}"
        end
        print "Select a node: ".color(:cyan)
        @ssh = $api.ssh(role, environment, nodes[$stdin.gets.chomp.to_i]['instance'])
      end
    end
    File.open('/tmp/gtkey', 'w') {|f| f.write(@ssh['key'])}
    File.chmod(0600, '/tmp/gtkey')
    system "SSH_AUTH_SOCK='' ssh -i /tmp/gtkey admin@#{@ssh['hostname']}"
  end

end

def sshcmd(node, commands)
  Net::SSH.start(
    node['hostname'],
    'admin',
    :key_data => [$api.ssh(node['role'], node['environment'], node['instance'])['key']],
    :config => false,
    :keys_only => true,
    :paranoid => false
  ) do |ssh|
    commands.each do |command|
      command.color(:cyan)
      ssh.exec! command do
        |ch, stream, line|
        puts "#{node['role'].color(:yellow)}:#{node['environment'].color(:yellow)}:#{node['instance'].color(:yellow)}> #{line}"
      end
    end
  end
end


class ChefrunCommand < Clamp::Command
  option ["-r", "--role"], "ROLE", "Role name to ssh to", :required => true
  option ["-e", "--environment"], "ENVIRONMENT", "Which environment, e.g. production", :required => true

  def execute
    nodes = $api.getenvroles(role, environment)
    nodes.peach do |node|
      json = {
        'this_server' => "#{role}-#{environment}-#{node['instance']}",
        'role' => role,
        'app_user' => node['appuser'],
        'run_list' => [ "recipe[main]" ],
        'hostname' => node['hostname'],
        'instance' => node['instance'],
        'zone' => node['zone'],
        'itype' => node['itype'],
        'apps' => node['apps']
      }.to_json
      commands = [
        "cd ~admin/ops; git pull",
        "echo '#{json}' > ~admin/solo.json",
        "sudo chef-solo -c ~admin/ops/cookbooks/solo.rb -j ~admin/solo.json"
      ]
      sshcmd(node, commands)
    end
  end
end

class DeployCommand < Clamp::Command

end

class MainCommand < Clamp::Command

  subcommand "init", "Create new application cluster", InitCommand
  subcommand "terminate", "Terminate instance", TerminateCommand
  subcommand "ssh", "ssh to cluster host", SshCommand
  subcommand "chefrun", "chefrun on a resource pool", ChefrunCommand
  subcommand "deploy", "deploy on an application", DeployCommand

end

MainCommand.run
