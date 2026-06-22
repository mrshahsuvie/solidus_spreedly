# frozen_string_literal: true

require 'vcr'
require 'webmock/rspec'

VCR.configure do |config|
  config.cassette_library_dir = "#{__dir__}/../../cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.default_cassette_options = { record: :once }

  # Spreedly authenticates with HTTP Basic auth built from the environment key
  # (login) and access secret (password). Never let those land in a cassette.
  config.filter_sensitive_data('<SPREEDLY_ENVIRONMENT_KEY>') { ENV.fetch('SPREEDLY_ENVIRONMENT_KEY', nil) }
  config.filter_sensitive_data('<SPREEDLY_ACCESS_SECRET>') { ENV.fetch('SPREEDLY_ACCESS_SECRET', nil) }

  # The Authorization header carries the Base64-encoded "key:secret" pair.
  config.filter_sensitive_data('<SPREEDLY_BASIC_AUTH>') do |interaction|
    interaction.request.headers['Authorization']&.first
  end
end
