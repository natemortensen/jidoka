require 'active_support/core_ext/class/attribute.rb'
require 'active_support/core_ext/hash/keys.rb'

module Jidoka
  ##
  # Raised when we can't rollback changes (to notify devs)
  class IrreversibleAction < StandardError; end

  ##
  # Raised when an argument's class does not match the class defined in `argument_types`
  class ArgumentClassMismatch < StandardError
    attr_reader :param, :expected, :actual

    def initialize(argument, expected:, actual:)
      @param = argument
      @expected = expected
      @actual = actual
    end

    def message
      if actual.nil?
        "#{param} was not provided"
      else
        "#{param} was expected to be a(n) #{@expected} but was a(n) #{@actual}"
      end
    end
  end

  ##
  # Raised manually if some error occurs during execution
  class Failure < StandardError
    attr_reader :message, :code

    def initialize(code:, message:)
      @message = message
      @code = code
    end
  end

  ##
  # Raised manually via `validate_conditions!` to pass directly to end user
  class ConditionNotMet < Failure; end

  ##
  # This class is an atomic set of instructions that can optionally be combined into a sequence of steps.
  # Human-readable error messages are also provided to end-users when
  class Worker
    attr_reader :message, :error

    ##
    # This is a Hash of required argument keys and their expected class
    class_attribute :argument_types, :errors

    def self.enforce_arguments!(obj)
      self.argument_types = obj.freeze
    end

    def self.set_errors(obj)
      self.errors = (self.errors || {}).merge(obj)
    end

    def self.possible_errors(with_prefix = false)
      @possible_errors ||= self.errors || {}
      with_prefix ? @possible_errors.transform_keys { |k| [to_s.underscore, k].join('-') } : @possible_errors
    end

    def self.run!(opts = {})
      steps = opts.delete(:notify) ? %i[validate! run!] : %i[validate! run! send_notification]
      initialize_and_call!(opts, *steps)
    end

    def self.run(opts = {})
      steps = opts.delete(:notify) ? %i[validate run] : %i[validate! run! send_notification]
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
      # super
      @opts = args
    end

    def validate!
      validate_arguments!(@opts)
      prepare(@opts)
      validate_conditions!(@opts)
    rescue ConditionNotMet, ArgumentClassMismatch, Failure => e
      notice_failure(e)
      raise(e)
    end

    def validate
      validate!
    rescue StandardError => e
      notice_failure(e)
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

    def notice_failure(e)
      @failure = true
      @error = e
      @message = e.message

      capture_error(error)
    end

    def capture_error(error); end

    # NOTE: This is an abstract method expected to be defined in the concrete class.
    def up(_opts = nil)
      raise NotImplementedError
    end

    def down; end

    def failure?
      !@failure.nil?
    end

    def failed
      yield(self) if failure?
    end

    def success?
      !failure?
    end

    def succeeded
      yield(self) if success?
    end

    def send_notification
      notify(@opts)

    # These are just notifications so they can silently fail but still report error
    rescue StandardError => e
      capture_error(e)
    end

    def notify(**_opts); end

    protected

    def validate_conditions!(**_opts); end

    ##
    # Raises `ConditionNotMet` with specified error message if block does not return a truthy value.
    # Intended for use with `validate_conditions!`
    def condition!(key, message: nil)
      raise_condition!(key, message: message) unless yield
    end

    def raise_condition!(key, message: nil)
      raise ConditionNotMet.new(
        message: message || self.class.possible_errors[key],
        code: key
      )
    end

    def fail!(key, message: nil)
      raise Failure.new(
        message: message || self.class.possible_errors[key],
        code: key
      )
    end

    # Iterate through `argument_types` checking for a class match
    def validate_arguments!(**args)
      return if self.class.argument_types.nil?

      self.class.argument_types.each do |key, klass|
        case args[key]
          when *Array(klass).map(&:constantize) then nil # Object is okay
          else raise ArgumentClassMismatch.new(key, expected: klass, actual: args[key]&.class&.to_s)
        end
      end
    end
  end
end
