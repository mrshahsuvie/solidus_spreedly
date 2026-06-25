# frozen_string_literal: true

require "spec_helper"

# Live Spreedly sandbox coverage that drives the Solidus-facing payment method
# (SolidusSpreedly::Gateway) end to end, proving the adapter threads
# orchestration mode + routing through to real Spreedly transactions.
RSpec.describe SolidusSpreedly::Gateway, :spreedly_sandbox do
  subject(:gateway) do
    create(:solidus_spreedly_payment_method).tap do |gw|
      gw.preferred_environment_key = SolidusSpreedly::SpecSupport::Sandbox.environment_key
      gw.preferred_access_secret = SolidusSpreedly::SpecSupport::Sandbox.access_secret
      gw.preferred_gateway_token = SolidusSpreedly::SpecSupport::Sandbox.gateway_token
    end
  end

  let(:source) { create(:solidus_spreedly_source, payment_method: gateway, payment_method_token: create_test_payment_method) }
  let(:gateway_options) do
    {
      currency: "USD",
      order_id: "SPEC-MODEL-#{RSpec.current_example.description.gsub(/[^A-Za-z0-9]+/, "-").upcase}",
      email: "buyer@example.com",
      ip: "127.0.0.1"
    }
  end

  describe "#purchase" do
    it "purchases through the configured gateway token", vcr: {cassette_name: "spreedly_sandbox/model/purchase"} do
      response = gateway.purchase(1000, source, gateway_options)

      expect(response).to be_success
      expect(response.authorization).to be_present
    end
  end

  describe "#authorize and #capture" do
    it "authorizes then captures", vcr: {cassette_name: "spreedly_sandbox/model/authorize_capture"} do
      auth = gateway.authorize(1000, source, gateway_options)
      expect(auth).to be_success

      capture = gateway.capture(1000, auth.authorization, gateway_options)
      expect(capture).to be_success
    end
  end

  describe "#credit" do
    it "refunds a completed purchase", vcr: {cassette_name: "spreedly_sandbox/model/credit"} do
      purchase = gateway.purchase(1000, source, gateway_options)
      expect(purchase).to be_success

      credit = gateway.credit(1000, source, purchase.authorization, gateway_options)
      expect(credit).to be_success
    end
  end

  describe "#try_void" do
    it "voids a still-voidable authorization", vcr: {cassette_name: "spreedly_sandbox/model/try_void"} do
      auth = gateway.authorize(1000, source, gateway_options)
      payment = instance_double(Spree::Payment, response_code: auth.authorization, source: source)

      response = gateway.try_void(payment)

      expect(response).to be_truthy
      expect(response.success?).to be(true)
    end
  end
end
