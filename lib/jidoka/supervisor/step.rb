module Jidoka
  class Supervisor < Worker
    class Step
      attr_reader :result

      def initialize(caller)
        @caller = caller
      end

      def up(&block)
        @result = @caller.instance_eval(&block)
      end

      def _down
        @caller.instance_exec(@result, &@down) if @down.present?
      end

      def down(&block)
        @down = block
      end

      def _notify
        @caller.instance_exec(@result, &@notify) if @notify.present?
      end

      def notify(&block)
        @notify = block
      end
    end
  end
end
