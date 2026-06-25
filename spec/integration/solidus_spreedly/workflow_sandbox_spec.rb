# frozen_string_literal: true

require "spec_helper"

# Live Spreedly sandbox coverage for :workflow (composer) orchestration and the
# configured 3DS2 / SCA provider response. Recorded/replayed exactly like
# client_sandbox_spec.rb.
RSpec.describe "SolidusSpreedly::Client workflow orchestration", :spreedly_sandbox do
  let(:currency) { "USD" }
  let(:amount) { 1000 }
  let(:order_id) do
    "SPEC-WORKFLOW-#{RSpec.current_example.description.gsub(/[^A-Za-z0-9]+/, "-").upcase}"
  end

  # Routes through a Spreedly composer workflow instead of a single gateway.
  let(:workflow_client) do
    client(orchestration_mode: :workflow, workflow_key: workflow_key, gateway_token: nil)
  end

  # Only meaningful with a real workflow configured in the Spreedly environment.
  before do
    if SolidusSpreedly::SpecSupport::Sandbox.credentials_present? && ENV["SPREEDLY_WORKFLOW_KEY"].blank?
      skip "Set SPREEDLY_WORKFLOW_KEY to record the :workflow orchestration specs"
    end
  end

  describe "#purchase via workflow" do
    it "purchases through the composer workflow", vcr: {cassette_name: "spreedly_sandbox/workflow/purchase"} do
      token = create_test_payment_method
      response = workflow_client.purchase(amount, token, currency: currency, order_id: order_id)

      expect(response).to be_success
      expect(response.authorization).to be_present
      expect(response.params.dig("transaction", "state")).to eq("succeeded")
    end
  end

  describe "#authorize then #capture via workflow" do
    it "authorizes through the workflow, then captures (transaction-scoped)",
      vcr: {cassette_name: "spreedly_sandbox/workflow/authorize_capture"} do
      token = create_test_payment_method
      auth = workflow_client.authorize(amount, token, currency: currency, order_id: order_id)
      expect(auth).to be_success

      # Capture is always transaction-scoped, so a gateway-mode client finishes it.
      capture = client.capture(amount, auth.authorization, currency: currency)

      expect(capture).to be_success
      expect(capture.params.dig("transaction", "transaction_type")).to eq("Capture")
    end
  end

  describe "#purchase then #credit via workflow" do
    it "purchases through the workflow, then refunds transaction-scoped",
      vcr: {cassette_name: "spreedly_sandbox/workflow/purchase_credit"} do
      token = create_test_payment_method
      purchase = workflow_client.purchase(amount, token, currency: currency, order_id: order_id)

      expect(purchase).to be_success
      expect(purchase.authorization).to be_present

      credit = client.credit(amount, purchase.authorization, currency: currency)

      expect(credit).to be_success
      expect(credit.params.dig("transaction", "transaction_type")).to eq("Credit")
    end
  end

  describe "3DS2 / SCA" do
    # Spreedly's gateway-specific 3DS2 test data. Amount 3004 drives a device
    # fingerprint + challenge flow when the configured SCA provider is valid.
    let(:challenge_card) { {number: "4556761029983886", month: 10, year: 2029} }

    it "records the live Spreedly SCA response for the configured provider",
      vcr: {cassette_name: "spreedly_sandbox/threeds/purchase_pending"} do
      token = create_test_payment_method(card: challenge_card)
      response = client.purchase(
        3004,
        token,
        currency: currency,
        order_id: order_id,
        gateway_token: stripe_gateway_token,
        sca_provider_key: sca_provider_key,
        browser_info: {"java_enabled" => false},
        redirect_url: "https://example.com/return",
        callback_url: "https://example.com/callback"
      )

      transaction_state = response.params.dig("transaction", "state")
      error_keys = Array(response.params["errors"]).map { |error| error["key"] }

      expect(transaction_state).to be_in(%w[pending succeeded]).or be_nil
      expect(response.authorization).to be_present if transaction_state == "pending"
      expect(error_keys).to include("errors.sca_provider_not_found") if transaction_state.nil?
    end
  end
end
