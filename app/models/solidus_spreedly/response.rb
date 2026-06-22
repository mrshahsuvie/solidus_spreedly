# frozen_string_literal: true

require "active_merchant/billing/response"

module SolidusSpreedly
  # Thin wrapper around +ActiveMerchant::Billing::Response+ that adds
  # Spreedly-specific, human-readable helpers on top of the parsed transaction state.
  class Response < ::ActiveMerchant::Billing::Response
    # A Spreedly transaction in this state is awaiting an extra step, most
    # commonly a 3DS2 challenge, and must be finished via the completion flow.
    PENDING_STATE = "pending"

    # Adapt an existing AM response into a Spreedly response wrapper.
    #
    # @param response [ActiveMerchant::Billing::Response]
    # @return [SolidusSpreedly::Response]
    def self.from_response(response)
      new(
        response.success?,
        response.message,
        response.params,
        authorization: response.authorization,
        test: response.test?,
        avs_result: {code: response.avs_result&.dig("code")},
        cvv_result: response.cvv_result&.dig("code"),
        error_code: response.error_code
      )
    end

    # The raw Spreedly transaction state, e.g. "succeeded" / "pending".
    def state
      transaction["state"] || params["state"]
    end

    # Whether the transaction still needs completion (e.g. a 3DS2 challenge).
    def pending?
      state == PENDING_STATE
    end

    # The URL the buyer must be redirected to in order to finish a pending
    # (3DS2) transaction, when Spreedly provides one.
    def checkout_url
      transaction.dig("checkout_url") || transaction.dig("challenge", "checkout_url")
    end

    # A human-readable description of the current state, looked up via I18n with
    # a humanized fallback.
    def friendly_message
      return message if state.blank?

      I18n.t(state, scope: "solidus_spreedly.transaction_states", default: state.humanize)
    end

    private

    def transaction
      hash = params.is_a?(Hash) ? params : {}
      hash["transaction"].is_a?(Hash) ? hash["transaction"] : hash
    end
  end
end
