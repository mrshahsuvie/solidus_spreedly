# frozen_string_literal: true

require 'vcr'
require 'webmock/rspec'

VCR.configure do |config|
  credentials_present = -> { ENV["SPREEDLY_ENVIRONMENT_KEY"].present? && ENV["SPREEDLY_ACCESS_SECRET"].present? }

  config.cassette_library_dir = "#{__dir__}/../../cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.default_cassette_options = {
    record: credentials_present.call ? :once : :none
  }

  # Spreedly authenticates with HTTP Basic auth built from the environment key
  # (login) and access secret (password). Never let those land in a cassette.
  #
  # The placeholders are deliberately URL-safe (no angle brackets) and identical
  # to the offline fallback values in SolidusSpreedly::SpecSupport::Sandbox.
  # The gateway tokens appear in the request *path* (e.g. /gateways/{token}/...),
  # so the recorded URI and the offline request must match character-for-character.
  config.filter_sensitive_data('test-environment-key') { credentials_present.call ? ENV.fetch('SPREEDLY_ENVIRONMENT_KEY', nil) : nil }
  config.filter_sensitive_data('test-access-secret') { credentials_present.call ? ENV.fetch('SPREEDLY_ACCESS_SECRET', nil) : nil }

  # Routing identifiers are not auth secrets, but we still keep them out of the
  # committed cassettes so the fixtures are not tied to one merchant's setup.
  config.filter_sensitive_data('test-gateway-token') { credentials_present.call ? ENV.fetch('SPREEDLY_GATEWAY_TOKEN', nil) : nil }
  config.filter_sensitive_data('test-stripe-gateway-token') { credentials_present.call ? ENV.fetch('SPREEDLY_STRIPE_GATEWAY_TOKEN', nil) : nil }
  config.filter_sensitive_data('test-workflow-key') { credentials_present.call ? ENV.fetch('SPREEDLY_WORKFLOW_KEY', nil) : nil }
  config.filter_sensitive_data('test-sca-provider-key') { credentials_present.call ? ENV.fetch('SPREEDLY_SCA_PROVIDER_KEY', nil) : nil }

  # The Authorization header carries the Base64-encoded "key:secret" pair.
  config.filter_sensitive_data('<SPREEDLY_BASIC_AUTH>') do |interaction|
    interaction.request.headers['Authorization']&.first
  end
end
