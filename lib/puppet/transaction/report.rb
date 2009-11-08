require 'puppet'
require 'puppet/indirector'

# A class for reporting what happens on each client.  Reports consist of
# two types of data:  Logs and Metrics.  Logs are the output that each
# change produces, and Metrics are all of the numerical data involved
# in the transaction.
class Puppet::Transaction::Report
    extend Puppet::Indirector

    indirects :report, :terminus_class => :processor

    attr_reader :events, :logs, :metrics, :host, :time
    attr_accessor :version

    # This is necessary since Marshall doesn't know how to
    # dump hash with default proc (see below @records)
    def self.default_format
        :yaml
    end

    def self.last_transaction_log_name
        last = Dir.entries(Puppet[:client_transactionlog_dir]).find_all { |f| f =~ /\d+\.yaml/ }.sort.last
        File.join(Puppet[:client_transactionlog_dir], last)
    end

    def self.last_transaction_log
        YAML.load_file(last_transaction_log_name)
    end

    def self.remove_last_transaction_log
        File.unlink(last_transaction_log_name)
    end

    def <<(msg)
        @logs << msg
        return self
    end

    def initialize
        @metrics = {}
        @logs = []
        @events = []
        @host = Puppet[:certname]
        @time = Time.now
    end

    def name
        host
    end

    # Create a new metric.
    def newmetric(name, hash)
        metric = Puppet::Util::Metric.new(name)

        hash.each do |name, value|
            metric.newvalue(name, value)
        end

        @metrics[metric.name] = metric
    end

    def register_event(event)
        @events << event
    end

    def store_as_transaction_log
        return if events.empty?
        return unless version

        Puppet.settings.use(:puppetd)

        name = File.join(Puppet[:client_transactionlog_dir], Time.now.to_i.to_s + ".yaml")

        File.open(name, "w") { |f| f.print to_yaml }
    end

    # Provide a summary of this report.
    def summary
        ret = ""

        @metrics.sort { |a,b| a[1].label <=> b[1].label }.each do |name, metric|
            ret += "%s:\n" % metric.label
            metric.values.sort { |a,b|
                # sort by label
                if a[0] == :total
                    1
                elsif b[0] == :total
                    -1
                else
                    a[1] <=> b[1]
                end
            }.each do |name, label, value|
                next if value == 0
                if value.is_a?(Float)
                    value = "%0.2f" % value
                end
                ret += "   %15s %s\n" % [label + ":", value]
            end
        end
        return ret
    end
end

