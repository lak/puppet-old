#  Created by Jeff McCune on 2007-07-22
#  Copyright (c) 2007. All rights reserved.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation (version 2 of the License)
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston MA  02110-1301 USA

require 'puppet'
require 'puppet/provider/nameservice'
require 'facter/util/plist'

class Puppet::Provider::NameService
class DirectoryService < Puppet::Provider::NameService
    # JJM: Dive into the eigenclass
    class << self
        # JJM: This allows us to pass information when calling
        #      Puppet::Type.type
        #  e.g. Puppet::Type.type(:user).provide :directoryservice, :ds_path => "Users"
        #  This is referenced in the get_ds_path class method
        attr_writer :ds_path
    end

    # JJM 2007-07-24: Not yet sure what initvars() does.  I saw it in netinfo.rb
    # I do know, however, that it makes methods "work"  =)
    # e.g. addcmd isn't available if this method call isn't present.
    #
    # JJM: Also, where this method is defined seems to impact the visibility
    #   of methods.  If I put initvars after commands, confine and defaultfor,
    #   then getinfo is called from the parent class, not this class.
    initvars()
    
    commands :dscl => "/usr/bin/dscl"
    confine :operatingsystem => :darwin
    defaultfor :operatingsystem => :darwin


    # JJM 2007-07-25: This map is used to map NameService attributes to their
    #     corresponding DirectoryService attribute names.
    #     See: http://images.apple.com/server/docs/Open_Directory_v10.4.pdf
    # JJM: Note, this is de-coupled from the Puppet::Type, and must
    #     be actively maintained.  There may also be collisions with different
    #     types (Users, Groups, Mounts, Hosts, etc...)
    @@ds_to_ns_attribute_map = {
        'RecordName' => :name,
        'PrimaryGroupID' => :gid,
        'NFSHomeDirectory' => :home,
        'UserShell' => :shell,
        'UniqueID' => :uid,
        'RealName' => :comment,
        'Password' => :password,
        'GeneratedUID' => :guid,
    }
    # JJM The same table as above, inverted.
    @@ns_to_ds_attribute_map = {
        :name => 'RecordName',
        :gid => 'PrimaryGroupID',
        :home => 'NFSHomeDirectory',
        :shell => 'UserShell',
        :uid => 'UniqueID',
        :comment => 'RealName',
        :password => 'Password',
        :guid => 'GeneratedUID',
    }
    
    @@password_hash_dir = "/var/db/shadow/hash"
    
    def self.instances
        # JJM Class method that provides an array of instance objects of this
        #     type.
        # JJM: Properties are dependent on the Puppet::Type we're managine.
        type_property_array = [:name] + @resource_type.validproperties
        
        # Create a new instance of this Puppet::Type for each object present
        #    on the system.
        list_all_present.collect do |name_string|
            self.new(single_report(name_string, *type_property_array))
        end
    end
    
    def self.get_ds_path
        # JJM: 2007-07-24 This method dynamically returns the DS path we're concerned with.
        #      For example, if we're working with an user type, this will be /Users
        #      with a group type, this will be /Groups.
        #   @ds_path is an attribute of the class itself.  
        if defined? @ds_path
            return @ds_path
        else
            # JJM: "Users" or "Groups" etc ...  (Based on the Puppet::Type)
            #       Remember this is a class method, so self.class is Class
            #       Also, @resource_type seems to be the reference to the
            #       Puppet::Type this class object is providing for.
            return @resource_type.name.to_s.capitalize + "s"
        end
    end

    def self.list_all_present
        # JJM: List all objects of this Puppet::Type already present on the system.
        begin
            dscl_output = execute(get_exec_preamble("-list"))
        rescue Puppet::ExecutionFailure => detail
            raise Puppet::Error, "Could not get %s list from DirectoryService" % [ @resource_type.name.to_s ]
        end
        return dscl_output.split("\n")
    end
    
    def self.single_report(resource_name, *type_properties)
        # JJM 2007-07-24:
        #     Given a the name of an object and a list of properties of that
        #     object, return all property values in a hash.
        #     
        #     This class method returns nil if the object doesn't exist
        #     Otherwise, it returns a hash of the object properties.
        
        all_present_str_array = list_all_present()
        
        # NBK: shortcut the process if the resource is missing
        return nil unless all_present_str_array.include? resource_name
        
        dscl_vector = get_exec_preamble("-read", resource_name)
        begin
            dscl_output = execute(dscl_vector)
        rescue Puppet::ExecutionFailure => detail
            raise Puppet::Error, "Could not get report.  command execution failed."
        end
        
        # JJM: We need a new hash to return back to our caller.
        attribute_hash = Hash.new
        
        dscl_plist = Plist.parse_xml(dscl_output)
        dscl_plist.keys().each do |key|
            ds_attribute = key.sub("dsAttrTypeStandard:", "")
            next unless (@@ds_to_ns_attribute_map.keys.include?(ds_attribute) and type_properties.include? @@ds_to_ns_attribute_map[ds_attribute])
            ds_value = dscl_plist[key][0]  # only care about the first entry...
            attribute_hash[@@ds_to_ns_attribute_map[ds_attribute]] = ds_value
        end
        
        # NBK: need to read the existing password here as it's not actually
        # stored in the user record. It is stored at a path that involves the
        # UUID of the user record for non-Mobile local acccounts.    
        # Mobile Accounts are out of scope for this provider for now
        attribute_hash[:password] = self.get_password(attribute_hash[:guid])
        return attribute_hash    
    end
    
    def self.get_exec_preamble(ds_action, resource_name = nil)
        # JJM 2007-07-24
        #     DSCL commands are often repetitive and contain the same positional
        #     arguments over and over. See http://developer.apple.com/documentation/Porting/Conceptual/PortingUnix/additionalfeatures/chapter_10_section_9.html
        #     for an example of what I mean.
        #     This method spits out proper DSCL commands for us.
        #     We EXPECT name to be @resource[:name] when called from an instance object.

        # There are two ways to specify paths in 10.5.  See man dscl.
        command_vector = [ command(:dscl), "-plist", "." ]
        # JJM: The actual action to perform.  See "man dscl"
        #      Common actiosn: -create, -delete, -merge, -append, -passwd
        command_vector << ds_action
        # JJM: get_ds_path will spit back "Users" or "Groups",
        # etc...  Depending on the Puppet::Type of our self.
        if resource_name
            command_vector << "/%s/%s" % [ get_ds_path, resource_name ]
        else
            command_vector << "/%s" % [ get_ds_path ]
        end
        # JJM:  This returns most of the preamble of the command.
        #       e.g. 'dscl / -create /Users/mccune'
        return command_vector
    end
    
    def self.set_password(resource_name, guid, password_hash)
        password_hash_file = "#{@@password_hash_dir}/#{guid}"
        begin
            File.open(password_hash_file, 'w') { |f| f.write(password_hash)}
        rescue Errno::EACCES => detail
            raise Puppet::Error, "Could not write to password hash file: #{detail}"
        end
        
        # NBK: For shadow hashes, the user AuthenticationAuthority must contain a value of
        # ";ShadowHash;". The LKDC in 10.5 makes this more interesting though as it
        # will dynamically generate ;Kerberosv5;;username@LKDC:SHA1 attributes if
        # missing. Thus we make sure we only set ;ShadowHash; if it is missing, and
        # we can do this with the merge command. This allows people to continue to
        # use other custom AuthenticationAuthority attributes without stomping on them.
        #
        # There is a potential problem here in that we're only doing this when setting
        # the password, and the attribute could get modified at other times while the 
        # hash doesn't change and so this doesn't get called at all... but
        # without switching all the other attributes to merge instead of create I can't
        # see a simple enough solution for this that doesn't modify the user record
        # every single time. This should be a rather rare edge case. (famous last words)
        
        dscl_vector = self.get_exec_preamble("-merge", resource_name)
        dscl_vector << "AuthenticationAuthority" << ";ShadowHash;"
        begin
            dscl_output = execute(dscl_vector)
        rescue Puppet::ExecutionFailure => detail
            raise Puppet::Error, "Could not set AuthenticationAuthority."
        end
    end
    
    def self.get_password(guid)
        password_hash = nil
        password_hash_file = "#{@@password_hash_dir}/#{guid}"
        # TODO: sort out error conditions?
        if File.exists?(password_hash_file)
            if not File.readable?(password_hash_file)
                raise Puppet::Error("Could not read password hash file at #{password_hash_file} for #{@resource[:name]}")
            end
            f = File.new(password_hash_file)
            password_hash = f.read
            f.close
          end
        password_hash
    end

    def ensure=(ensure_value)
        super
        # JJM: Modeled after nameservice/netinfo.rb, we need to
        #   loop over all valid properties for the type we're managing
        #   and call the method which sets that property value
        #   Like netinfo, dscl can't create everything at once, afaik.
        if ensure_value == :present
            @resource.class.validproperties.each do |name|
                next if name == :ensure

                # LAK: We use property.sync here rather than directly calling
                # the settor method because the properties might do some kind
                # of conversion.  In particular, the user gid property might
                # have a string and need to convert it to a number
                if @resource.should(name)
                    @resource.property(name).sync
                elsif value = autogen(name)
                    self.send(name.to_s + "=", value)
                else
                    next
                end
            end
        end 
    end
    
    def password=(passphrase)
      exec_arg_vector = self.class.get_exec_preamble("-read", @resource.name)
      exec_arg_vector << @@ns_to_ds_attribute_map[:guid]
      begin
          guid_output = execute(exec_arg_vector)
          guid_plist = Plist.parse_xml(guid_output)
          # Although GeneratedUID like all DirectoryService values can be multi-valued
          # according to the schema, in practice user accounts cannot have multiple UUIDs
          # otherwise Bad Things Happen, so we just deal with the first value.
          guid = guid_plist["dsAttrTypeStandard:#{@@ns_to_ds_attribute_map[:guid]}"][0]
          self.class.set_password(@resource.name, guid, passphrase)
      rescue Puppet::ExecutionFailure => detail
          raise Puppet::Error, "Could not set %s on %s[%s]: %s" % [param, @resource.class.name, @resource.name, detail]
      end
    end
    
    def modifycmd(property, value)
        # JJM: This method will assemble a exec vector which modifies
        #    a single property and it's value using dscl.
        # JJM: With /usr/bin/dscl, the -create option will destroy an
        #      existing property record if it exists
        exec_arg_vector = self.class.get_exec_preamble("-create", @resource[:name])
        # JJM: The following line just maps the NS name to the DS name
        #      e.g. { :uid => 'UniqueID' }
        exec_arg_vector << @@ns_to_ds_attribute_map[symbolize(property)]
        # JJM: The following line sends the actual value to set the property to
        exec_arg_vector << value.to_s
        return exec_arg_vector
    end
    
    # NBK: we override @parent.create as we need to execute a series of commands
    # to create objects with dscl, rather than the single command nameservice.rb
    # expects to be returned by addcmd. Thus we don't bother defining addcmd.
    def create
       if exists?
            info "already exists"
            # The object already exists
            return nil
        end
        
        # NBK: First we create the object with a known guid so we can set the contents
        # of the password hash if required
        # Shelling out sucks, but for a single use case it doesn't seem worth
        # requiring people install a UUID library that doesn't come with the system.
        # This should be revisited if Puppet starts managing UUIDs for other platform
        # user records.
        guid = %x{/usr/bin/uuidgen}.chomp
        
        exec_arg_vector = self.class.get_exec_preamble("-create", @resource[:name])
        exec_arg_vector << @@ns_to_ds_attribute_map[:guid] << guid
        begin
          execute(exec_arg_vector)
        rescue Puppet::ExecutionFailure => detail
            raise Puppet::Error, "Could not set GeneratedUID for %s %s: %s" %
                [@resource.class.name, @resource.name, detail]
        end
        
        if value = @resource.should(:password) and value != ""
          self.class.set_password(@resource[:name], guid, value)
        end
        
        # Now we create all the standard properties
        Puppet::Type.type(:user).validproperties.each do |property|
            next if property == :ensure
            if value = @resource.should(property) and value != ""
                exec_arg_vector = self.class.get_exec_preamble("-create", @resource[:name])
                exec_arg_vector << @@ns_to_ds_attribute_map[symbolize(property)]
                next if property == :password  # skip setting the password here
                exec_arg_vector << value.to_s
                begin
                  execute(exec_arg_vector)
                rescue Puppet::ExecutionFailure => detail
                    raise Puppet::Error, "Could not create %s %s: %s" %
                        [@resource.class.name, @resource.name, detail]
                end  
            end
        end
    end
    
    def deletecmd
        # JJM: Like addcmd, only called when deleting the object itself
        #    Note, this isn't used to delete properties of the object,
        #    at least that's how I understand it...
        self.class.get_exec_preamble("-delete", @resource[:name])
    end
    
    def getinfo(refresh = false)
        # JJM 2007-07-24: 
        #      Override the getinfo method, which is also defined in nameservice.rb
        #      This method returns and sets @infohash, which looks like:
        #      (NetInfo provider, user type...)
        #       @infohash = {:comment=>"Jeff McCune", :home=>"/Users/mccune", 
        #       :shell=>"/bin/zsh", :password=>"********", :uid=>502, :gid=>502,
        #       :name=>"mccune"}
        #
        # I'm not re-factoring the name "getinfo" because this method will be
        # most likely called by nameservice.rb, which I didn't write.
        if refresh or (! defined?(@property_value_cache_hash) or ! @property_value_cache_hash)
            # JJM 2007-07-24: OK, there's a bit of magic that's about to
            # happen... Let's see how strong my grip has become... =)
            # 
            # self is a provider instance of some Puppet::Type, like
            # Puppet::Type::User::ProviderDirectoryservice for the case of the
            # user type and this provider.
            # 
            # self.class looks like "user provider directoryservice", if that
            # helps you ...
            # 
            # self.class.resource_type is a reference to the Puppet::Type class,
            # probably Puppet::Type::User or Puppet::Type::Group, etc...
            # 
            # self.class.resource_type.validproperties is a class method,
            # returning an Array of the valid properties of that specific
            # Puppet::Type.
            # 
            # So... something like [:comment, :home, :password, :shell, :uid,
            # :groups, :ensure, :gid]
            # 
            # Ultimately, we add :name to the list, delete :ensure from the
            # list, then report on the remaining list. Pretty whacky, ehh?
            type_properties = [:name] + self.class.resource_type.validproperties
            type_properties.delete(:ensure) if type_properties.include? :ensure
            type_properties << :guid  # append GeneratedUID so we just get the report here
            @property_value_cache_hash = self.class.single_report(@resource[:name], *type_properties)
            [:uid, :gid].each do |param|
                @property_value_cache_hash[param] = @property_value_cache_hash[param].to_i if @property_value_cache_hash and @property_value_cache_hash.include?(param)
            end
        end
        return @property_value_cache_hash
    end
end
end
