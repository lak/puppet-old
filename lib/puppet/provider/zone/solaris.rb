Puppet::Type.type(:zone).provide(:solaris) do
  desc "Provider for Solaris Zones."

  commands :adm => "/usr/sbin/zoneadm", :cfg => "/usr/sbin/zonecfg"
  defaultfor :operatingsystem => :solaris

  mk_resource_methods

  # Convert the output of a list into a hash
  def self.line2hash(line)
    fields = [:id, :name, :ensure, :path]

    properties = {}
    line.split(":").each_with_index { |value, index|
      next unless fields[index]
      properties[fields[index]] = value
    }

    # Configured but not installed zones do not have IDs
    properties.delete(:id) if properties[:id] == "-"

    properties[:ensure] = symbolize(properties[:ensure])

    properties
  end

  def self.instances
    # LAK:NOTE See http://snurl.com/21zf8  [groups_google_com]
    x = adm(:list, "-cp").split("\n").collect do |line|
      new(line2hash(line))
    end
  end

  # Perform all of our configuration steps.
  def configure
    # If the thing is entirely absent, then we need to create the config.
    # Is there someway to get this on one line?
    str = "create -b #{@resource[:create_args]}\nset zonepath=#{@resource[:path]}\n"

    # Then perform all of our configuration steps.  It's annoying
    # that we need this much internal info on the resource.
    @resource.send(:properties).each do |property|
      str += property.configtext + "\n" if property.is_a? ZoneConfigProperty and ! property.safe_insync?(properties[property.name])
    end

    str += "commit\n"
    setconfig(str)
  end

  def destroy
    zonecfg :delete, "-F"
  end

  def exists?
    properties[:ensure] != :absent
  end

  # Clear out the cached values.
  def flush
    @property_hash.clear
  end

  def install(dummy_argument=:work_arround_for_ruby_GC_bug)
    if @resource[:clone] # TODO: add support for "-s snapshot"
      zoneadm :clone, @resource[:clone]
    elsif @resource[:install_args]
      zoneadm :install, @resource[:install_args].split(" ")
    else
      zoneadm :install
    end
  end

  # Look up the current status.
  def properties
    if @property_hash.empty?
      @property_hash = status || {}
      if @property_hash.empty?
        @property_hash[:ensure] = :absent
      else
        @resource.class.property_names.each do |name|
          @property_hash[name] ||= :absent
        end
      end

    end
    @property_hash.dup
  end

  # We need a way to test whether a zone is in process.  Our 'ensure'
  # property models the static states, but we need to handle the temporary ones.
  def processing?
    if hash = status
      case hash[:ensure]
      when "incomplete", "ready", "shutting_down"
        true
      else
        false
      end
    else
      false
    end
  end

  # Collect the configuration of the zone.
  def getconfig
    output = zonecfg :info

    name = nil
    current = nil
    hash = {}
    output.split("\n").each do |line|
      case line
      when /^(\S+):\s*$/
        name = $1
        current = nil # reset it
      when /^(\S+):\s*(.+)$/
        hash[$1.intern] = $2
      when /^\s+(\S+):\s*(.+)$/
        if name
          hash[name] = [] unless hash.include? name

          unless current
            current = {}
            hash[name] << current
          end
          current[$1.intern] = $2
        else
          err "Ignoring '#{line}'"
        end
      else
        debug "Ignoring zone output '#{line}'"
      end
    end

    hash
  end

  # Execute a configuration string.  Can't be private because it's called
  # by the properties.
  def setconfig(str)
    command = "#{command(:cfg)} -z #{@resource[:name]} -f -"
    debug "Executing '#{command}' in zone #{@resource[:name]} with '#{str}'"
    IO.popen(command, "w") do |pipe|
      pipe.puts str
    end

    unless $CHILD_STATUS == 0
      raise ArgumentError, "Failed to apply configuration"
    end
  end

  def start
    # Check the sysidcfg stuff
    if cfg = @resource[:sysidcfg]
      zoneetc = File.join(@resource[:path], "root", "etc")
      sysidcfg = File.join(zoneetc, "sysidcfg")

      # if the zone root isn't present "ready" the zone
      # which makes zoneadmd mount the zone root
      zoneadm :ready unless File.directory?(zoneetc)

      unless File.exists?(sysidcfg)
        begin
          File.open(sysidcfg, "w", 0600) do |f|
            f.puts cfg
          end
        rescue => detail
          puts detail.stacktrace if Puppet[:debug]
          raise Puppet::Error, "Could not create sysidcfg: #{detail}"
        end
      end
    end

    zoneadm :boot
  end

  # Return a hash of the current status of this zone.
  def status
    begin
      output = adm "-z", @resource[:name], :list, "-p"
    rescue Puppet::ExecutionFailure
      return nil
    end

    main = self.class.line2hash(output.chomp)

    # Now add in the configuration information
    config_status.each do |name, value|
      main[name] = value
    end

    main
  end

  def ready
    zoneadm :ready
  end

  def stop
    zoneadm :halt
  end

  def unconfigure
    zonecfg :delete, "-F"
  end

  def uninstall
    zoneadm :uninstall, "-F"
  end

  private

  # Turn the results of getconfig into status information.
  def config_status
    config = getconfig
    result = {}

    result[:autoboot] = config[:autoboot] ? config[:autoboot].intern : :absent
    result[:pool] = config[:pool]
    result[:shares] = config[:shares]
    if dir = config["inherit-pkg-dir"]
      result[:inherit] = dir.collect { |dirs| dirs[:dir] }
    end
    if datasets = config["dataset"]
      result[:dataset] = datasets.collect { |dataset| dataset[:name] }
    end
    result[:iptype] = config[:"ip-type"]
    if net = config["net"]
      result[:ip] = net.collect do |params|
        if params[:defrouter]
          "#{params[:physical]}:#{params[:address]}:#{params[:defrouter]}"
        elsif params[:address]
          "#{params[:physical]}:#{params[:address]}"
        else
          params[:physical]
        end
      end
    end

    result
  end

  def zoneadm(*cmd)
      adm("-z", @resource[:name], *cmd)
  rescue Puppet::ExecutionFailure => detail
      self.fail "Could not #{cmd[0]} zone: #{detail}"
  end

  def zonecfg(*cmd)
    # You apparently can't get the configuration of the global zone
    return "" if self.name == "global"

    begin
      cfg("-z", self.name, *cmd)
    rescue Puppet::ExecutionFailure => detail
      self.fail "Could not #{cmd[0]} zone: #{detail}"
    end
  end
end

