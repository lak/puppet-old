require 'puppet/indirector'

# Provide any attributes or functionality needed for indirected
# instances.
module Puppet::Indirector::Envelope
  attr_accessor :expiration, :request_id

  def expired?
    expiration and expiration < Time.now
  end
end
