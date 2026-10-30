# frozen_string_literal: true

SolidusSpreedly.configure do |config|
  # Spreedly credentials and routing are configured per payment method in the
  # Solidus admin (environment key, access secret, orchestration mode, gateway
  # token / workflow key, optional SCA provider key).
  #
  # This initializer is only for store-wide overrides. For example, to use your
  # own gateway subclass (e.g. to override the canary `gateway_token_for` hook):
  #
  #   config.default_gateway_class = 'MyStore::SpreedlyGateway'
  #
  # Which succeeded Spreedly transactions can be voided. The value is a String
  # class name. Subclass SolidusSpreedly::VoidPolicy and override a predicate
  # (for example to add a Braintree settlement-age cutoff):
  #
  #   config.void_policy_class = 'MyStore::SpreedlyVoidPolicy'
end
