#!/usr/bin/env rspec
require 'spec_helper'

describe Puppet::OldType do
  describe "when defining parameters" do
    before do
      @type = Puppet::Type.newtype(:parameter_tester)
    end

    after do
      Puppet::Type.rmtype(:parameter_tester)
    end

    it "should support defining and retrieving parameters" do
      @type.newparam(:foo)
      @type.parameter(:foo).should be_instance_of(Class)
    end

    it "should support retrieving parameters specified with a string" do
      @type.newparam(:foo)
      @type.parameter("foo").should be_instance_of(Class)
    end

    it "should support returning all parameters" do
      foo = @type.newparam(:foo)
      @type.parameters.should be_include(foo)
    end

    it "should always return parameters in the order specified" do
      foo = @type.newparam(:foo)
      bar = @type.newparam(:bar)
      baz = @type.newparam(:baz)
      params = @type.parameters
      params.index(foo).should < params.index(bar)
      params.index(bar).should < params.index(baz)
    end

    it "should always put the namevar first" do
      foo = @type.newparam(:foo)
      name = @type.newparam(:name) { isnamevar }
      params = @type.parameters
      params.index(name).should < params.index(foo)
    end

    it "should always put the namevar first even if the parameter isn't declared the namevar but is named 'name'" do
      foo = @type.newparam(:foo)
      name = @type.newparam(:name)
      params = @type.parameters
      params.index(name).should < params.index(foo)
    end

    it "should always put 'provider' as the first-non-namevar parameter" do
      foo = @type.newparam(:foo)
      provider = @type.newparam(:provider)
      name = @type.newparam(:name)
      params = @type.parameters
      params.index(name).should < params.index(provider)
      params.index(provider).should < params.index(foo)
    end

    it "should always put 'provider' as the first-non-namevar parameter even when it's added later" do
      name = @type.newparam(:name)
      provider = @type.newparam(:provider)
      foo = @type.newparam(:foo)
      params = @type.parameters
      params.index(name).should < params.index(provider)
      params.index(provider).should < params.index(foo)
    end

    it "should always put 'ensure' before any other properties but after the namevar" do
      foo = @type.newproperty(:foo)
      ens = @type.newproperty(:ensure)
      name = @type.newparam(:name) { isnamevar }
      params = @type.parameters
      params.index(name).should < params.index(ens)
      params.index(ens).should < params.index(foo)
    end

    it "should include metaparameters when asked for all parameters" do
      noop = @type.parameter(:noop)
      @type.parameters.should be_include(noop)
    end

    it "should be able to return a list of parameter names" do
      @type.newparam(:foo)
      @type.parameter_names.should be_include(:foo)
    end

    it "should include metaparameters when asked for all parameter names" do
      @type.parameter(:noop)
      @type.parameter_names.should be_include(:noop)
    end

    it "should support defining and retrieving properties" do
      @type.newproperty(:foo)
      @type.parameter(:foo).should be_instance_of(Class)
    end

    it "should be able to retrieve a metaparameter class by name" do
      @type.parameter(:noop).should be_instance_of(Class)
    end

    it "should consider subclasses of Property to be properties" do
      @type.newproperty(:foo)
      @type.parameter_type(:foo).should == :property
    end

    it "should be able to determine parameter type of parameters passed as a string" do
      @type.newproperty(:foo)
      @type.parameter_type("foo").should == :property
    end

    it "should be able to detect metaparameters" do
      @type.parameter_type(:noop).should == :metaparameter
    end

    it "should consider any non-metaparam subclass of Parameter to be a parameter" do
      @type.newparam(:foo)
      @type.parameter_type(:foo).should == :parameter
    end

    it "should consider a defined parameter to be valid" do
      @type.newparam(:foo)
      @type.should be_valid_parameter(:foo)
    end

    it "should consider a defined property to be valid" do
      @type.newproperty(:foo)
      @type.should be_valid_parameter(:foo)
    end

    it "should consider metaparameters to be valid" do
      @type.should be_valid_parameter(:noop)
    end

    it "should accept parameters specified as a string" do
      @type.newparam(:foo)
      @type.should be_valid_parameter("foo")
    end

    it "should always consider :name to be a valid parameter" do
      @type.should be_valid_parameter(:name)
    end

    it "should not consider :name to be a valid metaparameter" do
      Puppet::Type.should_not be_metaparameter(:name)
    end

    it "should be able to return all known properties" do
      foo = @type.newproperty(:foo)
      bar = @type.newproperty(:bar)

      @type.properties.should == [foo, bar]
    end

    it "should be able to return all known property names" do
      foo = @type.newproperty(:foo)
      bar = @type.newproperty(:bar)

      @type.property_names.should == [:foo, :bar]
    end
  end

  describe "when creating a provider" do
    before :each do
      @type = Puppet::Type.newtype(:provider_test_type)
    end

    after :each do
      @type.provider_hash.clear
    end

    it "should create a subclass of Puppet::Provider for the provider" do
      provider = @type.provide(:test_provider)

      provider.ancestors.should include(Puppet::Provider)
    end

    it "should use a parent class if specified" do
      parent_provider = @type.provide(:parent_provider)
      child_provider  = @type.provide(:child_provider, :parent => parent_provider)

      child_provider.ancestors.should include(parent_provider)
    end

    it "should use a parent class if specified by name" do
      parent_provider = @type.provide(:parent_provider)
      child_provider  = @type.provide(:child_provider, :parent => :parent_provider)

      child_provider.ancestors.should include(parent_provider)
    end

    it "should raise an error when the parent class can't be found" do
      expect {
        @type.provide(:child_provider, :parent => :parent_provider)
      }.to raise_error(Puppet::DevError, /Could not find parent provider.+parent_provider/)
    end

    it "should ensure its type has a 'provider' parameter" do
      @type.provide(:test_provider)

      @type.parameter_names.should include(:provider)
    end

    it "should remove a previously registered provider with the same name" do
      old_provider = @type.provide(:test_provider)
      new_provider = @type.provide(:test_provider)

      old_provider.should_not equal(new_provider)
    end

    it "should register itself as a provider for the type" do
      provider = @type.provide(:test_provider)

      provider.should == @type.provider(:test_provider)
    end

    it "should create a provider when a provider with the same name previously failed" do
      @type.provide(:test_provider) do
        raise "failed to create this provider"
      end rescue nil

      provider = @type.provide(:test_provider)

      provider.ancestors.should include(Puppet::Provider)
      provider.should == @type.provider(:test_provider)
    end
  end

  describe "when choosing a default provider" do
    it "should choose the provider with the highest specificity" do
      # Make a fake type
      type = Puppet::Type.newtype(:defaultprovidertest) do
        newparam(:name) do end
      end

      basic = type.provide(:basic) {}
      greater = type.provide(:greater) {}

      basic.stubs(:specificity).returns 1
      greater.stubs(:specificity).returns 2

      type.defaultprovider.should equal(greater)
    end
  end
