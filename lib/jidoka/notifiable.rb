module Jidoka
  module Notifiable
    extend ActiveSupport::Concern

    included do
      def send_notification
        notify(@opts)

      # These are just notifications so they can silently fail but still report error
      rescue StandardError => e
        capture_error(e)
      end

      def notify(**_opts); end
    end
  end
end