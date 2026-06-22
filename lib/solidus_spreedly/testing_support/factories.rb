# frozen_string_literal: true

FactoryBot.define do
  factory :solidus_spreedly_payment_method, class: "SolidusSpreedly::Gateway" do
    name { "Spreedly" }
    preferred_environment_key { "test-environment-key" }
    preferred_access_secret { "test-access-secret" }
    preferred_gateway_token { "test-gateway-token" }
  end

  factory :solidus_spreedly_source, class: "SolidusSpreedly::Source" do
    payment_method_token { "test-payment-method-token" }
    payment_method_type { "credit_card" }
    last_digits { "1111" }
    card_type { "visa" }
    month { "12" }
    year { (Time.current.year + 1).to_s }

    association :payment_method, factory: :solidus_spreedly_payment_method
  end
end
