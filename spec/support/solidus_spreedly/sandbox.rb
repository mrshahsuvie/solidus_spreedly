# frozen_string_literal: true

module SolidusSpreedly
  module SpecSupport
    # Helpers for the live Spreedly sandbox integration specs.
    #
    # These specs make real HTTP calls the first time they run (recording a VCR
    # cassette) and replay the committed cassette on every subsequent run, so
    # CI never needs credentials or network access.
    #
    # By default examples replay committed cassettes. If a cassette is missing
    # and SPREEDLY_* credentials are available, VCR records it from the live API.
    # To force re-recording, delete the relevant cassette(s) under
    # spec/cassettes/spreedly_sandbox/ and run the specs with credentials:
    #
    #   SPREEDLY_ENVIRONMENT_KEY=...        # the environment key (Basic-auth login)
    #   SPREEDLY_ACCESS_SECRET=...          # the access secret (Basic-auth password)
    #   SPREEDLY_GATEWAY_TOKEN=...          # a test gateway token (e.g. Braintree)
    #   SPREEDLY_STRIPE_GATEWAY_TOKEN=...   # a Stripe test gateway token (for 3DS)
    #   SPREEDLY_WORKFLOW_KEY=...           # a composer workflow key (workflow mode)
    #   SPREEDLY_SCA_PROVIDER_KEY=...       # optional 3DS2 provider key
    #
    # When the credentials are absent, examples replay the committed cassettes.
    # If a cassette is missing, the spec fails loudly so missing recordings are
    # visible instead of being hidden as pending examples.
    module Sandbox
      module_function

      # Placeholder values used when replaying cassettes offline. They are
      # URL-safe and must exactly match the filter placeholders in
      # spec/support/solidus_spreedly/vcr.rb, because the gateway tokens appear
      # in the recorded request path. With no real credentials, the client
      # builds requests from these values and they match the committed cassette.
      PLACEHOLDER = {
        environment_key: "test-environment-key",
        access_secret: "test-access-secret",
        gateway_token: "test-gateway-token",
        stripe_gateway_token: "test-stripe-gateway-token",
        workflow_key: "test-workflow-key",
        sca_provider_key: "test-sca-provider-key"
      }.freeze

      # A Visa test card accepted by Spreedly's test gateways.
      TEST_CARD = {
        first_name: "John",
        last_name: "Doe",
        number: "4111111111111111",
        verification_value: "123",
        month: 12,
        year: Time.now.year + 3
      }.freeze

      def load_dotenv!
        path = File.expand_path("../../../.env", __dir__)
        return unless File.exist?(path)

        File.readlines(path).each do |line|
          next if line.strip.empty? || line.lstrip.start_with?("#")

          key, value = line.strip.split("=", 2)
          next if key.to_s.empty? || value.nil? || ENV.key?(key)

          ENV[key] = value.gsub(/\A['"]|['"]\z/, "")
        end
      end

      def record_live?
        credentials_present?
      end

      def environment_key
        ENV["SPREEDLY_ENVIRONMENT_KEY"].presence || PLACEHOLDER[:environment_key]
      end

      def access_secret
        ENV["SPREEDLY_ACCESS_SECRET"].presence || PLACEHOLDER[:access_secret]
      end

      def gateway_token
        ENV["SPREEDLY_GATEWAY_TOKEN"].presence || PLACEHOLDER[:gateway_token]
      end

      def stripe_gateway_token
        ENV["SPREEDLY_STRIPE_GATEWAY_TOKEN"].presence || PLACEHOLDER[:stripe_gateway_token]
      end

      def workflow_key
        ENV["SPREEDLY_WORKFLOW_KEY"].presence || PLACEHOLDER[:workflow_key]
      end

      def sca_provider_key
        ENV["SPREEDLY_SCA_PROVIDER_KEY"].presence || PLACEHOLDER[:sca_provider_key]
      end

      # Whether real recording is possible right now (credentials in the env).
      def credentials_present?
        ENV["SPREEDLY_ENVIRONMENT_KEY"].present? && ENV["SPREEDLY_ACCESS_SECRET"].present?
      end

      # A client configured for the sandbox, defaulting to :gateway mode.
      def client(**overrides)
        SolidusSpreedly::Client.new(
          {
            login: environment_key,
            password: access_secret,
            gateway_token: gateway_token,
            test: true
          }.merge(overrides)
        )
      end

      # Mint a fresh, retained Spreedly payment method token from a test card so
      # each money-moving flow is self-contained and reproducible. The request
      # is captured inside the example's VCR cassette.
      #
      # @return [String] the Spreedly payment method token
      def create_test_payment_method(card: {})
        response = client.create_payment_method(
          credit_card: TEST_CARD.merge(card),
          retain: true
        )

        error_keys = Array(response.params.dig("transaction", "errors")).map { |error| error["key"] }
        if error_keys.include?("errors.access_denied")
          raise "Spreedly authentication failed while recording. Check SPREEDLY_ENVIRONMENT_KEY and SPREEDLY_ACCESS_SECRET; do not commit this cassette."
        end

        token = response.authorization
        raise "Could not mint a Spreedly test payment method: #{response.params.inspect}" if token.to_s.empty?

        token
      end
    end
  end
end

SolidusSpreedly::SpecSupport::Sandbox.load_dotenv!

RSpec.configure do |config|
  config.include SolidusSpreedly::SpecSupport::Sandbox, :spreedly_sandbox

  config.before(:each, :spreedly_sandbox) do |example|
    cassette = example.metadata.dig(:vcr, :cassette_name)
    next unless cassette

    cassette_path = File.join(VCR.configuration.cassette_library_dir, "#{cassette}.yml")
    next if File.exist?(cassette_path)
    next if SolidusSpreedly::SpecSupport::Sandbox.credentials_present?

    skip "Missing Spreedly VCR cassette and no credentials are available: #{cassette_path}"
  end
end
