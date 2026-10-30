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

  describe "#retain_on_success_for" do
    it "defaults to false when no per-call store key and preference is false" do
      expect(gateway.retain_on_success_for(source, gateway_options)).to be(false)
    end

    it "returns the preference when no per-call store key is present" do
      gateway.preferred_retain_on_success = true

      expect(gateway.retain_on_success_for(source, gateway_options)).to be(true)
    end

    it "honors an explicit per-call store: true over a false preference" do
      gateway.preferred_retain_on_success = false

      expect(gateway.retain_on_success_for(source, gateway_options.merge(store: true))).to be(true)
    end

    it "honors an explicit per-call store: false over a true preference" do
      gateway.preferred_retain_on_success = true

      expect(gateway.retain_on_success_for(source, gateway_options.merge(store: false))).to be(false)
    end
  end

  describe "#attempt_network_token_for" do
    it "defaults to false when no per-call key and preference is false" do
      expect(gateway.attempt_network_token_for(source, gateway_options)).to be(false)
    end

    it "returns the preference when no per-call key is present" do
      gateway.preferred_attempt_network_token = true

      expect(gateway.attempt_network_token_for(source, gateway_options)).to be(true)
    end

    it "honors an explicit per-call true over a false preference" do
      gateway.preferred_attempt_network_token = false

      expect(gateway.attempt_network_token_for(source, gateway_options.merge(attempt_network_token: true))).to be(true)
    end

    it "honors an explicit per-call false over a true preference" do
      gateway.preferred_attempt_network_token = true

      expect(gateway.attempt_network_token_for(source, gateway_options.merge(attempt_network_token: false))).to be(false)
    end
  end

  describe "#provision_network_token_for" do
    it "defaults to false when no per-call key and preference is false" do
      expect(gateway.provision_network_token_for(source, gateway_options)).to be(false)
    end

    it "returns the preference when no per-call key is present" do
      gateway.preferred_provision_network_token = true

      expect(gateway.provision_network_token_for(source, gateway_options)).to be(true)
    end

    it "honors an explicit per-call true over a false preference" do
      gateway.preferred_provision_network_token = false

      expect(gateway.provision_network_token_for(source, gateway_options.merge(provision_network_token: true))).to be(true)
    end

    it "honors an explicit per-call false over a true preference" do
      gateway.preferred_provision_network_token = true

      expect(gateway.provision_network_token_for(source, gateway_options.merge(provision_network_token: false))).to be(false)
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

      it "forwards transaction metadata when provided in gateway_options" do
        options = gateway_options.merge(transaction_metadata: {canary: "true", migration_phase: "1"})

        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_including(transaction_metadata: {canary: "true", migration_phase: "1"})
        ).and_return(success_response)

        gateway.purchase(1000, source, options)
      end

      it "omits metadata when gateway_options has none" do
        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_not_including(:transaction_metadata)
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

      it "omits store when retain_on_success is off by default" do
        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_not_including(:store)
        ).and_return(success_response)

        gateway.purchase(1000, source, gateway_options)
      end

      it "passes store: true when the retain_on_success preference is enabled" do
        gateway.preferred_retain_on_success = true

        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_including(store: true)
        ).and_return(success_response)

        gateway.purchase(1000, source, gateway_options)
      end

      it "honors an explicit per-call store: false over a true preference" do
        gateway.preferred_retain_on_success = true

        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_not_including(:store)
        ).and_return(success_response)

        gateway.purchase(1000, source, gateway_options.merge(store: false))
      end

      it "omits network tokenization flags by default" do
        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_not_including(:attempt_network_token, :provision_network_token)
        ).and_return(success_response)

        gateway.purchase(1000, source, gateway_options)
      end

      it "passes attempt_network_token when the preference is enabled" do
        gateway.preferred_attempt_network_token = true

        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_including(attempt_network_token: true)
        ).and_return(success_response)

        gateway.purchase(1000, source, gateway_options)
      end

      it "passes provision_network_token when the preference is enabled" do
        gateway.preferred_provision_network_token = true

        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_including(provision_network_token: true)
        ).and_return(success_response)

        gateway.purchase(1000, source, gateway_options)
      end

      it "honors a per-call attempt_network_token override over the preference" do
        gateway.preferred_attempt_network_token = true

        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_not_including(:attempt_network_token)
        ).and_return(success_response)

        gateway.purchase(1000, source, gateway_options.merge(attempt_network_token: false))
      end

      it "forwards stored credential options from gateway_options" do
        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_including(
            stored_credential_initiator: :merchant,
            stored_credential_reason_type: :recurring,
            stored_credential_alternate_gateway: :scheme_issued
          )
        ).and_return(success_response)

        gateway.purchase(
          1000,
          source,
          gateway_options.merge(
            stored_credential_initiator: :merchant,
            stored_credential_reason_type: :recurring,
            stored_credential_alternate_gateway: :scheme_issued
          )
        )
      end

      it "omits stored credential options when not provided" do
        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_not_including(
            :stored_credential_initiator,
            :stored_credential_reason_type,
            :stored_credential_alternate_gateway
          )
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

      it "routes through the overridable workflow_key_for hook" do
        allow(gateway).to receive(:workflow_key_for).and_return("CANARY_WORKFLOW")

        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_including(orchestration_mode: :workflow, workflow_key: "CANARY_WORKFLOW")
        ).and_return(success_response)

        gateway.purchase(1000, source, gateway_options)
      end

      it "passes store: true in workflow mode when the retain_on_success preference is enabled" do
        gateway.preferred_retain_on_success = true

        expect(client).to receive(:purchase).with(
          1000,
          "PMT123",
          hash_including(orchestration_mode: :workflow, workflow_key: "WF999", store: true)
        ).and_return(success_response)

        gateway.purchase(1000, source, gateway_options)
      end
    end
  end

  describe "#routing_options" do
    it "returns gateway_token in :gateway mode" do
      expect(gateway.send(:routing_options, source, gateway_options))
        .to eq(gateway_token: "GATEWAY123")
    end

    it "returns workflow_key in :workflow mode" do
      gateway.preferred_orchestration_mode = "workflow"
      gateway.preferred_workflow_key = "WF999"

      expect(gateway.send(:routing_options, source, gateway_options))
        .to eq(workflow_key: "WF999")
    end
  end

  describe "#transaction_metadata_for" do
    it "defaults to gateway_options[:transaction_metadata]" do
      metadata = {canary: "true"}

      expect(gateway.transaction_metadata_for(source, gateway_options.merge(transaction_metadata: metadata)))
        .to eq(metadata)
    end

    it "returns an empty hash when metadata is absent" do
      expect(gateway.transaction_metadata_for(source, gateway_options)).to eq({})
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

  describe "#verify" do
    it "delegates to the client with routing and SCA options" do
      gateway.preferred_sca_provider_key = "SCA1"

      expect(client).to receive(:verify).with(
        "PMT123",
        hash_including(
          orchestration_mode: :gateway,
          gateway_token: "GATEWAY123",
          sca_provider_key: "SCA1",
          browser_info: "eyJ3aWR0aCI6MX0=",
          store: true,
          currency: "USD"
        )
      ).and_return(success_response)

      expect(
        gateway.verify(
          "PMT123",
          browser_info: "eyJ3aWR0aCI6MX0=",
          currency: "USD"
        )
      ).to eq(success_response)
    end

    it "omits store when options[:store] is false" do
      expect(client).to receive(:verify).with(
        "PMT123",
        hash_not_including(:store)
      ).and_return(success_response)

      gateway.verify("PMT123", store: false)
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

    it "returns false for a succeeded Stripe purchase without voiding" do
      allow(gateway).to receive(:show).with("TXN123")
        .and_return(transaction_response({
          "succeeded" => true,
          "transaction_type" => "Purchase",
          "gateway_type" => "stripe_payment_intents"
        }))
      expect(client).not_to receive(:void)

      expect(gateway.try_void(payment)).to be(false)
    end

    it "voids a succeeded Braintree purchase" do
      allow(gateway).to receive(:show).with("TXN123")
        .and_return(transaction_response({
          "succeeded" => true,
          "transaction_type" => "Purchase",
          "gateway_type" => "braintree"
        }))
      expect(client).to receive(:void).with("TXN123").and_return(success_response)

      expect(gateway.try_void(payment)).to eq(success_response)
    end

    it "voids a succeeded Stripe authorization" do
      allow(gateway).to receive(:show).with("TXN123")
        .and_return(transaction_response({
          "succeeded" => true,
          "transaction_type" => "Authorization",
          "gateway_type" => "stripe"
        }))
      expect(client).to receive(:void).with("TXN123").and_return(success_response)

      expect(gateway.try_void(payment)).to eq(success_response)
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

    it "refunds a succeeded Stripe purchase without voiding" do
      allow(gateway).to receive(:show).with("TXN123")
        .and_return(transaction_response({
          "succeeded" => true,
          "transaction_type" => "Purchase",
          "gateway_type" => "stripe_payment_intents"
        }))
      expect(client).not_to receive(:void)
      expect(client).to receive(:refund).with(nil, "TXN123", {}).and_return(success_response)

      expect(gateway.cancel("TXN123")).to eq(success_response)
    end
  end

  describe "#stored_transaction" do
    let(:persisted_gateway) { create(:solidus_spreedly_payment_method) }
    let(:source) { create(:solidus_spreedly_source, payment_method: persisted_gateway) }
    let(:payment) do
      create(
        :payment,
        payment_method: persisted_gateway,
        source: source,
        response_code: "TXN123",
        state: "completed",
        amount: 10
      )
    end

    def store_response(payment_record, token:, gateway_type: "braintree", transaction_type: "Purchase")
      payment_record.log_entries.create!(
        parsed_details: ActiveMerchant::Billing::Response.new(
          true,
          "Succeeded!",
          {
            "transaction" => {
              "succeeded" => true,
              "token" => token,
              "transaction_type" => transaction_type,
              "gateway_type" => gateway_type
            }
          },
          authorization: token
        )
      )
    end

    it "returns the transaction whose token matches the payment and ignores other entries" do
      allow(persisted_gateway).to receive(:client).and_return(client)
      store_response(payment, token: "OTHER")
      match = store_response(payment, token: "TXN123", gateway_type: "stripe_payment_intents")

      expect(client).not_to receive(:show)
      expect(persisted_gateway.stored_transaction(payment)).to eq(
        match.parsed_details.params["transaction"]
      )
    end

    it "returns nil when no entry matches" do
      store_response(payment, token: "OTHER")

      expect(persisted_gateway.stored_transaction(payment)).to be_nil
    end

    it "returns nil when the only entry cannot be parsed" do
      payment.log_entries.create!(details: "--- !ruby/object:Object {}\n")

      expect(persisted_gateway.stored_transaction(payment)).to be_nil
    end

    it "skips an unparseable entry and still matches an older one" do
      match = store_response(payment, token: "TXN123")
      payment.log_entries.create!(details: "--- !ruby/object:Object {}\n")

      expect(persisted_gateway.stored_transaction(payment.reload)).to eq(
        match.parsed_details.params["transaction"]
      )
    end
  end

  describe "#voidable_payment?" do
    let(:persisted_gateway) { create(:solidus_spreedly_payment_method) }
    let(:payment) do
      instance_double(Spree::Payment, response_code: "TXN123", log_entries: Spree::LogEntry.none)
    end

    it "returns true when there is no stored entry" do
      allow(persisted_gateway).to receive(:stored_transaction).with(payment).and_return(nil)

      expect(persisted_gateway.voidable_payment?(payment)).to be(true)
    end

    it "returns false for a stored Stripe purchase" do
      allow(persisted_gateway).to receive(:stored_transaction).with(payment).and_return(
        {"succeeded" => true, "transaction_type" => "Purchase", "gateway_type" => "stripe_payment_intents"}
      )

      expect(persisted_gateway.voidable_payment?(payment)).to be(false)
    end
  end

  describe "#void_refused?" do
    let(:persisted_gateway) { create(:solidus_spreedly_payment_method) }

    it "is false for a pending payment" do
      payment = instance_double(Spree::Payment, completed?: false)

      expect(persisted_gateway.void_refused?(payment)).to be(false)
    end

    it "is true for a completed Stripe purchase" do
      payment = instance_double(Spree::Payment, completed?: true)
      allow(persisted_gateway).to receive(:voidable_payment?).with(payment).and_return(false)

      expect(persisted_gateway.void_refused?(payment)).to be(true)
    end

    it "is false for a completed payment the policy still allows" do
      payment = instance_double(Spree::Payment, completed?: true)
      allow(persisted_gateway).to receive(:voidable_payment?).with(payment).and_return(true)

      expect(persisted_gateway.void_refused?(payment)).to be(false)
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
