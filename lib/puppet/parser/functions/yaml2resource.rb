require 'yaml'
require 'puppet/parser/catalog_helper'

Puppet::Parser::Functions::newfunction(:yaml2resource, :type => :statement,
    :doc => "Provided a yaml file containing a hash, reads the file in and turns it into a resource.
An example yaml file is::

    --- 
    title: /tmp/myfile
    mode: \"755\"
    type: file
    content: othercontent
    ensure: present

And to use, store this yaml in a file (e.g., /tmp/resource.yaml), and call like so::

    yaml2resource(\"/tmp/resource.yaml\")

") do |vals|
    file = vals[0]
    raise ArgumentError, "Could not find file '%s'" % file unless FileTest.exist?(file)


    begin
        hash = YAML.load_file(file)
    rescue => detail
        raise "Could not convert file contents from %s to yaml: %s" % [file, detail]
    end

    Puppet::Parser::CatalogHelper.create_resource_from_hash(self, hash)
end
