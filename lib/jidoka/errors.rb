# frozen_string_literal: true

module Jidoka
  # Raised when rollback (down) fails
  class IrreversibleAction < StandardError; end

  # Raised when enforce_arguments! validation fails
  class ArgumentClassMismatch < StandardError
    attr_reader :param, :expected, :actual

    def initialize(argument, expected:, actual:)
      @param = argument
      @expected = expected
      @actual = actual
      super("#{param} was expected to be a(n) #{@expected} but was a(n) #{@actual || 'nil'}")
    end
  end

  # Raised when business logic conditions are not met (Validation phase)
  class ConditionNotMet < StandardError
    attr_reader :code

    def initialize(code:, message:)
      @code = code
      super(message)
    end
  end

  # Raised when execution fails for a known reason (Execution phase)
  class Failure < StandardError
    attr_reader :code, :context

    def initialize(code:, message:, context: {})
      @code = code
      @context = context
      super(message)
    end
  end
end
