module Jidoka
  class Commander < Jidoka.configuration.parent_job_class.constantize
    include ActiveSupport::Rescuable

    # @return [String] Error message to display to end users
    attr_reader :message, :error

    class_attribute :argument_types

    # Shared error messages available to all Commanders
    BASE_ERRORS = {
      invalid_state_transition: 'You cannot transition to this state',
      action_already_performed: 'This action has already been performed'
    }.freeze

    # Default ERRORS hash to be overridden by subclasses
    ERRORS = {}.freeze

    # -- Class Methods --

    def self.enforce_arguments!(obj)
      self.argument_types = obj.freeze
    end

    def self.possible_errors(with_prefix = false)
      @possible_errors ||= self::ERRORS
      with_prefix ? @possible_errors.transform_keys { |k| [to_s.underscore, k].join('-') } : @possible_errors
    end

    def self.run!(opts = {})
      initialize_and_call!(opts, :validate!, :run!, *include_notify?(opts))
    end

    def self.run(opts = {})
      initialize_and_call!(opts, :validate, :run, *include_notify?(opts)).tap do |result|
        yield(result) if block_given?
      end
    end

    def self.dry_run!(opts = {})
      initialize_and_call!(opts, :validate!)
    end

    def self.dry_run(opts = {})
      initialize_and_call!(opts, :validate)
    end

    def self.undo!(opts = {})
      initialize_and_call!(opts, :undo!)
    end

    def self.undo(opts = {})
      initialize_and_call!(opts, :undo).tap do |result|
        yield(result) if block_given?
      end
    end

    def self.include_notify?(opts)
      [nil, true].include?(opts.delete(:notify)) ? %i[notify!] : []
    end

    def self.initialize_and_call!(opts, *methods_to_call)
      instance = new(opts.transform_keys(&:to_sym))
      methods_to_call.each do |m|
        instance.send(m)
        break if instance.failure?
      end
      instance
    end

    # -- Instance Methods --

    def initialize(args = nil)
      super
      # Handle ActiveJob vs direct instantiation args
      @opts = args || (arguments ? arguments[0] : {})
      @opts = @opts.transform_keys(&:to_sym) if @opts
    end

    def perform(opts = {})
      @opts = opts.transform_keys(&:to_sym)
      validate!
      run!
      notify!
    end

    def prepare(opts); end

    def validate!
      validate_arguments!(**@opts)
      prepare(**@opts)
      validate_conditions!(**@opts)
    rescue Jidoka::ConditionNotMet, Jidoka::ArgumentClassMismatch, Jidoka::Failure => e
      notice_failure!(e)
      raise(e)
    end

    def validate
      validate!
    rescue StandardError => e
      notice_failure!(e)
    end

    def run!
      ActiveRecord::Base.transaction { up(**@opts) }
    rescue Jidoka::ConditionNotMet, Jidoka::Failure => e
      notice_failure!(e)
      raise(e)
    end

    def run
      run!
    rescue StandardError => e
      notice_failure!(e)
    end

    def undo!
      prepare_inverse(**@opts) if respond_to?(:prepare_inverse)
      ActiveRecord::Base.transaction { down }
    rescue Jidoka::ConditionNotMet, Jidoka::Failure => e
      notice_failure!(e)
      raise(e)
    end

    def undo
      undo!
    rescue StandardError => e
      notice_failure!(e)
    end

    def up(_opts = nil)
      raise NotImplementedError
    end

    def down; end

    def notify!
      _notify(**@opts)
    rescue StandardError => e
      report_error(e)
      # We do not re-raise notification errors by default unless in test
      raise(e) if defined?(Rails) && Rails.env.test?
    end

    def _notify(**_opts); end

    # -- State Helpers --

    def failure?
      @failure.present?
    end

    def success?
      !failure?
    end

    def failed
      yield(self) if failure?
    end

    def success
      yield(self) if success?
    end

    protected

    def validate_conditions!(**opts); end

    def condition!(key, message: nil)
      raise_condition!(key, message: message) unless yield
    end

    def raise_condition!(key, message: nil)
      raise Jidoka::ConditionNotMet.new(
        message: message || self.class.possible_errors[key],
        code: [self.class.to_s.underscore, key].join('-')
      )
    end

    def fail!(key, message: nil, **context)
      raise Jidoka::Failure.new(
        message: message || self.class.possible_errors[key],
        code: [self.class.to_s.underscore, key].join('-'),
        context: context
      )
    end

    def validate_arguments!(**args)
      return if self.class.argument_types.nil?

      self.class.argument_types.each do |key, klass_name|
        val = args[key]
        expected_classes = Array(klass_name).map(&:constantize)

        # Check if value matches any of the expected classes
        unless expected_classes.any? { |k| val.is_a?(k) }
          raise Jidoka::ArgumentClassMismatch.new(key, expected: klass_name, actual: val.class.to_s)
        end
      end
    end

    # Validates usage of AASM state machines if AASM is present
    def aasm_event_condition!(object, event)
      return unless defined?(AASM)

      matched = object.class.aasm.events.detect { |e| e.name.to_s == event.to_s }
      return if matched.may_fire?(object)

      if matched.transitions[0].to == object.aasm.current_state
        raise_condition!(
          :action_already_performed,
          message: "This #{object.class.to_s.humanize} is already #{object.try(:status)&.humanize || 'in that state'}"
        )
      else
        raise_condition!(
          :invalid_state_transition,
          message: "Could not #{event} because current status is #{object.try(:status)&.humanize || 'invalid'}"
        )
      end
    end

    def valid_for?(record, context)
      record.valid?(context) || raise(ActiveRecord::RecordInvalid, record)
    end

    private

    def notice_failure!(e)
      @failure = true
      @error = e
      @message = e.message
      report_error(e)
    end

    def report_error(e)
      Jidoka.configuration.error_handler.call(e, { worker: self.class.name, args: @opts })
    end
  end
end
