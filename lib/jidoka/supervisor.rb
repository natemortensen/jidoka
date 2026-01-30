require_relative "supervisor/step"

module Jidoka
  class Supervisor < Commander
    def initialize(*args)
      super(*args)
      @steps = []
    end

    def run!
      orchestrate(**@opts)
    rescue StandardError => e
      rollback
      # notice_failure! is called in run! wrapper of super, but we need to ensure
      # we notice it here if we want to log it before re-raising
      send(:notice_failure!, e)
      raise(e)
    end

    def rollback
      @steps.reverse_each do |step|
        begin
          step._down
        rescue StandardError => e
          report_error(e)
        end
      end
    end

    # Alias for compatibility
    def down
      rollback
    end

    def notify!
      @steps.each(&:_notify)
      _notify(**@opts)
    rescue StandardError => e
      report_error(e)
      raise(e) if defined?(Rails) && Rails.env.test?
    end

    protected

    def step!(&block)
      step = Step.new(self)
      begin
        step.instance_eval(&block)
      rescue StandardError => e
        @message = e.message
        raise(e)
      end

      @steps << step
      step.result
    end

    def worker_step!(klass, opts = {})
      step! do
        up { klass.run!(**opts.merge(notify: false)) }
        down(&:down) # Calls down on the worker instance returned by up
        notify(&:notify!) unless opts[:notify] == false
      end
    end

    def update_record_step!(record, updates)
      previous_state = updates.to_h do |k, v|
        [
          k,
          k.to_s =~ /_attributes/ ? v.class.new : record.send(k)
        ]
      end

      step! do
        up { record.tap { record.update!(updates) } }
        down { record.tap { record.update!(previous_state) } }
      end
    end

    def create_record_step!(&block)
      step! do
        up(&block)
        down do |record|
          record.reload.destroy!
        end
      end
    end

    # Abstract method to be implemented by subclass
    def orchestrate(**_opts)
      raise NotImplementedError
    end
  end
end
