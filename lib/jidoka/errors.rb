module Jidoka
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
  # Raised when we can't rollback changes (to notify devs)
  class IrreversibleAction < StandardError; end
end