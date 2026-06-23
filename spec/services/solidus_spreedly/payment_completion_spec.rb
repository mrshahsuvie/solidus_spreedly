# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusSpreedly::PaymentCompletion do
  let(:auto_capture) { true }
  let(:payment_method) { create(:solidus_spreedly_payment_method, auto_capture: auto_capture) }
  let(:source) { create(:solidus_spreedly_source, payment_method: payment_method) }
  let(:order) { create(:order) }
  let(:payment) do
    create(
      :payment,
      order: order,
      payment_method: payment_method,
      source: source,
      amount: 10,
      response_code: "TXN123"
    ).tap { |p| p.update!(state: "pending") }
  end

  def spreedly_response(succeeded:, state:, token: "TXN999")
    ActiveMerchant::Billing::Response.new(
      succeeded,
      "message",
      {"transaction" => {"token" => token, "succeeded" => succeeded, "state" => state}},
      authorization: token,
      test: true
    )
  end

  describe "#call" do
    context "when the completion succeeds" do
      let(:response) { spreedly_response(succeeded: true, state: "succeeded") }

      before { allow(payment.payment_method).to receive(:complete).and_return(response) }

      it "completes an auto-capture payment (pending -> completed)" do
        described_class.new(payment).call

        expect(payment.reload.state).to eq("completed")
      end

      it "stores the new transaction token and logs the response" do
        expect { described_class.new(payment).call }.to change { payment.log_entries.count }.by(1)

        expect(payment.reload.response_code).to eq("TXN999")
      end

      it "passes completion context through to the gateway" do
        expect(payment.payment_method).to receive(:complete)
          .with("TXN123", hash_including(browser_info: {"java_enabled" => false}))
          .and_return(response)

        described_class.new(payment, browser_info: {"java_enabled" => false}).call
      end

      context "when the payment method only authorizes (no auto-capture)" do
        let(:auto_capture) { false }

        it "leaves the payment pending for a later capture" do
          described_class.new(payment).call

          expect(payment.reload.state).to eq("pending")
        end
      end
    end

    context "when the completion fails" do
      let(:response) { spreedly_response(succeeded: false, state: "gateway_processing_failed") }

      before { allow(payment.payment_method).to receive(:complete).and_return(response) }

      it "fails the payment (pending -> failed)" do
        described_class.new(payment).call

        expect(payment.reload.state).to eq("failed")
      end
    end

    context "when the payment has no transaction to complete" do
      it "raises a MissingTransactionError" do
        payment.update!(response_code: nil)

        expect { described_class.new(payment).call }
          .to raise_error(described_class::MissingTransactionError)
      end
    end
  end
end
