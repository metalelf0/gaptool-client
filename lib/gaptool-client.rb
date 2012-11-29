@ssh = @api.ssh('app', 'staging', '')
File.open('/tmp/gtkey', 'w') {|f| f.write(@ssh['key'])}
File.chmod(0600, '/tmp/gtkey')
system "SSH_AUTH_SOCK='' ssh -i /tmp/gtkey admin@#{@ssh['hostname']}"

#@api.terminatenode('i-fa8665c8', 'us-west-2')

#@api.addnode('us-west-2a', 'm1.large', 'app', 'staging')
