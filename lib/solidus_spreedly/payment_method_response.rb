# frozen_string_literal: true

module SolidusSpreedly
  # Result of Spreedly endpoints that return a +payment_method+ payload
  # (not an ActiveMerchant billing / transaction response).
  #
  # Reuse this for any payment-method-shaped API. Pass +expect:+ to require
  # specific attributes on the returned payment method (e.g.
  # +expect: { managed: false }+ for +update_gratis+).
  class PaymentMethodResponse
    attr_reader :success, :message, :error_code, :payment_method_token, :payment_method

    def initialize(success:, message:, error_code: nil, payment_method_token: nil, payment_method: nil)
      @success = success
      @message = message
      @error_code = error_code
      @payment_method_token = payment_method_token
      @payment_method = payment_method || {}
    end

    def success?
      success
    end

    # Parse a raw Spreedly JSON body that is expected to contain a
    # +payment_method+ object.
    #
    # Success requires a +payment_method+, no errors, and every entry in
    # +expect+ to match the corresponding payment-method attribute.
    # Boolean expectations are cast with +ActiveModel::Type::Boolean+.
    #
    # @param raw_response [String, nil]
    # @param expect [Hash{Symbol,String => Object}]
    # @return [SolidusSpreedly::PaymentMethodResponse]
    def self.from_raw(raw_response, expect: {})
      new(**Parser.call(raw_response, expect: expect))
    end

    # @api private
    class Parser
      def self.call(raw_response, expect:)
        new(raw_response, expect: expect).call
      end

      def initialize(raw_response, expect:)
        @raw_response = raw_response
        @expect = expect.to_h
      end

      def call
        parsed = parse_json(raw_response)
        payment_method = payment_method_from(parsed)
        errors = payment_method_errors(parsed, payment_method)

        {
          success: success?(payment_method, errors),
          message: message(payment_method, errors),
          error_code: errors.filter_map { |error| error["key"] }.join(", ").presence,
          payment_method_token: payment_method["token"],
          payment_method: payment_method
        }
      end

      private

      attr_reader :raw_response, :expect

      def payment_method_from(parsed)
        parsed["payment_method"].is_a?(Hash) ? parsed["payment_method"] : {}
      end

      def success?(payment_method, errors)
        return false if payment_method.blank? || errors.any?

        expectations_match?(payment_method)
      end

      def payment_method_errors(parsed, payment_method)
        nested_errors = Array(payment_method["errors"])
        return nested_errors if nested_errors.any?

        Array(parsed["errors"])
      end

      def expectations_match?(payment_method)
        expect.all? do |key, expected|
          actual = payment_method[key.to_s]
          values_match?(actual, expected)
        end
      end

      def values_match?(actual, expected)
        if expected == true || expected == false
          ActiveModel::Type::Boolean.new.cast(actual) == expected
        else
          actual == expected
        end
      end

      def message(payment_method, errors)
        Array(errors).filter_map { |error| error["message"] }.join(", ").presence ||
          payment_method["message"].presence ||
          (payment_method.present? ? "OK" : "Invalid response from Spreedly")
      end

      def parse_json(raw)
        return {} if raw.nil? || raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        {"errors" => [{"message" => "Invalid response received from Spreedly: #{raw.inspect}"}]}
      end
    end
    private_constant :Parser
  end
end
