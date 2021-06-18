require 'active_support/core_ext/class/attribute.rb'
require 'active_support/core_ext/hash/keys.rb'
require 'active_support/concern.rb'

require 'jidoka/version'
require 'jidoka/errors'
require 'jidoka/validatable'
require 'jidoka/notifiable'

module Jidoka
  ##
  # This class is an atomic set of instructions that can optionally be combined into a sequence of steps.
  # Human-readable error messages are also provided to end-users when
  class Worker
    include Validatable
    include Notifiable

    def self.run!(opts = {})
      steps = opts.delete(:notify) == false ? %i[validate! run!] : %i[validate! run! send_notification]
      initialize_and_call!(opts, *steps)
    end

    def self.run(opts = {})
      steps = opts.delete(:notify) == false ? %i[validate run] : %i[validate run send_notification]
      initialize_and_call!(opts, *steps).tap do |result|
        yield(result) if block_given?
      end
    end

    # `dry_run` will only check conditions/validations without actually executing the `up` logic
    def self.dry_run!(opts = {})
      initialize_and_call!(opts, :validate!)
    end

    def self.dry_run(opts = {})
      initialize_and_call!(opts, :validate)
    end

    def self.initialize_and_call!(opts, *methods_to_call)
      new(opts.symbolize_keys).tap do |instance|
        methods_to_call.each do |m|
          instance.send(m)
          break if instance.failure?
        end
      end
    end

    def prepare(opts); end

    def initialize(args = nil)
      @opts = args
    end

    def run!
      # ActiveRecord::Base.transaction { up(**@opts) } # Rolls back if failure encountered
      up(**@opts)
    rescue Failure => e
      notice_failure(e)
      raise
    end

    def run
      run!
    rescue StandardError => e
      notice_failure(e)
    end

    # NOTE: This is an abstract method expected to be defined in the concrete class.
    def up(_opts = nil)
      raise NotImplementedError
    end

    def down; end
  end

  ##
  # This is the molecular unit of an supervisor.
  # It provides a DSL for up/down/notify hooks to be called depending on the success of other steps
  class Step
    attr_reader :result

    def initialize(caller)
      @caller = caller
    end

    def up(&block)
      @result = @caller.instance_eval(&block)
    end

    def down(&block)
      @down = block
    end

    def undo
      @caller.instance_exec(@result, &@down) if @down
    end

    def send_notification
      @caller.instance_exec(@result, &@notify) if @notify
    end

    def notify(&block)
      @notify = block
    end
  end

  ##
  # This class executes steps in a specified sequence given some inputs.
  # If a failure is encountered, previous steps will be rolled back automatically
  class Supervisor < Worker
    def initialize(*args)
      super(*args)
      @steps = []
    end

    # NOTE: Do not overwrite this method! The `down` for supervisors is just calling down on each step
    def rollback
      @steps.reverse_each do |step|
        step.undo

      # We shouldn't raise errors in rollbacks. Definitely want to catch any of these issues
      rescue StandardError => e
        capture_error(e)
      end
    end

    def run!
      orchestrate(@opts)
    rescue StandardError => e
      rollback
      notice_failure(e)
      raise(e)
    end

    def send_notification
      @steps.each(&:send_notification)
      notify(@opts)

    # These are just notifications so they can silently fail but still report error
    rescue StandardError => e
      capture_error(e)
    end

    protected

    def step(&block)
      step = Step.new(self)
      step.instance_eval(&block)
      @steps << step
      step.result
    end

    def worker_step(klass, opts = {})
      step do
        up { klass.run!(opts.merge(notify: false)) } # NOTE: notify is false since it is always deferred
        down(&:down)
        notify(&:send_notification)
      end
    end

    def update_record_step(record, updates)
      previous_state = updates.map do |k, v|
        [
          k,
          k.to_s =~ /_attributes/ ? v.class.new : record.send(k)
        ]
      end.to_h

      step do
        up { record.tap { record.update_attributes!(updates) } }
        down { record.tap { record.update_attributes!(previous_state) } }
      end
    end

    def create_record_step
      step do
        up { yield }
        down(&:destroy!)
      end
    end

    def notify(**_opts); end
  end
end
