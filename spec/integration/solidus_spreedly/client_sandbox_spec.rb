# frozen_string_literal: true

require "spec_helper"

# Live Spreedly sandbox integration coverage for the HTTP client. The first run
# (with SPREEDLY_* credentials in the env) records a VCR cassette per example;
# every later run replays the committed cassette with no network or credentials.
#
# See spec/support/solidus_spreedly/sandbox.rb for the recording workflow.
RSpec.describe SolidusSpreedly::Client, :spreedly_sandbox do
  let(:currency) { "USD" }
  let(:amount) { 1000 }
  let(:order_id) do
    "SPEC-GATEWAY-#{RSpec.current_example.description.gsub(/[^A-Za-z0-9]+/, "-").upcase}"
  end

  describe ":gateway orchestration mode" do
    describe "#purchase" do
      it "authorizes and captures in one call", vcr: {cassette_name: "spreedly_sandbox/gateway/purchase"} do
        token = create_test_payment_method
        response = client.purchase(amount, token, currency: currency, order_id: order_id)

        expect(response).to be_success
        expect(response.authorization).to be_present
        expect(response.params.dig("transaction", "transaction_type")).to eq("Purchase")
        expect(response.params.dig("transaction", "state")).to eq("succeeded")
      end
    end

    describe "#authorize then #capture" do
      it "holds funds, then captures the transaction", vcr: {cassette_name: "spreedly_sandbox/gateway/authorize_capture"} do
        token = create_test_payment_method
        auth = client.authorize(amount, token, currency: currency, order_id: order_id)

        expect(auth).to be_success
        expect(auth.params.dig("transaction", "transaction_type")).to eq("Authorization")

        capture = client.capture(amount, auth.authorization, currency: currency)

        expect(capture).to be_success
        expect(capture.params.dig("transaction", "transaction_type")).to eq("Capture")
      end
    end

    describe "#authorize then #void" do
      it "reverses an uncaptured authorization", vcr: {cassette_name: "spreedly_sandbox/gateway/authorize_void"} do
        token = create_test_payment_method
        auth = client.authorize(amount, token, currency: currency, order_id: order_id)
        expect(auth).to be_success

        void = client.void(auth.authorization)

        expect(void).to be_success
        expect(void.params.dig("transaction", "transaction_type")).to eq("Void")
      end
    end

    describe "#purchase then #credit (refund)" do
      it "refunds a settled purchase", vcr: {cassette_name: "spreedly_sandbox/gateway/purchase_credit"} do
        token = create_test_payment_method
        purchase = client.purchase(amount, token, currency: currency, order_id: order_id)
        expect(purchase).to be_success

        credit = client.credit(amount, purchase.authorization, currency: currency)

        expect(credit).to be_success
        expect(credit.params.dig("transaction", "transaction_type")).to eq("Credit")
      end
    end

    describe "#show" do
      it "fetches the current state of a transaction", vcr: {cassette_name: "spreedly_sandbox/gateway/show"} do
        token = create_test_payment_method
        purchase = client.purchase(amount, token, currency: currency, order_id: order_id)
        expect(purchase).to be_success

        shown = client.show(purchase.authorization)

        expect(shown).to be_success
        expect(shown.params.dig("transaction", "token")).to eq(purchase.authorization)
      end
    end

    describe "#store (retain)" do
      it "retains a payment method in the vault", vcr: {cassette_name: "spreedly_sandbox/gateway/store"} do
        token = create_test_payment_method
        response = client.store(token)

        expect(response).to be_success
        expect(response.params.dig("transaction", "payment_method", "storage_state")).to eq("retained")
      end
    end

    describe "a declined purchase" do
      it "maps a gateway decline into an unsuccessful response",
        vcr: {cassette_name: "spreedly_sandbox/gateway/purchase_declined"} do
        # The Braintree sandbox declines amounts in the $2000-$2999 range, which
        # lets us exercise the real failure-mapping path with a test card.
        token = create_test_payment_method
        response = client.purchase(200_000, token, currency: currency, order_id: order_id)

        expect(response).not_to be_success
        expect(response.error_code).to be_present
      end
    end
  end

  describe "the Stripe gateway token (3DS-capable)" do
    it "runs a purchase through the Stripe test gateway",
      vcr: {cassette_name: "spreedly_sandbox/gateway/stripe_purchase"} do
      token = create_test_payment_method
      response = client.purchase(amount, token, currency: currency, order_id: order_id, gateway_token: stripe_gateway_token)

      # A frictionless test card succeeds; a challenge card returns "pending"
      # and would require the 3DS2 completion path.
      expect(response.params.dig("transaction", "state")).to be_in(%w[succeeded pending])
    end

    it "authorizes and captures through the Stripe test gateway",
      vcr: {cassette_name: "spreedly_sandbox/gateway/stripe_authorize_capture"} do
      token = create_test_payment_method
      auth = client.authorize(amount, token, currency: currency, order_id: order_id, gateway_token: stripe_gateway_token)

      expect(auth).to be_success
      expect(auth.params.dig("transaction", "transaction_type")).to eq("Authorization")

      capture = client.capture(amount, auth.authorization, currency: currency)

      expect(capture).to be_success
      expect(capture.params.dig("transaction", "transaction_type")).to eq("Capture")
    end

    it "refunds a purchase made through the Stripe test gateway",
      vcr: {cassette_name: "spreedly_sandbox/gateway/stripe_purchase_credit"} do
      token = create_test_payment_method
      purchase = client.purchase(amount, token, currency: currency, order_id: order_id, gateway_token: stripe_gateway_token)

      expect(purchase).to be_success

      credit = client.credit(amount, purchase.authorization, currency: currency)

      expect(credit).to be_success
      expect(credit.params.dig("transaction", "transaction_type")).to eq("Credit")
    end
  end

  describe "the explicit Braintree gateway token" do
    it "runs a purchase through the configured Braintree gateway token",
      vcr: {cassette_name: "spreedly_sandbox/gateway/braintree_explicit_purchase"} do
      token = create_test_payment_method
      response = client.purchase(amount, token, currency: currency, order_id: order_id, gateway_token: gateway_token)

      expect(response).to be_success
      expect(response.authorization).to be_present
      expect(response.params.dig("transaction", "state")).to eq("succeeded")
    end
  end
end
