# frozen_string_literal: true

require "active_support"
require "active_job"
require "active_record"
require "jidoka/version"
require "jidoka/errors"
require "jidoka/worker"
require "jidoka/supervisor"

module Jidoka
  class Error < StandardError; end

  class Configuration
    # The parent class for Workers (defaults to ActiveJob::Base)
    attr_accessor :parent_job_class
    # Block to execute when an error occurs (for Sentry/Honeybadger)
    attr_accessor :error_handler

    def initialize
      @parent_job_class = "ActiveJob::Base"
      @error_handler = ->(error, context = {}) {
        # Default: just log it
        if defined?(Rails)
          Rails.logger.error("[Jidoka] #{error.message}")
          Rails.logger.error(error.backtrace.join("\n"))
        end
      }
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end
  end
end
