# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Spreedly 3DS2 completion", type: :request do
  let!(:store) { create(:store, default: true) }
  let(:payment_method) { create(:solidus_spreedly_payment_method, auto_capture: true) }
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

  let(:complete_url) { "https://core.spreedly.com/v1/transactions/TXN123/complete.json" }

  def complete_body(succeeded:, state:)
    {
      transaction: {
        token: "TXN123",
        succeeded: succeeded,
        state: state,
        message: succeeded ? "Succeeded!" : "Failed.",
        response: {avs_code: nil, cvv_code: nil}
      }
    }.to_json
  end

  context "when the transaction completes successfully" do
    before { stub_request(:post, complete_url).to_return(status: 200, body: complete_body(succeeded: true, state: "succeeded")) }

    it "completes the payment and returns the resulting state as JSON" do
      post "/solidus_spreedly/payments/#{payment.id}/complete", headers: {"Accept" => "application/json"}

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["state"]).to eq("succeeded")
      expect(payment.reload.state).to eq("completed")
    end
  end

  context "when the transaction fails to complete" do
    before do
      stub_request(:post, complete_url)
        .to_return(status: 422, body: complete_body(succeeded: false, state: "gateway_processing_failed"))
    end

    it "fails the payment and responds with an unprocessable status" do
      post "/solidus_spreedly/payments/#{payment.id}/complete", headers: {"Accept" => "application/json"}

      expect(response).to have_http_status(:unprocessable_entity)
      expect(payment.reload.state).to eq("failed")
    end
  end

  context "when the payment does not exist" do
    it "returns not found" do
      post "/solidus_spreedly/payments/0/complete", headers: {"Accept" => "application/json"}

      expect(response).to have_http_status(:not_found)
    end
  end
end
