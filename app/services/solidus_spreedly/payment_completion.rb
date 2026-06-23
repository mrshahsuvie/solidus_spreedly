# frozen_string_literal: true

module SolidusSpreedly
  # Finishes a Spreedly transaction that previously came back +pending+ (most
  # commonly after a 3DS2 challenge) and reflects the outcome back onto the
  # Solidus payment.
  #
  # Given a payment whose +response_code+ is a pending Spreedly transaction
  # token, it calls the gateway's completion endpoint and then transitions the
  # payment:
  #
  #   * succeeded -> +complete!+ (auto-capture) or +pend!+ (authorize-only)
  #   * anything else -> +failure!+
  #
  # The Spreedly response is always recorded as a payment log entry, mirroring
  # how +Spree::Payment::Processing+ records gateway responses.
  class PaymentCompletion
    # Raised when asked to complete a payment that has no Spreedly transaction
    # to act on.
    class MissingTransactionError < StandardError; end

    attr_reader :payment, :options

    def initialize(payment, options = {})
      @payment = payment
      @options = options
    end

    # @return [ActiveMerchant::Billing::Response] the Spreedly completion response
    def call
      raise MissingTransactionError, "payment has no response_code to complete" if payment.response_code.blank?

      response = payment.payment_method.complete(payment.response_code, options)
      record_response(response)
      apply_state!(response)
      response
    end

    private

    def apply_state!(response)
      if response.authorization.present?
        payment.response_code = response.authorization
        payment.save!
      end

      response.success? ? mark_completed : mark_failed
    end

    def mark_completed
      if payment.payment_method.auto_capture?
        payment.complete! if can_transition?(:complete)
      elsif can_transition?(:pend)
        payment.pend!
      end
    end

    def mark_failed
      payment.failure! if can_transition?(:failure)
    end

    def can_transition?(event)
      payment.public_send(:"can_#{event}?")
    end

    def record_response(response)
      payment.log_entries.create!(parsed_payment_response_details_with_fallback: response)
    end
  end
end
