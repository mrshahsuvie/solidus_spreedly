# frozen_string_literal: true

module SolidusSpreedly
  class Configuration
    # The payment method class used by the extension. Override with your own
    # subclass (e.g. to customize the `gateway_token_for` routing hook).
    attr_accessor :default_gateway_class

    def initialize
      @default_gateway_class = "SolidusSpreedly::Gateway"
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    alias_method :config, :configuration

    def configure
      yield configuration
    end
  end
end
