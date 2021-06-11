module Jidoka
  module Validatable
    extend ActiveSupport::Concern

    included do
      attr_reader :message, :error

      ##
      # This is a Hash of required argument keys and their expected class
      class_attribute :argument_types, :errors

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

      def notice_failure(e)
        @failure = true
        @error = e
        @message = e.message

        capture_error(error)
      end

      def capture_error(error); end

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

    class_methods do
      def enforce_arguments!(obj)
        self.argument_types = obj.freeze
      end

      def set_errors(obj)
        self.errors = (self.errors || {}).merge(obj)
      end

      def possible_errors(with_prefix = false)
        @possible_errors ||= self.errors || {}
        with_prefix ? @possible_errors.transform_keys { |k| [to_s.underscore, k].join('-') } : @possible_errors
      end
    end
  end
end