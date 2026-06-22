# frozen_string_literal: true

SolidusSpreedly.configure do |config|
  # Spreedly gateways are configured per payment method in the admin
  # (environment key, access secret, orchestration mode, gateway token, etc.).
  #
  # Use this initializer only for store-wide overrides, e.g. swapping the
  # default gateway class with your own subclass:
  #
  # config.default_gateway_class = 'SolidusSpreedly::Gateway'
end
