require 'puppet/indirector/code'
require 'puppet/file_bucket/file'
require 'puppet/util/checksums'

module Puppet::FileBucketFile
    class Git < Puppet::Indirector::Code
        include Puppet::Util::Checksums

        desc "Store files in a directory set based on their checksums."

        attr_reader :path

        def initialize
            Puppet.settings.use(:filebucket)
            @path = "/tmp/gitrepo"
            unless FileTest.exist?("/tmp/gitrepo/.git")
                puts "Initializing repo"
                Dir.mkdir(path)
                in_repo { system("git init") }
            end
        end

        def find( request )
            checksum, path = request_to_checksum_and_path( request )
            return find_by_checksum( checksum, request.options )
        end

        def save( request )
            checksum, path = request_to_checksum_and_path( request )

            instance = request.instance
            instance.checksum_type = :git
            instance.path = path if path

            save_to_disk(instance)
            instance.to_s
        end

        private

        def in_repo(repo_path = @path)
            Dir.chdir(repo_path) { yield }
        end

        def find_by_checksum( checksum, options )
            content = in_repo(options[:bucket_path]) { %x{git cat-file -p #{checksum}} }

            model.new(content, :checksum => checksum)
        end

        def request_to_checksum_and_path( request )
            return [request.key, nil] if checksum?(request.key)

            checksum_type, checksum, path = request.key.split(/\//, 3)
            return nil if checksum_type.to_s == ""
            return [ "{#{checksum_type}}#{checksum}", path ]
        end

        def save_to_disk(bucket_file)
            in_repo {
                IO.popen("git hash-object --stdin -w", "w") do |git|
                    git.print File.read(bucket_file.path)
                end
            }

            return bucket_file.checksum_data
        end
    end
end