end

describe Puppet::OldType::RelationshipMetaparam do
  it "should be a subclass of Puppet::Parameter" do
    Puppet::OldType::RelationshipMetaparam.superclass.should equal(Puppet::Parameter)
  end

  it "should be able to produce a list of subclasses" do
    Puppet::OldType::RelationshipMetaparam.should respond_to(:subclasses)
  end

  describe "when munging relationships" do
    before do
      @resource = Puppet::Type.type(:mount).new :name => "/foo"
      @metaparam = Puppet::OldType.metaparameter(:require).new :resource => @resource
    end

    it "should accept Puppet::Resource instances" do
      ref = Puppet::Resource.new(:file, "/foo")
      @metaparam.munge(ref)[0].should equal(ref)
    end

    it "should turn any string into a Puppet::Resource" do
      @metaparam.munge("File[/ref]")[0].should be_instance_of(Puppet::Resource)
    end
  end

  it "should be able to validate relationships" do
    Puppet::OldType.metaparameter(:require).new(:resource => mock("resource")).should respond_to(:validate_relationship)
  end

  it "should fail if any specified resource is not found in the catalog" do
    catalog = mock 'catalog'
    resource = stub 'resource', :catalog => catalog, :ref => "resource"

    param = Puppet::OldType.metaparameter(:require).new(:resource => resource, :value => %w{Foo[bar] Class[test]})

    catalog.expects(:resource).with("Foo[bar]").returns "something"
    catalog.expects(:resource).with("Class[Test]").returns nil

    param.expects(:fail).with { |string| string.include?("Class[Test]") }

    param.validate_relationship
  end
end

describe Puppet::OldType.metaparameter(:check) do
  it "should warn and create an instance of ':audit'" do
    file = Puppet::Type.type(:file).new :path => "/foo"
    file.expects(:warning)
    file[:check] = :mode
    file[:audit].should == [:mode]
  end
end

describe Puppet::OldType.metaparameter(:audit) do
  before do
    @resource = Puppet::Type.type(:file).new :path => "/foo"
  end

  it "should default to being nil" do
    @resource[:audit].should be_nil
  end

  it "should specify all possible properties when asked to audit all properties" do
    @resource[:audit] = :all

    list = @resource.class.properties.collect { |p| p.name }
    @resource[:audit].should == list
  end

  it "should accept the string 'all' to specify auditing all possible properties" do
    @resource[:audit] = 'all'

    list = @resource.class.properties.collect { |p| p.name }
    @resource[:audit].should == list
  end

  it "should fail if asked to audit an invalid property" do
    lambda { @resource[:audit] = :foobar }.should raise_error(Puppet::Error)
  end

  it "should create an attribute instance for each auditable property" do
    @resource[:audit] = :mode
    @resource.parameter(:mode).should_not be_nil
  end

  it "should accept properties specified as a string" do
    @resource[:audit] = "mode"
    @resource.parameter(:mode).should_not be_nil
  end

  it "should not create attribute instances for parameters, only properties" do
    @resource[:audit] = :noop
    @resource.parameter(:noop).should be_nil
  end

  describe "when generating the uniqueness key" do
    it "should include all of the key_attributes in alphabetical order by attribute name" do
      Puppet::Type.type(:file).stubs(:key_attributes).returns [:path, :mode, :owner]
      Puppet::Type.type(:file).stubs(:title_patterns).returns(
        [ [ /(.*)/, [ [:path, lambda{|x| x} ] ] ] ]
      )
      res = Puppet::Type.type(:file).new( :title => '/my/file', :path => '/my/file', :owner => 'root', :content => 'hello' )
      res.uniqueness_key.should == [ nil, 'root', '/my/file']
    end
  end

  describe "when being reloaded" do
    it "should not lose its provider list when it is reloaded" do
      type = Puppet::Type.newtype(:reload_with_providers) do
        newparam(:name) {}
      end

      provider = type.provide(:myprovider) {}

      # reload it
      type = Puppet::Type.newtype(:reload_with_providers) do
        newparam(:name) {}
      end

      type.provider(:myprovider).should equal(provider)
    end

    it "should not lose its provider parameter when it is reloaded" do
      type = Puppet::Type.newtype(:reload_test_type) do
        newparam(:name) {}
      end

      provider = type.provide(:test_provider)

      # reload it
      type = Puppet::Type.newtype(:reload_test_type) do
        newparam(:name) {}
      end

      type.parameter_names.should include(:provider)
    end
  end
end
