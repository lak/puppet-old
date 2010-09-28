require 'puppet/util/queue'
require 'stomp'
require 'uri'

# Implements the Ruby Stomp client as a queue type within the Puppet::Indirector::Queue::Client
# registry, for use with the <tt>:queue</tt> indirection terminus type.
#
# Looks to <tt>Puppet[:queue_source]</tt> for the sole argument to the underlying Stomp::Client constructor;
# consequently, for this client to work, <tt>Puppet[:queue_source]</tt> must use the Stomp::Client URL-like
# syntax for identifying the Stomp message broker: <em>login:pass@host.port</em>
class Puppet::Util::Queue::Stomp
  attr_accessor :stomp_client

  def initialize
    begin
      uri = URI.parse(Puppet[:queue_source])
    rescue => detail
      raise ArgumentError, "Could not create Stomp client instance - queue source #{Puppet[:queue_source]} is invalid: #{detail}"
    end
    unless uri.scheme == "stomp"
      raise ArgumentError, "Could not create Stomp client instance - queue source #{Puppet[:queue_source]} is not a Stomp URL: #{detail}"
    end

    begin
      self.stomp_client = Stomp::Client.new(uri.user, uri.password, uri.host, uri.port, true)
    rescue => detail
      raise ArgumentError, "Could not create Stomp client instance with queue source #{Puppet[:queue_source]}: got internal Stomp client error #{detail}"
    end
  end

  def publish(target, msg)
    stomp_client.publish(stompify_target(target), msg, :persistent => true)
  end

  def subscribe(target)
    stomp_client.subscribe(stompify_target(target), :ack => :client) do |stomp_message|
      begin
        yield(stomp_message.body)
        stomp_client.acknowledge(stomp_message)
      rescue => detail
        puts detail.backtrace if Puppet[:trace]
        Puppet.warning "Got exception processing message on #{target}: #{detail}"
      end
    end
  rescue => detail
    puts detail.backtrace if Puppet[:trace]
    Puppet.warning "Got exception subscribing to #{target}: #{detail}"
  end

  def stompify_target(target)
    '/queue/' + target.to_s
  end

  Puppet::Util::Queue.register_queue_type(self, :stomp)
end
