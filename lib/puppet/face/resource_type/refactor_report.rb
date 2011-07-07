Puppet::Face.define(:resource_type, "current") do
  action :refactor_report do
    summary "Report on the status of the refactor"
#    arguments ""
#    returns <<-'EOT'
#      A list of resource references ("Type[title]"). When used from the API,
#      returns an array of Puppet::Resource objects excised from a catalog.
#    EOT
#    description <<-'EOT'
#      Retrieves a catalog for the specified host, then searches it for all
#      resources of the requested type.
#    EOT
#    notes <<-'NOTES'
#      By default, this action will retrieve a catalog from Puppet's compiler
#      subsystem; you must call the action with `--terminus rest` if you wish
#      to retrieve a catalog from the puppet master.
#
#      FORMATTING ISSUES: This action cannot currently render useful yaml;
#      instead, it returns an entire catalog. Use json instead.
#    NOTES
#    examples <<-'EOT'
#      Ask the puppet master for a list of managed file resources for a node:
#
#      $ puppet catalog select --terminus rest somenode.magpie.lan file
#    EOT
    when_invoked do
      total = {}

      Puppet::Type.loadall
      Puppet::Type.eachtype do |type|
        hash = total[type.name.to_s] = {}
        hash[:values] = []
        type.properties.each do |property|
          # XXX We're losing the property information here
          if property.instance_methods.include?("sync")
            hash[:sync] = true
          end

          if values = property.value_collection.values
            values.each do |value|
              if property.value_option(value, :call) == :instead
                hash[:values]<< value.to_s
              end
            end
          end
        end
      end
      total
    end

    when_rendering :console do |total|
      result = ""
      total.sort { |a,b| a[0] <=> b[0] }.each do |type, hash|
        unless hash[:sync] or hash[:values]
          result << "-----> #{type} is good\n"
          next
        end

        result << "#{type}: sync? #{hash[:sync]} values: #{hash[:values].join(", ")}\n"
      end
      result
    end
  end
end
