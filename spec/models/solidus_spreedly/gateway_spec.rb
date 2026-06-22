# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusSpreedly::Gateway do
  subject(:gateway) do
    described_class.new(name: "Spreedly").tap do |gw|
      gw.preferred_environment_key = "env-key"
      gw.preferred_access_secret = "access-secret"
      gw.preferred_gateway_token = "GATEWAY123"
    end
  end

  let(:client) { instance_double(SolidusSpreedly::Client) }
  # Source is introduced in Phase 3; use a lightweight stand-in here.
  let(:source) { double("SolidusSpreedly::Source", payment_method_token: "PMT123") }
  let(:gateway_options) do
    {currency: "USD", order_id: "R123-1", email: "buyer@example.com", ip: "1.2.3.4"}
  end
  let(:success_response) { instance_double(ActiveMerchant::Billing::Response, success?: true) }

  before { allow(gateway).to receive(:client).and_return(client) }

  def transaction_response(transaction, success: true)
    instance_double(
      ActiveMerchant::Billing::Response,
      success?: success,
      params: {"transaction" => transaction}
    )
  end

  describe "configuration" do
    it "defaults the orchestration mode to :gateway" do
      expect(gateway.orchestration_mode).to eq(:gateway)
    end

    it "supports payment profiles (token reuse)" do
      expect(gateway.payment_profiles_supported?).to be(true)
    end

    it 'uses the "spreedly" partial' do
      expect(gateway.partial_name).to eq("spreedly")
      expect(gateway.method_type).to eq("spreedly")
    end
  end

  describe "#client" do
    it "builds a client from the configured credentials and mode" do
      allow(gateway).to receive(:client).and_call_original

      expect(SolidusSpreedly::Client).to receive(:new).with(
        hash_including(
          login: "env-key",
          password: "access-secret",
          gateway_token: "GATEWAY123",
          orchestration_mode: :gateway
        )
      )

      gateway.client
    end
  end

  describe "#purchase" do
    context "in :gateway mode (default)" do
      it "delegates to the client with the configured gateway_token" do
        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_including(orchestration_mode: :gateway, gateway_token: "GATEWAY123", currency: "USD")
        ).and_return(success_response)

        expect(gateway.purchase(1000, source, gateway_options)).to eq(success_response)
      end

      it "routes through the overridable gateway_token_for hook" do
        allow(gateway).to receive(:gateway_token_for).and_return("CANARY_GATEWAY")

        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_including(gateway_token: "CANARY_GATEWAY")
        ).and_return(success_response)

        gateway.purchase(1000, source, gateway_options)
      end

      it "forwards a configured SCA provider key for 3DS2" do
        gateway.preferred_sca_provider_key = "SCA1"

        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_including(sca_provider_key: "SCA1")
        ).and_return(success_response)

        gateway.purchase(1000, source, gateway_options)
      end
    end

    context "in :workflow mode" do
      before do
        gateway.preferred_orchestration_mode = "workflow"
        gateway.preferred_workflow_key = "WF999"
      end

      it "delegates with the workflow_key and no gateway_token" do
        expect(client).to receive(:purchase) do |cents, token, options|
          expect(cents).to eq(1000)
          expect(token).to eq("PMT123")
          expect(options).to include(orchestration_mode: :workflow, workflow_key: "WF999")
          expect(options).not_to have_key(:gateway_token)
          success_response
        end

        gateway.purchase(1000, source, gateway_options)
      end
    end
  end

  describe "#authorize" do
    it "delegates to the client authorize endpoint" do
      expect(client).to receive(:authorize).with(
        1000,
        "PMT123",
        hash_including(orchestration_mode: :gateway, gateway_token: "GATEWAY123")
      ).and_return(success_response)

      gateway.authorize(1000, source, gateway_options)
    end
  end

  describe "#capture" do
    it "delegates to the transaction-scoped capture with the currency" do
      expect(client).to receive(:capture).with(1000, "TXN123", {currency: "USD"}).and_return(success_response)

      gateway.capture(1000, "TXN123", gateway_options)
    end
  end

  describe "#void" do
    it "delegates to the transaction-scoped void, ignoring the source" do
      expect(client).to receive(:void).with("TXN123").and_return(success_response)

      gateway.void("TXN123", source, gateway_options)
    end
  end

  describe "#credit" do
    it "delegates to the transaction-scoped refund" do
      expect(client).to receive(:refund).with(500, "TXN123", {currency: "USD"}).and_return(success_response)

      gateway.credit(500, source, "TXN123", gateway_options)
    end
  end

  describe "#try_void" do
    let(:payment) { instance_double(Spree::Payment, response_code: "TXN123", source: source) }

    it "voids when the transaction is still voidable" do
      allow(gateway).to receive(:show).with("TXN123")
        .and_return(transaction_response({"succeeded" => true, "transaction_type" => "Authorization"}))
      expect(client).to receive(:void).with("TXN123").and_return(success_response)

      expect(gateway.try_void(payment)).to eq(success_response)
    end

    it "returns false when the transaction is no longer voidable" do
      allow(gateway).to receive(:show).with("TXN123")
        .and_return(transaction_response({"succeeded" => true, "transaction_type" => "Credit"}))
      expect(client).not_to receive(:void)

      expect(gateway.try_void(payment)).to be(false)
    end

    it "returns false when the void itself fails" do
      allow(gateway).to receive(:show).with("TXN123")
        .and_return(transaction_response({"succeeded" => true, "transaction_type" => "Purchase"}))
      allow(client).to receive(:void).with("TXN123")
        .and_return(instance_double(ActiveMerchant::Billing::Response, success?: false))

      expect(gateway.try_void(payment)).to be(false)
    end
  end

  describe "#cancel" do
    it "voids when the transaction is voidable and the void succeeds" do
      allow(gateway).to receive(:show).with("TXN123")
        .and_return(transaction_response({"succeeded" => true, "transaction_type" => "Authorization"}))
      expect(client).to receive(:void).with("TXN123").and_return(success_response)
      expect(client).not_to receive(:refund)

      expect(gateway.cancel("TXN123")).to eq(success_response)
    end

    it "refunds when the transaction can no longer be voided" do
      allow(gateway).to receive(:show).with("TXN123")
        .and_return(transaction_response({"succeeded" => true, "transaction_type" => "Credit"}))
      expect(client).to receive(:refund).with(nil, "TXN123", {}).and_return(success_response)

      expect(gateway.cancel("TXN123")).to eq(success_response)
    end

    it "refunds when a voidable transaction fails to void" do
      allow(gateway).to receive(:show).with("TXN123")
        .and_return(transaction_response({"succeeded" => true, "transaction_type" => "Purchase"}))
      allow(client).to receive(:void).with("TXN123")
        .and_return(instance_double(ActiveMerchant::Billing::Response, success?: false))
      expect(client).to receive(:refund).with(nil, "TXN123", {}).and_return(success_response)

      expect(gateway.cancel("TXN123")).to eq(success_response)
    end
  end

  describe "#reusable_sources" do
    let(:persisted_gateway) { create(:solidus_spreedly_payment_method) }
    let(:user) { create(:user) }

    it "returns the user's vaulted sources for this payment method" do
      mine = create(:solidus_spreedly_source, payment_method: persisted_gateway, user: user, payment_method_token: "PMT-mine")
      _other_user = create(:solidus_spreedly_source, payment_method: persisted_gateway, user: create(:user), payment_method_token: "PMT-other")
      order = create(:order, user: user)

      expect(persisted_gateway.reusable_sources(order)).to contain_exactly(mine)
    end

    it "returns nothing for a guest order" do
      order = create(:order, user: nil)

      expect(persisted_gateway.reusable_sources(order)).to eq([])
    end
  end
end
