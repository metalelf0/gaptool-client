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

  def execute
    if instance
      @ssh = $api.ssh(role, environment, instance)
      File.open('/tmp/gtkey', 'w') {|f| f.write(@ssh['key'])}
      File.chmod(0600, '/tmp/gtkey')
      system "SSH_AUTH_SOCK='' ssh -i /tmp/gtkey admin@#{@ssh['hostname']}"
    else
      puts "No node number selected; querying provider"
      gethosts(resource, environment).each do |host|
        puts host
      end
      puts "Select number (just the number):"
      number = gets
      `ssh admin@#{resource}-#{environment}-#{number}.#{DOMAIN}`
    end
  end
end

class ChefrunCommand < Clamp::Command

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
