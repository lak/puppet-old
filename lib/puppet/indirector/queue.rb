require 'puppet/indirector/terminus'
require 'puppet/util/queue'
require 'puppet/util'

# Implements the <tt>:queue</tt> abstract indirector terminus type, for storing
# model instances to a message queue, presumably for the purpose of out-of-process
# handling of changes related to the model.
#
# Relies upon Puppet::Util::Queue for registry and client object management,
# and specifies a default queue type of <tt>:stomp</tt>, appropriate for use with a variety of message brokers.
#
# It's up to the queue client type to instantiate itself correctly based on Puppet configuration information.
#
# A single queue client is maintained for the abstract terminus, meaning that you can only use one type
# of queue client, one message broker solution, etc., with the indirection mechanism.
#
# Per-indirection queues are assumed, based on the indirection name.  If the <tt>:catalog</tt> indirection makes
# use of this <tt>:queue</tt> terminus, queue operations work against the "catalog" queue.  It is up to the queue
# client library to handle queue creation as necessary (for a number of popular queuing solutions, queue
# creation is automatic and not a concern).
class Puppet::Indirector::Queue < Puppet::Indirector::Terminus
  include Puppet::Util::Queue
  include Puppet::Util

  def initialize(*args)
    super
    raise ArgumentError, "Queueing requires pson support" unless Puppet.features.pson?
  end

  # Do a synchronous request on the queue
  def find(request)
      benchmark :info, "Queued request for #{indirection.name} for #{request.key}" do
        client.publish(request_queue, request.to_pson)
      end

      result = nil
      benchmark :notice, "Received response for #{request}" do
        result = sync_look_for_response(request)
      end
      result
  rescue => detail
      puts detail.backtrace if Puppet[:trace]
      raise Puppet::Error, "Could not look for response to #{request} queue: #{detail}"
  end

  # Place the request on the queue
  def save(request)
      result = nil
      benchmark :info, "Queued #{indirection.name} for #{request.key}" do
        result = client.publish(response_queue, request.instance.render(:pson))
      end
      result
  rescue => detail
      puts detail.backtrace if Puppet[:trace]
      raise Puppet::Error, "Could not write #{request.key} to queue: #{detail}\nInstance::#{request.instance}\n client : #{client}"
  end

  def queue_name(*ary)
    ary.collect { |i| i.to_s }.join(".")
  end

  def request_queue
    queue_name "puppet", self.class.indirection_name, :request
  end

  def response_queue
    queue_name "puppet", self.class.indirection_name, :response
  end

  private

  def request_expired?(request)
    request.start ||= Time.now

    return (Time.now - request.start).to_i > 20
  end
  

  def sync_look_for_response(request)
    # Set up the callback for processing requests.
    result = nil
    error = nil
    client.subscribe(response_queue) do |pson|
      if pson =~ /^Error: (.+)/
        error = $1
      else
        begin
          result = indirection.model.convert_from(:pson, pson)
        rescue => details
          puts details.backtrace
          Puppet.warning "Failed to convert pson to #{name}: #{details}"
        end
      end
    end

    # Sleep until the 'subscribe' block fires or we time out
    until request_expired?(request)
      break if result or error
      Puppet.debug "Sleeping for result from #{request}/#{request.object_id}"
      sleep 0.5
    end

    raise "Could not retrieve catalog: #{error}" if error
    raise "Response from #{request} timed out" unless result

    return result
    if result.request_id.nil?
      Puppet.warning "No request ID for instance of #{model}"
      return result
    end

    if result.request_id != request.object_id
      raise "Got wrong response for #{request}: #{result.request_id} vs #{request.object_id}"
    end

    result
  end
end
