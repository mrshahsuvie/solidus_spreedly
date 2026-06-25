# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Solidus order processing with Spreedly", :spreedly_sandbox do
  let(:amount) { BigDecimal("10.0") }

  def spreedly_gateway(**attributes)
    gateway_token_preference = attributes.delete(:preferred_gateway_token) do
      SolidusSpreedly::SpecSupport::Sandbox.gateway_token
    end

    create(:solidus_spreedly_payment_method, attributes).tap do |gateway|
      gateway.preferred_environment_key = SolidusSpreedly::SpecSupport::Sandbox.environment_key
      gateway.preferred_access_secret = SolidusSpreedly::SpecSupport::Sandbox.access_secret
      gateway.preferred_gateway_token = gateway_token_preference
      gateway.save!
    end
  end

  def spreedly_source(gateway, token: create_test_payment_method)
    create(:solidus_spreedly_source, payment_method: gateway, payment_method_token: token)
  end

  def order_with_spreedly_payment(gateway:, source:, line_items_price: amount, shipment_cost: 0, user: :default)
    order_attributes = {
      line_items_price: line_items_price,
      shipment_cost: shipment_cost
    }
    order_attributes[:user] = user unless user == :default
    order_attributes[:email] = "guest@example.com" if user.nil?

    order = create(
      :order_ready_to_complete,
      order_attributes
    )

    source.update!(user: order.user)

    payment = order.payments.first
    payment.update!(
      payment_method: gateway,
      source: source,
      response_code: nil
    )

    order.reload
  end

  shared_examples "completes the order payment" do |cassette_name|
    it "completes the order and payment", vcr: {cassette_name: cassette_name} do
      expect(order.complete!).to be(true)

      payment = order.payments.reload.first
      expect(order.reload).to be_completed
      expect(payment).to be_completed
      expect(payment.response_code).to be_present
      expect(payment.log_entries).to be_present
      expect(order.user.wallet.default_wallet_payment_source.payment_source).to eq(source)
      expect(order.payment_state).to eq("paid")
    end
  end

  context "with the default Braintree gateway token" do
    let(:gateway) { spreedly_gateway(auto_capture: true) }
    let(:source) { spreedly_source(gateway) }
    let(:order) { order_with_spreedly_payment(gateway: gateway, source: source) }

    it_behaves_like "completes the order payment", "spreedly_sandbox/order/default_gateway_complete"
  end

  context "with the Stripe gateway token" do
    let(:gateway) { spreedly_gateway(auto_capture: true, preferred_gateway_token: stripe_gateway_token) }
    let(:source) { spreedly_source(gateway) }
    let(:order) { order_with_spreedly_payment(gateway: gateway, source: source) }

    it_behaves_like "completes the order payment", "spreedly_sandbox/order/stripe_gateway_complete"
  end

  context "with workflow orchestration" do
    let(:gateway) do
      spreedly_gateway(
        auto_capture: true,
        preferred_orchestration_mode: "workflow",
        preferred_workflow_key: workflow_key
      )
    end
    let(:source) { spreedly_source(gateway) }
    let(:order) { order_with_spreedly_payment(gateway: gateway, source: source) }

    it_behaves_like "completes the order payment", "spreedly_sandbox/order/workflow_complete"
  end

  context "with authorize-only payment" do
    let(:gateway) { spreedly_gateway(auto_capture: false) }
    let(:source) { spreedly_source(gateway) }
    let(:order) { order_with_spreedly_payment(gateway: gateway, source: source) }

    it "authorizes the payment and completes the order",
      vcr: {cassette_name: "spreedly_sandbox/order/default_gateway_authorize"} do
      expect(order.complete!).to be(true)

      payment = order.payments.reload.first
      expect(order.reload).to be_completed
      expect(payment).to be_pending
      expect(payment.response_code).to be_present
      expect(payment.log_entries).to be_present
      expect(order.user.wallet.default_wallet_payment_source.payment_source).to eq(source)
    end
  end

  context "with a guest order" do
    let(:gateway) { spreedly_gateway(auto_capture: true) }
    let(:source) { spreedly_source(gateway) }
    let(:order) { order_with_spreedly_payment(gateway: gateway, source: source, user: nil) }

    it "completes the payment without trying to save a wallet source",
      vcr: {cassette_name: "spreedly_sandbox/order/guest_default_gateway_complete"} do
      expect(order.complete!).to be(true)

      payment = order.payments.reload.first
      expect(order.reload).to be_completed
      expect(payment).to be_completed
      expect(payment.response_code).to be_present
      expect(source.reload.user).to be_nil
    end
  end

  context "when the order is already covered by a completed Spreedly payment" do
    let(:gateway) { spreedly_gateway(auto_capture: true) }
    let(:source) { spreedly_source(gateway, token: "already-completed-token") }
    let(:order) { order_with_spreedly_payment(gateway: gateway, source: source) }

    it "completes the order without creating another gateway log entry" do
      payment = order.payments.first
      payment.update!(state: "completed", response_code: "existing-spreedly-transaction")

      expect(order.complete!).to be(true)

      expect(order.reload).to be_completed
      expect(payment.reload).to be_completed
      expect(payment.log_entries).to be_empty
      expect(order.user.wallet.default_wallet_payment_source.payment_source).to eq(source)
    end
  end

  context "when the payment source is missing" do
    let(:gateway) { spreedly_gateway(auto_capture: true) }
    let(:source) { spreedly_source(gateway, token: "unused-token") }
    let(:order) { order_with_spreedly_payment(gateway: gateway, source: source) }

    it "does not call Spreedly and keeps the order incomplete" do
      payment = order.payments.first
      payment.update_columns(source_type: nil, source_id: nil)

      expect { order.complete! }
        .to raise_error(StateMachines::InvalidTransition, /Payment could not be processed/)

      expect(order.reload).not_to be_completed
      expect(payment.reload).to be_checkout
      expect(payment.log_entries).to be_empty
    end
  end

  context "with SCA enabled" do
    let(:challenge_card) { {number: "4556761029983886", month: 10, year: 2029} }
    let(:gateway) do
      spreedly_gateway(
        auto_capture: true,
        preferred_gateway_token: stripe_gateway_token,
        preferred_sca_provider_key: sca_provider_key
      )
    end
    let(:source) { spreedly_source(gateway, token: create_test_payment_method(card: challenge_card)) }
    let(:order) do
      order_with_spreedly_payment(
        gateway: gateway,
        source: source,
        line_items_price: BigDecimal("30.04")
      )
    end

    it "does not complete the order while SCA is pending or unavailable",
      vcr: {cassette_name: "spreedly_sandbox/order/sca_purchase_pending"} do
      expect { order.complete! }
        .to raise_error(StateMachines::InvalidTransition, /pending|SCA|sca|provider|authenticate/i)

      payment = order.payments.reload.first
      expect(order.reload).not_to be_completed
      expect(payment).to be_failed
      expect(payment.log_entries).to be_present
    end
  end

  context "when Spreedly declines the purchase" do
    let(:gateway) { spreedly_gateway(auto_capture: true) }
    let(:source) { spreedly_source(gateway) }
    let(:order) do
      # Braintree sandbox declines transactions in the $2000-$2999 range.
      order_with_spreedly_payment(
        gateway: gateway,
        source: source,
        line_items_price: BigDecimal("2000.0")
      )
    end

    it "fails the payment and does not complete the order",
      vcr: {cassette_name: "spreedly_sandbox/order/default_gateway_declined"} do
      expect { order.complete! }
        .to raise_error(StateMachines::InvalidTransition, /2000 Do Not Honor/)

      payment = order.payments.reload.first
      expect(order.reload).not_to be_completed
      expect(payment).to be_failed
      expect(payment.log_entries).to be_present
      expect(order.errors[:base]).to be_present
    end

    it "returns false from non-bang complete and keeps the order incomplete",
      vcr: {cassette_name: "spreedly_sandbox/order/default_gateway_declined"} do
      expect(order.complete).to be(false)

      payment = order.payments.reload.first
      expect(order.reload).not_to be_completed
      expect(payment).to be_failed
      expect(order.errors[:base]).to include(/2000 Do Not Honor/)
    end
  end
end
