# frozen_string_literal: true

require "solidus_core"
require "solidus_support"

module SolidusSpreedly
  class Engine < Rails::Engine
    include SolidusSupport::EngineExtensions

    isolate_namespace ::Spree

    engine_name "solidus_spreedly"

    # Register the gateway as an available payment method type (so it shows up
    # in the admin "New Payment Method" dropdown) and permit the Spreedly source
    # attributes the storefront submits. `config.spree.payment_methods` is a
    # ClassConstantizer::Set, so it dedups the entry by class name.
    initializer "solidus_spreedly.register_payment_method", after: "spree.register.payment_methods" do |app|
      config.to_prepare do
        app.config.spree.payment_methods << "SolidusSpreedly::Gateway"

        ::Spree::PermittedAttributes.source_attributes.concat(
          %i[
            payment_method_token
            payment_method_type
            card_type
            last_digits
            month
            year
            first_name
            last_name
            email
          ]
        ).uniq!
      end
    end

    # Allow the Spreedly response wrapper to be deserialized from payment log
    # entries (ActiveMerchant::Billing::Response is already permitted by core).
    initializer "solidus_spreedly.log_entry_permitted_classes" do
      Spree.config do |config|
        config.log_entry_permitted_classes << "SolidusSpreedly::Response"
        config.log_entry_permitted_classes.uniq!
      end
    end

    # use rspec for tests
    config.generators do |g|
      g.test_framework :rspec
    end
  end
end
