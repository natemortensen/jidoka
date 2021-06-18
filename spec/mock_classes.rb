require 'jidoka'

module MockClasses
  class TestWorker < Jidoka::Worker
    attr_reader :arr

    set_errors(
      array_has_multiple: 'Array cannot have multiple elements'
    )

    def prepare(arr:, **_opts)
      @arr = arr
    end

    def up(arr:, **_opts)
      arr << 'Code has executed.'
    end

    def down
      @arr.pop
    end

    def audit(arr:, **_opts)
      valid_if(:array_has_multiple) { arr.size <= 1 }
    end

    def notify(opts)
      opts[:notifications] << 'Hey you! Something happened.'
    end
  end

  class TestSupervisor < Jidoka::Supervisor
    attr_reader :result, :inline_step

    set_errors(
      array_not_blank: 'Array is not empty',
      custom_failure: 'Inline error raised'
    )

    def orchestrate(arr:, notifications:, run_twice: true, raise_error: false, raise_inline_error: false)
      args = {arr: arr, notifications: notifications}
      worker_step(TestWorker, args)
      worker_step(TestWorker, args) if run_twice || raise_error # Test conditionals
      worker_step(TestWorker, args) if raise_error # Test rollback

      step do
        up { @inline_step = {status: :ran} }

        # We're the result in as a block argument intentionally to test that functionality
        down { |r| r[:status] = :rolled_back }
      end

      fail!(:custom_failure) if raise_inline_error

      @result = arr.clone
      @result << 'The returned object is slightly different'
    end

    protected

    def audit(arr:, **_opts)
      valid_if(:array_not_blank) { arr.size == 0 }
    end
  end
end
