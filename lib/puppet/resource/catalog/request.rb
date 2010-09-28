require 'puppet/indirector'
require 'puppet/util/pson'

class Puppet::Resource::Catalog::Request
  include Puppet::Util
  extend Puppet::Indirector
  indirects :catalog_request

  attr_reader :name
  attr_accessor :facts

  def self.from_pson(pson)
    raise ArgumentError, "No name provided in pson data" unless name = pson['name']

    request = new(name)

    if facts = pson['facts']
      request.facts = facts
    end

    request
  end

  def to_pson(*args)
    result = {'name' => name}
    result['facts'] = facts if facts
    result
  end

  def self.compiler
    @compiler ||= Puppet::Resource::Catalog.indirection.terminus(:compiler)
  end

  def compiler
    self.class.compiler
  end

  def compile
    request = Puppet::Indirector::Request.new(:catalog, :find, name)
    compiler.find(request)
  end

  def initialize(name, facts = {})
    @name = name
    @facts = facts
  end

  def execute
    Puppet.warning "Trying to execute request for #{name}"
    real_facts = Puppet::Node::Facts.new(name, facts)

    benchmark :info, "Saved facts for #{name}" do
      real_facts.save
    end

    catalog = nil
    benchmark :notice, "Compiled catalog for #{name}" do
      unless catalog = compile
        raise "Could not compile catalog for #{name}"
      end
    end

    # We're assuming that the catalog is being saved into some kind of store that the client can read from
    catalog.save
  end
end
