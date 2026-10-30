# frozen_string_literal: true

module SolidusSpreedly
  # Decides whether a Spreedly transaction can still be voided.
  #
  # Consumers can replace this class with +SolidusSpreedly.config.void_policy_class+
  # (a String class name). Override the predicate methods to change one rule
  # without copying the rest.
  class VoidPolicy
    # Transaction types that already reverse a charge and cannot be voided.
    REVERSAL_TRANSACTION_TYPES = %w[void credit].freeze

    # Stripe gateways cannot cancel a captured PaymentIntent. Refund instead.
    STRIPE_GATEWAY_TYPES = %w[stripe stripe_payment_intents].freeze

    STRIPE_NON_VOIDABLE_TRANSACTION_TYPE = "purchase"

    # @param transaction [Hash, nil] Spreedly transaction hash (+succeeded+,
    #   +transaction_type+, +gateway_type+)
    # @return [Boolean]
    def voidable?(transaction)
      return false unless succeeded?(transaction)
      return false if reversal?(transaction)
      return false if stripe_purchase?(transaction)

      true
    end

    # @param transaction [Hash, nil]
    # @return [Boolean]
    def succeeded?(transaction)
      transaction.is_a?(Hash) && transaction["succeeded"].present?
    end

    # @param transaction [Hash, nil]
    # @return [Boolean]
    def reversal?(transaction)
      REVERSAL_TRANSACTION_TYPES.include?(transaction_type(transaction))
    end

    # Captured Stripe purchases cannot be voided. Authorizations still can.
    #
    # @param transaction [Hash, nil]
    # @return [Boolean]
    def stripe_purchase?(transaction)
      stripe_gateway?(transaction) && transaction_type(transaction) == STRIPE_NON_VOIDABLE_TRANSACTION_TYPE
    end

    # @param transaction [Hash, nil]
    # @return [Boolean]
    def stripe_gateway?(transaction)
      STRIPE_GATEWAY_TYPES.include?(gateway_type(transaction))
    end

    # @param transaction [Hash, nil]
    # @return [String]
    def transaction_type(transaction)
      field(transaction, "transaction_type")
    end

    # @param transaction [Hash, nil]
    # @return [String]
    def gateway_type(transaction)
      field(transaction, "gateway_type")
    end

    private

    def field(transaction, key)
      return "" unless transaction.is_a?(Hash)

      transaction[key].to_s.downcase
    end
  end
end
