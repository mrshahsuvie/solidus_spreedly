# frozen_string_literal: true

require "active_merchant"

module SolidusSpreedly
  # Thin JSON client for the Spreedly Core API.
  #
  # It subclasses +ActiveMerchant::Billing::Gateway+ so it can reuse the SSL
  # plumbing (+ssl_post+/+ssl_get+) and return standard
  # +ActiveMerchant::Billing::Response+ objects, while speaking JSON instead of
  # the XML that the bundled +SpreedlyCoreGateway+ uses.
  #
  # Two orchestration modes are supported for the money-moving calls
  # (+purchase+/+authorize+):
  #
  #   * +:gateway+  - routes through a specific Spreedly gateway you configured:
  #                   POST /v1/gateways/{gateway_token}/purchase.json
  #   * +:workflow+ - routes through a Spreedly composer workflow:
  #                   POST /v1/transactions/purchase.json (with +workflow_key+)
  #
  # Every follow-up call (+capture+, +void+, +credit+, +complete+, +show+) is
  # transaction-scoped and therefore mode-independent.
  class Client < ::ActiveMerchant::Billing::Gateway
    self.live_url = "https://core.spreedly.com/v1"

    self.supported_countries = ::ActiveMerchant::Billing::SpreedlyCoreGateway.supported_countries
    self.supported_cardtypes = %i[visa master american_express discover]
    self.homepage_url = "https://spreedly.com"
    self.display_name = "Spreedly"
    self.money_format = :cents
    self.default_currency = "USD"

    # A Spreedly transaction whose +state+ is "pending" is awaiting an
    # additional step (most commonly a 3DS2 challenge) and must be finished
    # via #complete.
    PENDING_STATE = "pending"

    # Public: Build a new client.
    #
    # options - A hash of credentials:
    #           :login    - The Spreedly environment key (required).
    #           :password - The Spreedly access secret (required).
    def initialize(options = {})
      requires!(options, :login, :password)
      super
    end

    # Public: Run a purchase (authorize + capture in one step).
    #
    # money          - The amount in cents.
    # payment_method - The Spreedly payment method token (String).
    # options        - See #build_transaction_body, plus routing options:
    #                  :orchestration_mode     - :gateway (default) or :workflow.
    #                  :gateway_token          - Required in :gateway mode.
    #                  :workflow_key           - Optional in :workflow mode.
    #                  :transaction_metadata   - Optional hash of transaction metadata.
    #                  :attempt_network_token  - Prefer a network token when available.
    #                  :provision_network_token - Request NT provisioning (with retain).
    #                  :store                  - Retain the payment method on success.
    def purchase(money, payment_method, options = {})
      commit(:post, transaction_path("purchase", options), build_transaction_body(money, payment_method, options))
    end

    # Public: Run an authorization (funds held, captured later).
    #
    # See #purchase for the argument shape.
    def authorize(money, payment_method, options = {})
      commit(:post, transaction_path("authorize", options), build_transaction_body(money, payment_method, options))
    end

    # Public: Capture a previously authorized transaction.
    #
    # money         - The amount in cents to capture (nil captures the full
    #                 authorized amount).
    # authorization - The Spreedly transaction token of the authorization.
    def capture(money, authorization, options = {})
      commit(:post, "transactions/#{authorization}/capture.json", build_amount_body(money, options))
    end

    # Public: Void (cancel) a transaction that has not yet settled.
    #
    # authorization - The Spreedly transaction token to void.
    def void(authorization, options = {})
      commit(:post, "transactions/#{authorization}/void.json", build_gateway_specific_body(options))
    end

    # Public: Refund (credit) a settled transaction. Maps to Solidus' +credit+.
    #
    # money         - The amount in cents to refund (nil refunds the full
    #                 captured amount).
    # authorization - The Spreedly transaction token to credit.
    def refund(money, authorization, options = {})
      commit(:post, "transactions/#{authorization}/credit.json", build_amount_body(money, options))
    end

    alias_method :credit, :refund

    # Public: Complete a pending transaction (e.g. after a 3DS2 challenge).
    #
    # authorization - The Spreedly transaction token returned in the "pending"
    #                 state.
    def complete(authorization, options = {})
      commit(:post, "transactions/#{authorization}/complete.json", build_complete_body(options))
    end

    # Public: Fetch the current state of a transaction.
    #
    # authorization - The Spreedly transaction token to look up.
    def show(authorization, options = {})
      commit(:get, "transactions/#{authorization}.json", nil)
    end

    alias_method :find, :show

    # Public: Create a payment method in Spreedly (AddPaymentMethod).
    #
    # Vaults card or bank-account details in Spreedly and returns a reusable
    # payment method token in +response.authorization+.
    #
    # options - A hash describing the payment method:
    #           :credit_card  - Hash of card attributes (number, month, year, ...).
    #           :bank_account - Hash of bank-account attributes.
    #           :payment_method - Full payment_method payload (overrides the above).
    #           :retain       - Whether to retain in the vault (default: true).
    #           :provision_network_token - Request a network token while retaining
    #                                      (Advanced Vault; requires TRIDs).
    #           :email, :data - Optional metadata fields.
    #
    # @return [ActiveMerchant::Billing::Response]
    def create_payment_method(options = {})
      commit(:post, "payment_methods.json", build_payment_method_body(options))
    end

    alias_method :add_payment_method, :create_payment_method

    # Public: Retain (vault) a payment method so it can be reused.
    #
    # payment_method_token - The Spreedly payment method token to retain.
    # options              - Optional hash:
    #                        :provision_network_token - Request a network token
    #                          for the retained payment method (Advanced Vault).
    def store(payment_method_token, options = {})
      commit(:put, "payment_methods/#{payment_method_token}/retain.json", build_retain_body(options))
    end

    alias_method :retain, :store

    def supports_scrubbing?
      true
    end

    # Public: Strip sensitive values out of a transcript before logging it.
    def scrub(transcript)
      transcript
        .gsub(%r{(Authorization: Basic )\w+}i, '\1[FILTERED]')
        .gsub(%r{("number\\?":\\?")[^"\\]*}i, '\1[FILTERED]')
        .gsub(%r{("verification_value\\?":\\?")[^"\\]*}i, '\1[FILTERED]')
        .gsub(%r{("payment_method_token\\?":\\?")[^"\\]*}i, '\1[FILTERED]')
    end

    private

    # Internal: Decide the request path for a money-moving call based on the
    # orchestration mode.
    def transaction_path(action, options)
      case orchestration_mode(options)
      when :workflow
        "transactions/#{action}.json"
      else
        gateway_token = options[:gateway_token] || @options[:gateway_token]
        raise ArgumentError, "gateway_token is required in :gateway orchestration mode" if gateway_token.to_s.empty?

        "gateways/#{gateway_token}/#{action}.json"
      end
    end

    def orchestration_mode(options)
      (options[:orchestration_mode] || @options[:orchestration_mode] || :gateway).to_sym
    end

    # Internal: Build the body for purchase/authorize.
    def build_transaction_body(money, payment_method, options)
      transaction = {
        payment_method_token: payment_method,
        amount: localized_amount(money, options[:currency] || currency(money)).to_i,
        currency_code: options[:currency] || currency(money) || default_currency
      }
      transaction[:order_id] = options[:order_id] if options[:order_id]
      transaction[:ip] = options[:ip] if options[:ip]
      transaction[:email] = options[:email] if options[:email]
      transaction[:description] = options[:description] if options[:description]
      transaction[:retain_on_success] = true if options[:store]
      if options[:transaction_metadata].is_a?(Hash) && options[:transaction_metadata].any?
        transaction[:transaction_metadata] = options[:transaction_metadata]
      end
      add_network_tokenization(transaction, options)

      add_three_ds(transaction, options)
      add_workflow_key(transaction, options)
      add_gateway_specific_fields(transaction, options)

      {transaction: transaction}
    end

    # Internal: Build a body that only carries an amount (capture/refund).
    def build_amount_body(money, options)
      transaction = {}
      unless money.nil?
        transaction[:amount] = localized_amount(money, options[:currency] || currency(money)).to_i
        transaction[:currency_code] = options[:currency] || currency(money) || default_currency
      end
      add_gateway_specific_fields(transaction, options)

      transaction.empty? ? nil : {transaction: transaction}
    end

    def build_gateway_specific_body(options)
      transaction = {}
      add_gateway_specific_fields(transaction, options)
      transaction.empty? ? nil : {transaction: transaction}
    end

    # Internal: Build the body for a 3DS2 completion call.
    def build_complete_body(options)
      transaction = {}
      transaction[:device_fingerprint] = options[:device_fingerprint] if options[:device_fingerprint]
      transaction[:browser_info] = options[:browser_info] if options[:browser_info]
      transaction.merge!(options[:context]) if options[:context].is_a?(Hash)
      transaction.empty? ? nil : {transaction: transaction}
    end

    # Internal: Build the body for POST /payment_methods.json.
    def build_payment_method_body(options)
      payment_method =
        if options[:payment_method].is_a?(Hash)
          options[:payment_method].dup
        else
          build_payment_method_attributes(options)
        end

      payment_method[:retained] = options.fetch(:retain, true) unless payment_method.key?(:retained)
      payment_method[:email] = options[:email] if options[:email] && !payment_method.key?(:email)
      payment_method[:data] = options[:data] if options[:data] && !payment_method.key?(:data)
      if options[:provision_network_token] && !payment_method.key?(:provision_network_token)
        payment_method[:provision_network_token] = true
      end

      {payment_method: payment_method}
    end

    def build_payment_method_attributes(options)
      if options[:credit_card].is_a?(Hash)
        {credit_card: options[:credit_card]}
      elsif options[:bank_account].is_a?(Hash)
        {bank_account: options[:bank_account]}
      else
        raise ArgumentError, "credit_card, bank_account, or payment_method is required"
      end
    end

    # Internal: Body for PUT retain. Only sent when provisioning a network token.
    def build_retain_body(options)
      return unless options[:provision_network_token]

      {payment_method: {provision_network_token: true}}
    end

    def add_network_tokenization(transaction, options)
      transaction[:attempt_network_token] = true if options[:attempt_network_token]
      transaction[:provision_network_token] = true if options[:provision_network_token]
    end

    def add_three_ds(transaction, options)
      transaction[:sca_provider_key] = options[:sca_provider_key] if options[:sca_provider_key]
      transaction[:attempt_3dsecure] = true if options[:sca_provider_key] || options[:attempt_3dsecure]
      transaction[:browser_info] = options[:browser_info] if options[:browser_info]
      transaction[:redirect_url] = options[:redirect_url] if options[:redirect_url]
      transaction[:callback_url] = options[:callback_url] if options[:callback_url]
    end

    def add_workflow_key(transaction, options)
      return unless orchestration_mode(options) == :workflow

      workflow_key = options[:workflow_key] || @options[:workflow_key]
      transaction[:workflow_key] = workflow_key if workflow_key
    end

    def add_gateway_specific_fields(transaction, options)
      fields = options[:gateway_specific_fields]
      transaction[:gateway_specific_fields] = fields if fields.is_a?(Hash) && fields.any?
    end

    def commit(method, path, body)
      url = "#{live_url}/#{path}"

      raw_response =
        begin
          case method
          when :get
            ssl_get(url, headers)
          when :put
            ssl_request(:put, url, body ? body.to_json : "", headers)
          else
            ssl_post(url, body ? body.to_json : "", headers)
          end
        rescue ::ActiveMerchant::ResponseError => e
          e.response.body
        end

      response_from(raw_response)
    end

    def response_from(raw_response)
      parsed = parse(raw_response)
      transaction = parsed["transaction"] || parsed
      gateway_response = transaction["response"] || {}

      ::ActiveMerchant::Billing::Response.new(
        success_from(transaction),
        message_from(transaction),
        parsed,
        authorization: authorization_from(transaction),
        avs_result: {code: gateway_response["avs_code"]},
        cvv_result: gateway_response["cvv_code"],
        test: transaction["on_test_gateway"] == true || test?,
        error_code: error_code_from(transaction)
      )
    end

    def parse(raw_response)
      return {} if raw_response.nil? || raw_response.empty?

      JSON.parse(raw_response)
    rescue JSON::ParserError
      {"errors" => [{"message" => "Invalid response received from Spreedly: #{raw_response.inspect}"}]}
    end

    def success_from(transaction)
      transaction["succeeded"] == true && transaction["state"] != PENDING_STATE
    end

    def gateway_response_from(transaction)
      response = transaction["response"]
      response.is_a?(Hash) ? response : {}
    end

    def message_from(transaction)
      gateway_response = gateway_response_from(transaction)

      gateway_response["message"].presence ||
        transaction["message"].presence ||
        Array(transaction["errors"]).map { |e| e["message"] }.compact.join(", ").presence ||
        transaction["state"]
    end

    def authorization_from(transaction)
      if transaction["transaction_type"] == "AddPaymentMethod"
        transaction.dig("payment_method", "token")
      else
        transaction["token"] || transaction.dig("payment_method", "token")
      end
    end

    def error_code_from(transaction)
      return if success_from(transaction)

      gateway_response = gateway_response_from(transaction)

      gateway_response["error_code"].presence ||
        Array(transaction["errors"]).map { |e| e["key"] }.compact.join(", ").presence ||
        transaction["state"]
    end

    def headers
      {
        "Authorization" => "Basic #{Base64.strict_encode64("#{@options[:login]}:#{@options[:password]}").chomp}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end
  end
end
