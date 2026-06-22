# frozen_string_literal: true

module SolidusSpreedly
  # Payment source for the Spreedly gateway.
  #
  # The only value used to move money is +payment_method_token+ (the Spreedly
  # vault token). Everything else is display-only metadata captured client-side
  # so the source can be rendered in the storefront/admin without another API
  # round-trip.
  class Source < ::Spree::PaymentSource
    self.table_name = "solidus_spreedly_sources"

    belongs_to :user, class_name: ::Spree::UserClassHandle.new, optional: true
    belongs_to :payment_method, class_name: "Spree::PaymentMethod", optional: true

    has_many :payments, as: :source, class_name: "Spree::Payment", dependent: :destroy

    validates :payment_method_token, presence: true

    scope :with_payment_profile, -> { where.not(payment_method_token: nil) }

    # Match Spree::CreditCard's interface so existing storefront / admin
    # partials keep working. (Defined as methods rather than +alias_method+
    # because ActiveRecord attribute readers are generated lazily.)
    def last_4
      last_digits
    end

    def cc_type
      card_type
    end

    def actions
      %w[capture void credit]
    end

    def can_capture?(payment)
      payment.pending? || payment.checkout?
    end

    def can_void?(payment)
      payment.can_void?
    end

    def can_credit?(payment)
      payment.completed? && payment.credit_allowed > 0
    end

    # A source can be charged again as long as it carries a vault token.
    def reusable?
      payment_method_token.present?
    end

    def display_number
      "XXXX-XXXX-XXXX-#{last_digits.to_s.rjust(4, "X")}"
    end

    def display_payment_type
      I18n.t(
        "solidus_spreedly.payment_type",
        default: "Spreedly"
      )
    end
  end
end
