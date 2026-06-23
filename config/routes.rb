# frozen_string_literal: true

Spree::Core::Engine.routes.draw do
  # 3DS2 / pending-transaction completion callback.
  #
  # The leading slash on the controller escapes the engine's isolated +Spree+
  # namespace so it resolves to +SolidusSpreedly::CompletionsController+ rather
  # than +Spree::SolidusSpreedly::...+.
  match "/solidus_spreedly/payments/:payment_id/complete",
    to: "/solidus_spreedly/completions#create",
    via: %i[get post],
    as: :solidus_spreedly_complete_payment
end
