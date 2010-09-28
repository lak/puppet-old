#!/usr/bin/env ruby

require File.dirname(__FILE__) + '/../../../spec_helper'

require 'puppet/indirector/catalog_request/queue'

describe Puppet::Resource::CatalogRequest::Queue do
  it 'should be a subclass of the Queue terminus' do
    Puppet::Resource::CatalogRequest::Queue.superclass.should equal(Puppet::Indirector::Queue)
  end

  it 'should be registered with the catalog store indirection' do
    indirection = Puppet::Indirector::Indirection.instance(:catalog)
    Puppet::Resource::CatalogRequest::Queue.indirection.should equal(indirection)
  end

  it 'shall be dubbed ":queue"' do
    Puppet::Resource::CatalogRequest::Queue.name.should == :queue
  end
end
