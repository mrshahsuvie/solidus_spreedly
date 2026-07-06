# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusSpreedly::Client do
  subject(:client) do
    described_class.new(
      login: "env-key",
      password: "access-secret",
      gateway_token: "GATEWAY123"
    )
  end

  let(:base_url) { "https://core.spreedly.com/v1" }
  let(:payment_method_token) { "PMT123" }

  def succeeded_body(state: "succeeded", token: "TXN123")
    {
      transaction: {
        token: token,
        succeeded: state == "succeeded",
        state: state,
        message: "Succeeded!",
        on_test_gateway: true,
        response: {avs_code: "D", cvv_code: "M"},
        payment_method: {token: payment_method_token}
      }
    }.to_json
  end

  def failed_body
    {
      transaction: {
        token: "TXNFAIL",
        succeeded: false,
        state: "gateway_processing_failed",
        message: "Unable to process the purchase transaction.",
        response: {
          success: false,
          message: "Unable to process the purchase transaction.",
          error_code: "processor_declined",
          avs_code: nil,
          cvv_code: nil
        }
      }
    }.to_json
  end

  def stripe_declined_body
    {
      transaction: {
        token: "TXNDECLINED",
        succeeded: false,
        state: "gateway_processing_failed",
        message: "Your card was declined.",
        response: {
          success: false,
          message: "Your card was declined.",
          error_code: "card_declined",
          avs_code: nil,
          cvv_code: nil
        }
      }
    }.to_json
  end

  def add_payment_method_body(token: "PMT123", transaction_token: "TXNADD123")
    {
      transaction: {
        token: transaction_token,
        succeeded: true,
        state: "succeeded",
        transaction_type: "AddPaymentMethod",
        message: "Succeeded!",
        on_test_gateway: true,
        payment_method: {
          token: token,
          storage_state: "retained",
          payment_method_type: "credit_card",
          last_four_digits: "1111",
          card_type: "visa"
        }
      }
    }.to_json
  end

  def add_payment_method_failed_body
    {
      transaction: {
        token: "TXNFAIL",
        succeeded: false,
        state: "failed",
        transaction_type: "AddPaymentMethod",
        message: "Unable to process the payment method.",
        errors: [{key: "errors.invalid", message: "Credit card number is invalid"}]
      }
    }.to_json
  end

  describe "#purchase" do
    context "in :gateway mode (default)" do
      it "POSTs to the gateway-scoped purchase endpoint with a transaction body" do
        stub = stub_request(:post, "#{base_url}/gateways/GATEWAY123/purchase.json")
          .with(
            headers: {
              "Authorization" => "Basic #{Base64.strict_encode64("env-key:access-secret")}",
              "Content-Type" => "application/json"
            },
            body: {
              transaction: {
                payment_method_token: payment_method_token,
                amount: 1000,
                currency_code: "USD"
              }
            }
          )
          .to_return(status: 200, body: succeeded_body)

        response = client.purchase(1000, payment_method_token, currency: "USD")

        expect(stub).to have_been_requested
        expect(response).to be_success
        expect(response.authorization).to eq("TXN123")
        expect(response.avs_result["code"]).to eq("D")
        expect(response.cvv_result["code"]).to eq("M")
        expect(response.test).to be(true)
      end

      it "can route a purchase through an explicit Stripe gateway token with 3DS callback fields" do
        stub = stub_request(:post, "#{base_url}/gateways/STRIPE_GATEWAY/purchase.json")
          .with(
            body: {
              transaction: {
                payment_method_token: payment_method_token,
                amount: 1000,
                currency_code: "USD",
                sca_provider_key: "SCA1",
                attempt_3dsecure: true,
                redirect_url: "https://example.com/return",
                callback_url: "https://example.com/callback"
              }
            }
          )
          .to_return(status: 200, body: succeeded_body(state: "pending"))

        response = client.purchase(
          1000,
          payment_method_token,
          currency: "USD",
          gateway_token: "STRIPE_GATEWAY",
          sca_provider_key: "SCA1",
          redirect_url: "https://example.com/return",
          callback_url: "https://example.com/callback"
        )

        expect(stub).to have_been_requested
        expect(response).not_to be_success
        expect(response.params.dig("transaction", "state")).to eq("pending")
      end

      it "passes Braintree gateway-specific fields through the transaction body" do
        stub = stub_request(:post, "#{base_url}/gateways/GATEWAY123/purchase.json")
          .with(
            body: {
              transaction: {
                payment_method_token: payment_method_token,
                amount: 1000,
                currency_code: "USD",
                gateway_specific_fields: {
                  braintree: {
                    transaction_source: "recurring"
                  }
                }
              }
            }
          )
          .to_return(status: 200, body: succeeded_body)

        response = client.purchase(
          1000,
          payment_method_token,
          currency: "USD",
          gateway_specific_fields: {
            braintree: {
              transaction_source: "recurring"
            }
          }
        )

        expect(stub).to have_been_requested
        expect(response).to be_success
      end

      it "raises when no gateway_token is configured" do
        tokenless = described_class.new(login: "env-key", password: "access-secret")

        expect { tokenless.purchase(1000, payment_method_token) }
          .to raise_error(ArgumentError, /gateway_token is required/)
      end
    end

    context "in :workflow mode" do
      it "POSTs to the composer purchase endpoint with the workflow_key" do
        stub = stub_request(:post, "#{base_url}/transactions/purchase.json")
          .with(
            body: {
              transaction: {
                payment_method_token: payment_method_token,
                amount: 1000,
                currency_code: "USD",
                workflow_key: "WF999"
              }
            }
          )
          .to_return(status: 200, body: succeeded_body)

        response = client.purchase(
          1000,
          payment_method_token,
          currency: "USD",
          orchestration_mode: :workflow,
          workflow_key: "WF999"
        )

        expect(stub).to have_been_requested
        expect(response).to be_success
      end

      it "uses workflow mode and workflow_key configured on the client" do
        workflow_client = described_class.new(
          login: "env-key",
          password: "access-secret",
          orchestration_mode: :workflow,
          workflow_key: "WF999"
        )

        stub = stub_request(:post, "#{base_url}/transactions/purchase.json")
          .with(
            body: {
              transaction: {
                payment_method_token: payment_method_token,
                amount: 1000,
                currency_code: "USD",
                workflow_key: "WF999"
              }
            }
          )
          .to_return(status: 200, body: succeeded_body)

        response = workflow_client.purchase(1000, payment_method_token, currency: "USD")

        expect(stub).to have_been_requested
        expect(response).to be_success
      end
    end

    it "adds 3DS2 fields when an sca_provider_key is supplied" do
      stub = stub_request(:post, "#{base_url}/gateways/GATEWAY123/purchase.json")
        .with(
          body: {
            transaction: {
              payment_method_token: payment_method_token,
              amount: 1000,
              currency_code: "USD",
              sca_provider_key: "SCA1",
              attempt_3dsecure: true,
              browser_info: {"java_enabled" => false}
            }
          }
        )
        .to_return(status: 200, body: succeeded_body(state: "pending"))

      response = client.purchase(
        1000,
        payment_method_token,
        currency: "USD",
        sca_provider_key: "SCA1",
        browser_info: {"java_enabled" => false}
      )

      expect(stub).to have_been_requested
      expect(response).not_to be_success
    end

    it "treats a pending transaction as not yet successful" do
      stub_request(:post, "#{base_url}/gateways/GATEWAY123/purchase.json")
        .to_return(status: 200, body: succeeded_body(state: "pending"))

      response = client.purchase(1000, payment_method_token, currency: "USD")

      expect(response).not_to be_success
      expect(response.params.dig("transaction", "state")).to eq("pending")
    end

    it "includes transaction metadata in the request body when provided" do
      stub = stub_request(:post, "#{base_url}/gateways/GATEWAY123/purchase.json")
        .with(
          body: {
            transaction: {
              payment_method_token: payment_method_token,
              amount: 1000,
              currency_code: "USD",
              transaction_metadata: {canary: "true", migration_phase: "1"}
            }
          }
        )
        .to_return(status: 200, body: succeeded_body)

      response = client.purchase(
        1000,
        payment_method_token,
        currency: "USD",
        transaction_metadata: {canary: "true", migration_phase: "1"}
      )

      expect(stub).to have_been_requested
      expect(response).to be_success
    end

    it "maps a gateway failure into an unsuccessful response" do
      stub_request(:post, "#{base_url}/gateways/GATEWAY123/purchase.json")
        .to_return(status: 422, body: failed_body)

      response = client.purchase(1000, payment_method_token, currency: "USD")

      expect(response).not_to be_success
      expect(response.message).to eq("Unable to process the purchase transaction.")
      expect(response.error_code).to eq("processor_declined")
    end

    it "maps a Stripe-style gateway decline using nested response fields" do
      stub_request(:post, "#{base_url}/gateways/GATEWAY123/purchase.json")
        .to_return(status: 200, body: stripe_declined_body)

      response = client.purchase(1000, payment_method_token, currency: "USD")

      expect(response).not_to be_success
      expect(response.message).to eq("Your card was declined.")
      expect(response.error_code).to eq("card_declined")
    end
  end

  describe "#authorize" do
    it "POSTs to the gateway-scoped authorize endpoint" do
      stub = stub_request(:post, "#{base_url}/gateways/GATEWAY123/authorize.json")
        .to_return(status: 200, body: succeeded_body)

      response = client.authorize(1000, payment_method_token, currency: "USD")

      expect(stub).to have_been_requested
      expect(response).to be_success
    end
  end

  describe "#capture" do
    it "POSTs to the transaction-scoped capture endpoint with the amount" do
      stub = stub_request(:post, "#{base_url}/transactions/TXN123/capture.json")
        .with(body: {transaction: {amount: 1000, currency_code: "USD"}})
        .to_return(status: 200, body: succeeded_body)

      response = client.capture(1000, "TXN123", currency: "USD")

      expect(stub).to have_been_requested
      expect(response).to be_success
    end

    it "sends an empty body when capturing the full amount" do
      stub = stub_request(:post, "#{base_url}/transactions/TXN123/capture.json")
        .with(body: "")
        .to_return(status: 200, body: succeeded_body)

      client.capture(nil, "TXN123")

      expect(stub).to have_been_requested
    end
  end

  describe "#void" do
    it "POSTs to the transaction-scoped void endpoint regardless of mode" do
      stub = stub_request(:post, "#{base_url}/transactions/TXN123/void.json")
        .to_return(status: 200, body: succeeded_body)

      response = client.void("TXN123")

      expect(stub).to have_been_requested
      expect(response).to be_success
    end
  end

  describe "#refund / #credit" do
    it "POSTs to the transaction-scoped credit endpoint with the amount" do
      stub = stub_request(:post, "#{base_url}/transactions/TXN123/credit.json")
        .with(body: {transaction: {amount: 500, currency_code: "USD"}})
        .to_return(status: 200, body: succeeded_body)

      response = client.credit(500, "TXN123", currency: "USD")

      expect(stub).to have_been_requested
      expect(response).to be_success
    end
  end

  describe "#complete" do
    it "POSTs to the transaction-scoped complete endpoint for 3DS2" do
      stub = stub_request(:post, "#{base_url}/transactions/TXN123/complete.json")
        .to_return(status: 200, body: succeeded_body)

      response = client.complete("TXN123")

      expect(stub).to have_been_requested
      expect(response).to be_success
    end
  end

  describe "#show / #find" do
    it "GETs the transaction-scoped show endpoint" do
      stub = stub_request(:get, "#{base_url}/transactions/TXN123.json")
        .to_return(status: 200, body: succeeded_body)

      response = client.show("TXN123")

      expect(stub).to have_been_requested
      expect(response).to be_success
    end
  end

  describe "#create_payment_method / #add_payment_method" do
    let(:credit_card) do
      {
        first_name: "John",
        last_name: "Doe",
        number: "4111111111111111",
        verification_value: "123",
        month: 12,
        year: 2029
      }
    end

    it "POSTs to the payment_methods endpoint with a retained credit card" do
      stub = stub_request(:post, "#{base_url}/payment_methods.json")
        .with(
          headers: {
            "Authorization" => "Basic #{Base64.strict_encode64("env-key:access-secret")}",
            "Content-Type" => "application/json"
          },
          body: {
            payment_method: {
              credit_card: credit_card,
              retained: true
            }
          }
        )
        .to_return(status: 201, body: add_payment_method_body)

      response = client.create_payment_method(credit_card: credit_card)

      expect(stub).to have_been_requested
      expect(response).to be_success
      expect(response.authorization).to eq("PMT123")
      expect(response.params.dig("transaction", "transaction_type")).to eq("AddPaymentMethod")
    end

    it "creates a non-retained payment method when retain: false" do
      stub = stub_request(:post, "#{base_url}/payment_methods.json")
        .with(
          body: {
            payment_method: {
              credit_card: credit_card,
              retained: false
            }
          }
        )
        .to_return(status: 201, body: add_payment_method_body)

      response = client.add_payment_method(credit_card: credit_card, retain: false)

      expect(stub).to have_been_requested
      expect(response).to be_success
    end

    it "accepts a full payment_method payload" do
      stub = stub_request(:post, "#{base_url}/payment_methods.json")
        .with(
          body: {
            payment_method: {
              credit_card: credit_card,
              retained: true,
              email: "buyer@example.com"
            }
          }
        )
        .to_return(status: 201, body: add_payment_method_body)

      response = client.create_payment_method(
        payment_method: {credit_card: credit_card, email: "buyer@example.com"}
      )

      expect(stub).to have_been_requested
      expect(response).to be_success
    end

    it "maps validation failures into an unsuccessful response" do
      stub_request(:post, "#{base_url}/payment_methods.json")
        .to_return(status: 422, body: add_payment_method_failed_body)

      response = client.create_payment_method(credit_card: credit_card)

      expect(response).not_to be_success
      expect(response.message).to eq("Unable to process the payment method.")
    end

    it "raises when no payment method attributes are supplied" do
      expect { client.create_payment_method }
        .to raise_error(ArgumentError, /credit_card, bank_account, or payment_method is required/)
    end
  end

  describe "#store / #retain" do
    it "PUTs to the payment-method retain endpoint" do
      stub = stub_request(:put, "#{base_url}/payment_methods/PMT123/retain.json")
        .to_return(status: 200, body: succeeded_body)

      response = client.store("PMT123")

      expect(stub).to have_been_requested
      expect(response).to be_success
    end
  end

  describe "#scrub" do
    it "filters credentials and card data out of a transcript" do
      transcript = <<~TRANSCRIPT
        Authorization: Basic ZW52LWtleTphY2Nlc3Mtc2VjcmV0
        {"transaction":{"number":"4111111111111111","verification_value":"123","payment_method_token":"PMT123"}}
      TRANSCRIPT

      scrubbed = client.scrub(transcript)

      expect(client.supports_scrubbing?).to be(true)
      expect(scrubbed).to include("Authorization: Basic [FILTERED]")
      expect(scrubbed).not_to include("4111111111111111")
      expect(scrubbed).not_to include('"123"')
      expect(scrubbed).not_to include("PMT123")
    end
  end
end
