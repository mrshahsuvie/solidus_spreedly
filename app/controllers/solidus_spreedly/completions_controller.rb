# frozen_string_literal: true

module SolidusSpreedly
  # Finishes a pending Spreedly transaction after the buyer has gone through a
  # 3DS2 challenge.
  #
  # Spreedly redirects the buyer back to this endpoint (the +callback_url+/
  # +redirect_url+ configured on the original transaction), at which point we
  # call the completion endpoint and reflect the result onto the payment via
  # {SolidusSpreedly::PaymentCompletion}.
  #
  # It responds with JSON for API/SPA storefronts and, when a +redirect_url+ is
  # supplied, with an HTML redirect for classic server-rendered storefronts.
  class CompletionsController < ::Spree::BaseController
    skip_before_action :verify_authenticity_token, raise: false

    def create
      payment = ::Spree::Payment.find(params[:payment_id])
      response = SolidusSpreedly::PaymentCompletion.new(payment, completion_options).call
      respond_with_result(payment, response)
    rescue ActiveRecord::RecordNotFound
      head :not_found
    rescue SolidusSpreedly::PaymentCompletion::MissingTransactionError => e
      render json: {error: e.message}, status: :unprocessable_entity
    end

    private

    def respond_with_result(payment, response)
      wrapped = SolidusSpreedly::Response.from_response(response)
      status = response.success? ? :ok : :unprocessable_entity

      respond_to do |format|
        format.json do
          render json: {state: wrapped.state, payment_state: payment.state, message: wrapped.friendly_message},
            status: status
        end
        format.html { redirect_to redirect_url, allow_other_host: true }
      end
    end

    def completion_options
      {
        browser_info: params[:browser_info].presence,
        device_fingerprint: params[:device_fingerprint].presence
      }.compact
    end

    def redirect_url
      params[:redirect_url].presence || spree.root_path
    end
  end
end
