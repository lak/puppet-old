require 'puppet/resource/status'

class Puppet::Transaction::ResourceHarness
  extend Forwardable
  def_delegators :@transaction, :relationship_graph

  attr_reader :transaction

  def allow_changes?(resource)
    if resource.purging? and resource.deleting? and deps = relationship_graph.dependents(resource) \
            and ! deps.empty? and deps.detect { |d| ! d.deleting? }
      deplabel = deps.collect { |r| r.ref }.join(",")
      plurality = deps.length > 1 ? "":"s"
      resource.warning "#{deplabel} still depend#{plurality} on me -- not purging"
      false
    else
      true
    end
  end

  # Used mostly for scheduling and auditing at this point.
  def cached(resource, name)
    Puppet::Util::Storage.cache(resource)[name]
  end

  # Used mostly for scheduling and auditing at this point.
  def cache(resource, name, value)
    Puppet::Util::Storage.cache(resource)[name] = value
  end

  def perform_changes(resource)
    current = resource.retrieve_resource

    cache resource, :checked, Time.now

    return [] if ! allow_changes?(resource)

    current_values = current.to_hash
    historical_values = Puppet::Util::Storage.cache(resource).dup
    synced_params = []

    # Record the current state in state.yml.
    audited_params = cache_current_state(resource, current_values)

    # Update the machine state & create logs/events
    synced_params, events = update_machine_state(resource, current_values, historical_values, audited_params)

    # Add more events to capture audit results
    events += capture_audit_results(resource, audited_params, historical_values, current_values, synced_params)

    events
  end

  def create_change_event(property, current_value, do_audit, historical_value)
    event = property.event
    event.previous_value = current_value
    event.desired_value = property.should
    event.historical_value = historical_value

    if do_audit
      event.audited = true
      event.status = "audit"
      if historical_value != current_value
        event.message = "audit change: previously recorded value #{property.is_to_s(historical_value)} has been changed to #{property.is_to_s(current_value)}"
      end
    end

    event
  end

  def apply_parameter(property, current_value, do_audit, historical_value)
    event = create_change_event(property, current_value, do_audit, historical_value)

    if do_audit && historical_value && historical_value != current_value
      brief_audit_message = " (previously recorded value was #{property.is_to_s(historical_value)})"
    else
      brief_audit_message = ""
    end

    if property.noop
      event.message = "current_value #{property.is_to_s(current_value)}, should be #{property.should_to_s(property.should)} (noop)#{brief_audit_message}"
      event.status = "noop"
    else
      set_value(property)
      event.message = [ property.change_to_s(current_value, property.should), brief_audit_message ].join
      event.status = "success"
    end
    event
  rescue => detail
    puts detail.backtrace
    puts detail.backtrace if Puppet[:trace]
    event.status = "failure"

    event.message = "change from #{property.is_to_s(current_value)} to #{property.should_to_s(property.should)} failed: #{detail}"
    event
  ensure
    event.send_log
  end

  # This is the only truly "public" method on this class - it's the entry
  # point for all work.
  def evaluate(resource)
    start = Time.now
    status = Puppet::Resource::Status.new(resource)

    perform_changes(resource).each do |event|
      status << event
    end

    if status.changed? && ! resource.noop?
      cache(resource, :synced, Time.now)
      resource.flush if resource.respond_to?(:flush)
    end

    return status
  rescue => detail
    resource.fail "Could not create resource status: #{detail}" unless status
    puts detail.backtrace
    puts detail.backtrace if Puppet[:trace]
    resource.err "Could not evaluate: #{detail}"
    status.failed = true
    return status
  ensure
    (status.evaluation_time = Time.now - start) if status
  end

  def initialize(transaction)
    @transaction = transaction
  end

  def scheduled?(status, resource)
    return true if Puppet[:ignoreschedules]
    return true unless schedule = schedule(resource)

    # We use 'checked' here instead of 'synced' because otherwise we'll
    # end up checking most resources most times, because they will generally
    # have been synced a long time ago (e.g., a file only gets updated
    # once a month on the server and its schedule is daily; the last sync time
    # will have been a month ago, so we'd end up checking every run).
    schedule.match?(cached(resource, :checked).to_i)
  end

  def schedule(resource)
    unless resource.catalog
      resource.warning "Cannot schedule without a schedule-containing catalog"
      return nil
    end

    return nil unless name = resource[:schedule]
    resource.catalog.resource(:schedule, name) || resource.fail("Could not find schedule #{name}")
  end

  private

  def cache_current_state(resource, current_values)
    audited_params = (resource[:audit] || []).map { |p| p.to_sym }
    audited_params.each do |param|
      cache(resource, param, current_values[param])
    end
    audited_params
  end

  def update_machine_state(resource, current_values, historical_values, audited_params)
    events = []
    synced_params = []
    ensure_param = resource.parameter(:ensure)
    if ensure_param and resource[:ensure] && !ensure_param.safe_insync?(current_values[:ensure])
      events << apply_parameter(ensure_param, current_values[:ensure], audited_params.include?(:ensure), historical_values[:ensure])
      synced_params << :ensure
    elsif current_values[:ensure] != :absent
      work_order = resource.properties # Note: only the resource knows what order to apply changes in
      work_order.each do |param|
        if resource[param.name] && !param.safe_insync?(current_values[param.name])
          events << apply_parameter(param, current_values[param.name], audited_params.include?(param.name), historical_values[param.name])
          synced_params << param.name
        end
      end
    end
    return [synced_params, events]
  end

  def capture_audit_results(resource, audited_params, historical_values, current_values, synced_params)
    events = []
    audited_params.each do |param_name|
      if historical_values.include?(param_name)
        if historical_values[param_name] != current_values[param_name] && !synced_params.include?(param_name)
          event = create_change_event(resource.parameter(param_name), current_values[param_name], true, historical_values[param_name])
          event.send_log
          events << event
        end
      else
        resource.property(param_name).notice "audit change: newly-recorded value #{current_values[param_name]}"
      end
    end
    events
  end

  # Set our value, using the provider, an associated block, or both.
  def set_value(property)
    value = property.should
    # Set a name for looking up associated options like the event.
    name = property.class.value_name(value)

    call = property.class.value_option(name, :call) || :none

    if call == :instead
      property.call_valuemethod(name, value)
    else
      # They haven't provided a block, and our parent does not have
      # a provider, so we have no idea how to handle this.
      property.fail "#{property.class.name} cannot handle values of type #{value.inspect}" unless property.resource.provider
      call_provider(property, value)
    end
  end

  def call_provider(property, value)
      provider = property.resource.provider
      provider.send(property.class.name.to_s + "=", value)
  rescue NoMethodError
      property.fail "The #{provider.class.name} provider can not handle attribute #{property.class.name}"
  end
end
