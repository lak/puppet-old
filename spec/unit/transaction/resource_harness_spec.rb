#!/usr/bin/env rspec
require 'spec_helper'

require 'puppet/transaction/resource_harness'

describe Puppet::Transaction::ResourceHarness do
  include PuppetSpec::Files

  before do
    @resource_type = Puppet::Type.newtype(:harness_test_type) do
      newparam(:name) do
        desc "The name var"
        isnamevar
      end

      newproperty(:ensure, :parent => Puppet::Property::Ensure) do
        newvalue(:present) { provider.create }
        newvalue(:absent) { provider.destroy }

        def insync?(value)
          if value == :present
            provider.exists?
          else
            ! provider.exists?
          end
        end
      end

      newproperty(:foo) do
        desc "A property that can be changed successfully"
        def retrieve
          :absent
        end

        def insync?(reference_value)
          false
        end
      end

      newproperty(:bar) do
        desc "A property that raises an exception when you try to change it"
        def retrieve
          :absent
        end

        def insync?(reference_value)
          false
        end
      end
    end

    @provider_class = @resource_type.provide :harness_test_provider do
      attr_accessor :foo, :bar

      def create
        @present = true
      end

      def destroy
        @present = false
      end

      def exists?
        if @present
          true
        else
          false
        end
      end
    end
  end

  after { Puppet::Type.rmtype(:harness_test_type) }

  before do
    @transaction = Puppet::Transaction.new(Puppet::Resource::Catalog.new)
    @resource = Puppet::Type.type(:harness_test_type).new :name => "/my/file"
    @harness = Puppet::Transaction::ResourceHarness.new(@transaction)
    @current_state = Puppet::Resource.new(:file, "/my/file")
    @resource.stubs(:retrieve).returns @current_state
    @status = Puppet::Resource::Status.new(@resource)
    Puppet::Resource::Status.stubs(:new).returns @status
  end

  it "should accept a transaction at initialization" do
    harness = Puppet::Transaction::ResourceHarness.new(@transaction)
    harness.transaction.should equal(@transaction)
  end

  it "should delegate to the transaction for its relationship graph" do
    @transaction.expects(:relationship_graph).returns "relgraph"
    Puppet::Transaction::ResourceHarness.new(@transaction).relationship_graph.should == "relgraph"
  end

  describe "when evaluating a resource" do
    it "should create and return a resource status instance for the resource" do
      @harness.evaluate(@resource).should be_instance_of(Puppet::Resource::Status)
    end

    it "should fail if no status can be created" do
      Puppet::Resource::Status.expects(:new).raises ArgumentError

      lambda { @harness.evaluate(@resource) }.should raise_error
    end

    it "should retrieve the current state of the resource" do
      @resource.expects(:retrieve).returns @current_state
      @harness.evaluate(@resource)
    end

    it "should mark the resource as failed and return if the current state cannot be retrieved" do
      @resource.expects(:retrieve).raises ArgumentError
      @harness.evaluate(@resource).should be_failed
    end

    it "should store the resource's evaluation time in the resource status" do
      @harness.evaluate(@resource).evaluation_time.should be_instance_of(Float)
    end
  end

  def events_to_hash(events)
    events.map do |event|
      hash = {}
      event.instance_variables.each do |varname|
        hash[varname] = event.instance_variable_get(varname.to_sym)
      end
      hash
    end
  end

  describe "when an error occurs" do
    before :each do
      resource = @resource_type.new :name => 'name', :ensure => :present, :foo => 1, :bar => 2

      # So there's no ensure event
      resource.provider.create
      resource.expects(:err).never
      resource.provider.expects(:bar=).raises ArgumentError

      @status = @harness.evaluate(resource)
    end

    it "should record previous successful events" do
      event = @status.events.find { |e| e.property == "foo" }
      event.should be_instance_of(Puppet::Transaction::Event)
      event.status.should == "success"
    end

    it "should record a failure event" do
      event = @status.events.find { |e| e.property == "bar" }
      event.should be_instance_of(Puppet::Transaction::Event)
      event.status.should == "failure"
    end
  end

  describe "when auditing" do
    it "should not call insync? on parameters that are merely audited" do
      resource = @resource_type.new :name => 'name', :audit => ['foo']
      resource.property(:foo).expects(:insync?).never
      status = @harness.evaluate(resource)
      status.events.each do |event|
        event.status.should != 'failure'
      end
    end

    it "should be able to audit a file's group" do # see bug #5710
      test_file = tmpfile('foo')
      File.open(test_file, 'w').close
      resource = Puppet::Type.type(:file).new :path => test_file, :audit => ['group'], :backup => false
      resource.expects(:err).never # make sure no exceptions get swallowed
      status = @harness.evaluate(resource)
      status.events.each do |event|
        event.status.should != 'failure'
      end
    end
  end

  describe "when applying changes" do
    count = 0
    [false, true].each do |noop_mode|; describe (noop_mode ? "in noop mode" : "in normal mode") do
      before { @noop_mode = noop_mode }
      [nil, 'foo1'].each do |machine_state|; describe (machine_state ? "with a resource initially present" : "with no resource initially present") do
        before { @machine_state = machine_state }
        [nil, 'foo1', 'foo2'].each do |yaml_foo|
          before { @yaml_foo = yaml_foo }
          [nil, :present, :absent].each do |yaml_ensure|; describe "with cached foo=#{yaml_foo.inspect} and ensure=#{yaml_ensure.inspect} stored in state.yml" do
            before { @yaml_ensure = yaml_ensure }
            [false, true].each do |auditing_ensure|
              before { @auditing_ensure = auditing_ensure }
              [false, true].each do |auditing_foo|
                before { @auditing_foo = auditing_foo }
                auditing = []
                auditing.push(:foo) if auditing_foo
                auditing.push(:ensure) if auditing_ensure
                [nil, :present, :absent].each do |ensure_property| # what we set "ensure" to in the manifest
                  before { @ensure_property = ensure_property }
                  [nil, 'foo1', 'foo2'].each do |foo_property| # what we set "foo" to in the manifest
                    before { @foo_property = foo_property }
                    manifest_settings = {}
                    manifest_settings[:audit] = auditing if !auditing.empty?
                    manifest_settings[:ensure] = ensure_property if ensure_property
                    manifest_settings[:foo] = foo_property if foo_property
                    describe "with manifest settings #{manifest_settings.inspect}" do
                      before do
                        count += 1
                        name = "/random/chars#{count}"
                        params = manifest_settings.merge({:name => name})
                        @resource = Puppet::Type.type(:harness_test_type).new params

                        # Set up preconditions
                        if machine_state
                          # This is just a stub, so mark the stub so it will claim it exists and set the 'foo' value
                          @resource.provider.create
                          @resource.provider.foo = machine_state
                        end

                        Puppet[:noop] = noop_mode

                        @harness.cache(@resource, :foo, yaml_foo) if yaml_foo
                        @harness.cache(@resource, :ensure, yaml_ensure) if yaml_ensure

                        fake_time = Time.utc(2011, 'jan', 3, 12, 24, 0)
                        Time.stubs(:now).returns(fake_time) # So that Puppet::Resource::Status objects will compare properly
                        @resource.expects(:err).never # make sure no exceptions get swallowed
                        # end of preconditions

                        @status = @harness.evaluate(@resource) # do the thing
                      end

                      def started_present?
                        @machine_state != nil
                      end

                      def resource_would_be_there_if_not_noop?
                        if @ensure_property == :present
                          true
                        elsif @ensure_property == nil
                          started_present?
                        else # ensure_property == :absent
                          false
                        end
                      end

                      def resource_should_be_there?
                        @noop_mode ? started_present? : resource_would_be_there_if_not_noop?
                      end

                      def expected_resource_foo?
                        if @noop_mode
                          @machine_state
                        else
                          @foo_property || @machine_state
                        end
                      end

                      def synced_should_be_set?
                        !@noop_mode && @status.changed
                      end

                      it "should create the resource, or not, as appropriate" do
                        @resource.provider.exists?.should == resource_should_be_there?
                      end

                      it "should cache data appropraiately" do
                        if auditing_foo
                          @harness.cached(@resource, :foo).should == (machine_state || :absent)
                        else
                          @harness.cached(@resource, :foo).should == yaml_foo
                        end
                        if auditing_ensure
                          @harness.cached(@resource, :ensure).should == (machine_state ? :present : :absent)
                        else
                          @harness.cached(@resource, :ensure).should == yaml_ensure
                        end
                      end

                      it "should set non-ensure states appropriately" do
                        # check that the state of the machine has been properly updated
                        if resource_should_be_there?
                          if !expected_resource_foo?
                            # we didn't specify a foo and the resource was created, so foo comes from the set state in the provider
                          else
                            @resource.provider.foo.should == expected_resource_foo?
                          end
                        end
                      end

                      it "should correctly cache whether the resource was synced" do
                        # Check the :synced field on state.yml
                        (@harness.cached(@resource, :synced) != nil).should == synced_should_be_set?
                      end

                      it "should behave properly" do
                        # Test log output for the "foo" parameter
                        previously_recorded_foo_already_logged = false
                        foo_status_msg = nil

                        expected_logs = []
                        if machine_state && resource_would_be_there_if_not_noop? && foo_property && (machine_state != foo_property)
                          if noop_mode
                            what_happened = "current_value #{machine_state}, should be #{foo_property} (noop)"
                            expected_status = 'noop'
                          else
                            what_happened = "foo changed '#{machine_state}' to '#{foo_property}'"
                            expected_status = 'success'
                          end
                          if auditing_foo && yaml_foo && yaml_foo != machine_state
                            previously_recorded_foo_already_logged = true
                            foo_status_msg = "#{what_happened} (previously recorded value was #{yaml_foo})"
                          else
                            foo_status_msg = what_happened
                          end
                          expected_logs << "notice: /#{@resource}/foo: #{foo_status_msg}"
                        end
                        if @harness.cached(@resource, :foo) && @harness.cached(@resource, :foo) != yaml_foo
                          if yaml_foo
                            unless previously_recorded_foo_already_logged
                              foo_status_msg = "audit change: previously recorded value #{yaml_foo} has been changed to #{@harness.cached(@resource, :foo)}"
                              expected_logs << "notice: /#{@resource}/foo: #{foo_status_msg}"
                              expected_status = 'audit'
                            end
                          else
                            expected_logs << "notice: /#{@resource}/foo: audit change: newly-recorded value #{@harness.cached(@resource, :foo)}"
                          end
                        end
                        expected_status_events = []
                        if foo_status_msg
                          expected_status_events << Puppet::Transaction::Event.new(
                              :source_description => "/#{@resource}/foo", :resource => @resource, :file => nil,
                              :line => nil, :tags => %w{harness_test_type}, :desired_value => foo_property,
                              :historical_value => yaml_foo, :message => foo_status_msg, :name => :foo_changed,
                              :previous_value => machine_state || :absent, :property => :foo, :status => expected_status,
                              :audited => auditing_foo)
                        end

                        # Test log output for the "ensure" parameter
                        previously_recorded_ensure_already_logged = false
                        ensure_status_msg = nil
                        if resource_would_be_there_if_not_noop? != (started_present?)
                          if noop_mode
                            what_happened = "current_value #{machine_state ? 'present' : 'absent'}, should be #{resource_would_be_there_if_not_noop? ? 'present' : 'absent'} (noop)"
                            expected_status = 'noop'
                          else
                            what_happened = resource_would_be_there_if_not_noop? ? 'created' : 'removed'
                            expected_status = 'success'
                          end
                          if auditing_ensure && yaml_ensure && yaml_ensure != (machine_state ? :present : :absent)
                            previously_recorded_ensure_already_logged = true
                            ensure_status_msg = "#{what_happened} (previously recorded value was #{yaml_ensure})"
                          else
                            ensure_status_msg = "#{what_happened}"
                          end
                          expected_logs << "notice: /#{@resource}/ensure: #{ensure_status_msg}"
                        end
                        if @harness.cached(@resource, :ensure) && @harness.cached(@resource, :ensure) != yaml_ensure
                          if yaml_ensure
                            unless previously_recorded_ensure_already_logged
                              ensure_status_msg = "audit change: previously recorded value #{yaml_ensure} has been changed to #{@harness.cached(@resource, :ensure)}"
                              expected_logs << "notice: /#{@resource}/ensure: #{ensure_status_msg}"
                              expected_status = 'audit'
                            end
                          else
                            expected_logs << "notice: /#{@resource}/ensure: audit change: newly-recorded value #{@harness.cached(@resource, :ensure)}"
                          end
                        end
                        if ensure_status_msg
                          if ensure_property == :present
                            ensure_event_name = :harness_test_type_created
                          elsif ensure_property == nil
                            ensure_event_name = :harness_test_type_changed
                          else # ensure_property == :absent
                            ensure_event_name = :harness_test_type_removed
                          end
                          expected_status_events << Puppet::Transaction::Event.new(
                              :source_description => "/#{@resource}/ensure", :resource => @resource, :file => nil,
                              :line => nil, :tags => %w{harness_test_type}, :desired_value => ensure_property,
                              :historical_value => yaml_ensure, :message => ensure_status_msg, :name => ensure_event_name,
                              :previous_value => machine_state ? :present : :absent, :property => :ensure,
                              :status => expected_status, :audited => auditing_ensure)
                        end

                        # Actually check the logs.
                        @logs.map {|l| "#{l.level}: #{l.source}: #{l.message}"}.should =~ expected_logs

                        # All the log messages should show up as events except the "newly-recorded" ones.
                        expected_event_logs = @logs.reject {|l| l.message =~ /newly-recorded/ }
                        @status.events.map {|e| e.message}.should =~ expected_event_logs.map {|l| l.message }
                        events_to_hash(@status.events).should =~ events_to_hash(expected_status_events)

                        # Check change count - this is the number of changes that actually occurred.
                        expected_change_count = 0
                        if (started_present?) != resource_should_be_there?
                          expected_change_count = 1
                        elsif started_present?
                          if expected_resource_foo? != machine_state
                            expected_change_count = 1
                          end
                        end
                        @status.change_count.should == expected_change_count

                        # Check out of sync count - this is the number
                        # of changes that would have occurred in
                        # non-noop mode.
                        expected_out_of_sync_count = 0
                        if (started_present?) != resource_would_be_there_if_not_noop?
                          expected_out_of_sync_count = 1
                        elsif started_present?
                          if foo_property != nil && foo_property != machine_state
                            expected_out_of_sync_count = 1
                          end
                        end
                        if !noop_mode
                          expected_out_of_sync_count.should == expected_change_count
                        end
                        @status.out_of_sync_count.should == expected_out_of_sync_count

                        # Check legacy summary fields
                        @status.changed.should == (expected_change_count != 0)
                        @status.out_of_sync.should == (expected_out_of_sync_count != 0)
                      end
                    end
                  end
                end
              end
            end
          end; end
        end
      end; end
    end; end

    it "should not apply changes if allow_changes?() returns false" do
      test_file = tmpfile('foo')
      resource = Puppet::Type.type(:file).new :path => test_file, :backup => false, :ensure => :file
      resource.expects(:err).never # make sure no exceptions get swallowed
      @harness.expects(:allow_changes?).with(resource).returns false
      status = @harness.evaluate(resource)
      File.exists?(test_file).should == false
    end
  end

  describe "when determining whether the resource can be changed" do
    before do
      @resource.stubs(:purging?).returns true
      @resource.stubs(:deleting?).returns true
    end

    it "should be true if the resource is not being purged" do
      @resource.expects(:purging?).returns false
      @harness.should be_allow_changes(@resource)
    end

    it "should be true if the resource is not being deleted" do
      @resource.expects(:deleting?).returns false
      @harness.should be_allow_changes(@resource)
    end

    it "should be true if the resource has no dependents" do
      @harness.relationship_graph.expects(:dependents).with(@resource).returns []
      @harness.should be_allow_changes(@resource)
    end

    it "should be true if all dependents are being deleted" do
      dep = stub 'dependent', :deleting? => true
      @harness.relationship_graph.expects(:dependents).with(@resource).returns [dep]
      @resource.expects(:purging?).returns true
      @harness.should be_allow_changes(@resource)
    end

    it "should be false if the resource's dependents are not being deleted" do
      dep = stub 'dependent', :deleting? => false, :ref => "myres"
      @resource.expects(:warning)
      @harness.relationship_graph.expects(:dependents).with(@resource).returns [dep]
      @harness.should_not be_allow_changes(@resource)
    end
  end

  describe "when finding the schedule" do
    before do
      @catalog = Puppet::Resource::Catalog.new
      @resource.catalog = @catalog
    end

    it "should warn and return nil if the resource has no catalog" do
      @resource.catalog = nil
      @resource.expects(:warning)

      @harness.schedule(@resource).should be_nil
    end

    it "should return nil if the resource specifies no schedule" do
      @harness.schedule(@resource).should be_nil
    end

    it "should fail if the named schedule cannot be found" do
      @resource[:schedule] = "whatever"
      @resource.expects(:fail)
      @harness.schedule(@resource)
    end

    it "should return the named schedule if it exists" do
      sched = Puppet::Type.type(:schedule).new(:name => "sched")
      @catalog.add_resource(sched)
      @resource[:schedule] = "sched"
      @harness.schedule(@resource).to_s.should == sched.to_s
    end
  end

  describe "when determining if a resource is scheduled" do
    before do
      @catalog = Puppet::Resource::Catalog.new
      @resource.catalog = @catalog
      @status = Puppet::Resource::Status.new(@resource)
    end

    it "should return true if 'ignoreschedules' is set" do
      Puppet[:ignoreschedules] = true
      @resource[:schedule] = "meh"
      @harness.should be_scheduled(@status, @resource)
    end

    it "should return true if the resource has no schedule set" do
      @harness.should be_scheduled(@status, @resource)
    end

    it "should return the result of matching the schedule with the cached 'checked' time if a schedule is set" do
      t = Time.now
      @harness.expects(:cached).with(@resource, :checked).returns(t)

      sched = Puppet::Type.type(:schedule).new(:name => "sched")
      @catalog.add_resource(sched)
      @resource[:schedule] = "sched"

      sched.expects(:match?).with(t.to_i).returns "feh"

      @harness.scheduled?(@status, @resource).should == "feh"
    end
  end

  it "should be able to cache data in the Storage module" do
    data = {}
    Puppet::Util::Storage.expects(:cache).with(@resource).returns data
    @harness.cache(@resource, :foo, "something")

    data[:foo].should == "something"
  end

  it "should be able to retrieve data from the cache" do
    data = {:foo => "other"}
    Puppet::Util::Storage.expects(:cache).with(@resource).returns data
    @harness.cached(@resource, :foo).should == "other"
  end

  describe "when setting a value" do
    before do
      @property = @resource.parameter(:mode)
      @class = Class.new(Puppet::Property) do
        @name = :foo
      end
      @class.initvars
      @resource = Puppet::Type.type(:mount).new :name => "/foo"
      @provider = @resource.provider
      @property = @class.new :resource => @resource
    end

    it "should catch exceptions and raise Puppet::Error" do
      @class.newvalue(:foo) { raise "eh" }
      lambda { @property.set(:foo) }.should raise_error(Puppet::Error)
    end

    describe "that was defined without a block" do
      it "should call the settor on the provider" do
        @class.newvalue(:bar)
        @provider.expects(:foo=).with :bar
        @property.set(:bar)
      end
    end

    describe "that was defined with a block" do
      it "should call the method created for the value if the value is not a regex" do
        @class.newvalue(:bar) {}
        @property.expects(:set_bar)
        @property.set(:bar)
      end

      it "should call the provided block if the value is a regex" do
        @class.newvalue(/./) { self.test }
        @property.expects(:test)
        @property.set("foo")
      end
    end
  end
end
