# frozen_string_literal: true

module SolidusSpreedly
  # Solidus payment method backed by the Spreedly Core API.
  #
  # This model is the Solidus-facing adapter: it exposes the standard
  # +Spree::PaymentMethod+ gateway interface (+purchase+, +authorize+,
  # +capture+, +void+, +credit+) and translates those calls into
  # {SolidusSpreedly::Client} requests, threading the configured orchestration
  # mode and routing information through.
  #
  class Gateway < ::Spree::PaymentMethod
    # Spreedly transaction types that represent a reversal already performed;
    # such transactions can never be voided again.
    REVERSAL_TRANSACTION_TYPES = %w[void credit].freeze

    preference :environment_key, :string, default: nil
    preference :access_secret, :string, default: nil

    # Orchestration mode: "gateway" (default) routes through a specific
    # Spreedly gateway, "workflow" routes through a Spreedly composer workflow.
    preference :orchestration_mode, :string, default: "gateway"

    # Used in :gateway mode. The token of the gateway configured in Spreedly.
    preference :gateway_token, :string, default: nil

    # Used (optionally) in :workflow mode. The composer workflow key.
    preference :workflow_key, :string, default: nil

    # Optional 3DS2 provider key, enabling the SCA flow on purchase/authorize.
    preference :sca_provider_key, :string, default: nil

    # When true, a successful purchase/authorize also retains (vaults) the card
    # for later reuse. Off by default so charging never vaults as a side effect.
    preference :retain_on_success, :boolean, default: false

    # When true, purchase/authorize attempt to use a Spreedly network token
    # (Advanced Vault). Spreedly falls back to PAN when NT is unusable.
    preference :attempt_network_token, :boolean, default: false

    # When true, request network-token provisioning while retaining a payment
    # method (create/retain, or purchase/authorize with retain_on_success).
    preference :provision_network_token, :boolean, default: false

    validates :preferred_retain_on_success, inclusion: {in: [true, false]}
    validates :preferred_attempt_network_token, inclusion: {in: [true, false]}
    validates :preferred_provision_network_token, inclusion: {in: [true, false]}

    def partial_name
      "spreedly"
    end
    alias_method :method_type, :partial_name

    def payment_source_class
      SolidusSpreedly::Source
    end

    # Returns the buyer's previously-vaulted Spreedly sources so they can be
    # reused at checkout. Spreedly has no server-side customer object, so we
    # simply scope retained sources by the order's user.
    #
    # @param order [Spree::Order]
    # @return [ActiveRecord::Relation, Array]
    def reusable_sources(order)
      return [] unless order.user_id

      payment_source_class
        .with_payment_profile
        .where(payment_method_id: id, user_id: order.user_id)
    end

    def client
      @client ||= SolidusSpreedly::Client.new(client_options)
    end

    # The orchestration mode as a symbol (:gateway or :workflow).
    def orchestration_mode
      (preferred_orchestration_mode || "gateway").to_sym
    end

    # Purchase (authorize + capture in one step).
    #
    # @param amount_cents [Integer] amount in cents
    # @param source [SolidusSpreedly::Source] the payment source
    # @param gateway_options [Hash] Solidus gateway options
    # @return [ActiveMerchant::Billing::Response]
    def purchase(amount_cents, source, gateway_options)
      client.purchase(amount_cents, payment_method_token_for(source), transaction_options(source, gateway_options))
    end

    # Authorize funds to be captured later.
    #
    # @see #purchase for the argument shape.
    def authorize(amount_cents, source, gateway_options)
      client.authorize(amount_cents, payment_method_token_for(source), transaction_options(source, gateway_options))
    end

    # Capture a previously authorized transaction (transaction-scoped, so it is
    # independent of the orchestration mode).
    #
    # @param amount_cents [Integer] amount in cents to capture
    # @param response_code [String] the Spreedly transaction token
    def capture(amount_cents, response_code, gateway_options = {})
      client.capture(amount_cents, response_code, currency_options(gateway_options))
    end

    # Void an unsettled transaction (transaction-scoped, mode-independent).
    #
    # The +source+ argument is part of the Solidus signature (payment profiles
    # are supported) but is unused: Spreedly voids are keyed by transaction
    # token alone.
    #
    # @param response_code [String] the Spreedly transaction token
    def void(response_code, _source = nil, _gateway_options = {})
      client.void(response_code)
    end

    # Refund a settled transaction (transaction-scoped, mode-independent). Maps
    # to the Solidus +credit+ signature used by +Spree::Refund+.
    #
    # @param amount_cents [Integer, nil] amount in cents (nil refunds in full)
    # @param response_code [String] the Spreedly transaction token
    def credit(amount_cents, _source, response_code, gateway_options = {})
      client.refund(amount_cents, response_code, currency_options(gateway_options))
    end

    # Fetch the current state of a Spreedly transaction.
    #
    # @param response_code [String] the Spreedly transaction token
    # @return [ActiveMerchant::Billing::Response]
    def show(response_code)
      client.show(response_code)
    end

    # Complete a transaction that came back +pending+ (e.g. after a 3DS2
    # challenge). Transaction-scoped, so it is independent of the orchestration
    # mode.
    #
    # @param response_code [String] the Spreedly transaction token
    # @param options [Hash] completion context (e.g. :browser_info)
    # @return [ActiveMerchant::Billing::Response]
    def complete(response_code, options = {})
      client.complete(response_code, options)
    end

    # Reverse a transaction before Solidus knows whether it has settled.
    #
    # If the transaction can still be voided we void it; otherwise we issue a
    # credit (refund).
    #
    # @param response_code [String] the Spreedly transaction token
    # @return [ActiveMerchant::Billing::Response]
    def cancel(response_code)
      transaction = show(response_code)

      if voidable?(transaction)
        void_response = void(response_code)
        return void_response if void_response.success?
      end

      credit(nil, nil, response_code, {})
    end

    # Used by +Spree::Payment#cancel!+ (Solidus >= 2.4).
    #
    # Returns the void response when the transaction can still be voided,
    # otherwise +false+ so that Solidus falls back to creating a refund.
    #
    # @param payment [Spree::Payment] the payment to void
    # @return [ActiveMerchant::Billing::Response, false]
    def try_void(payment)
      transaction = show(payment.response_code)
      return false unless voidable?(transaction)

      void_response = void(payment.response_code, payment.source, {originator: payment})
      void_response.success? ? void_response : false
    end

    # Payment profiles are supported: the Spreedly payment method token stored
    # on the source can be reused. This also fixes the +void+/+credit+ argument
    # arity Solidus uses (source is passed through).
    def payment_profiles_supported?
      true
    end

    # Called by +Spree::Payment+ (via +create_payment_profile+) on save when
    # payment profiles are supported.
    #
    # Spreedly payment method tokens are captured and retained client-side
    # (Spreedly Express / iFrame), so there is nothing to create server-side by
    # default. Overridable for stores that want to retain on demand.
    #
    # @param _payment [Spree::Payment]
    # @return [void]
    def create_profile(_payment)
      nil
    end

    # Overridable routing hook for :gateway mode.
    #
    # Returns the Spreedly gateway token to charge for a given payment. Defaults
    # to the single configured token; override to implement canary rollouts or
    # multi-gateway routing.
    #
    # @param _source [SolidusSpreedly::Source]
    # @param _gateway_options [Hash]
    # @return [String]
    def gateway_token_for(_source, _gateway_options)
      preferred_gateway_token
    end

    # Overridable routing hook for :workflow mode.
    #
    # Returns the Spreedly Composer workflow key for a given payment. Defaults
    # to the configured +workflow_key+ preference; override to select workflows
    # dynamically (e.g. from order context or routing transaction_metadata).
    #
    # @param _source [SolidusSpreedly::Source]
    # @param _gateway_options [Hash]
    # @return [String, nil]
    def workflow_key_for(_source, _gateway_options)
      preferred_workflow_key
    end

    # Overridable hook for transaction metadata sent to Spreedly.
    #
    # Transaction Metadata is available to Composer workflow rules for routing decisions.
    # Defaults to the +:transaction_metadata+ entry in +gateway_options+; override to derive
    # values from the source, order, or payment context.
    #
    # @param _source [SolidusSpreedly::Source]
    # @param gateway_options [Hash]
    # @return [Hash]
    def transaction_metadata_for(_source, gateway_options)
      gateway_options[:transaction_metadata] || {}
    end

    # Overridable hook: whether a successful purchase/authorize should also
    # retain (vault) the card for reuse.
    #
    # Precedence:
    #   1. explicit per-call gateway_options[:store] (true/false) wins
    #   2. else the :retain_on_success preference
    #   3. else false
    #
    # @param _source [SolidusSpreedly::Source]
    # @param gateway_options [Hash]
    # @return [Boolean]
    def retain_on_success_for(_source, gateway_options)
      gateway_options = gateway_options.to_h
      return !!gateway_options[:store] if gateway_options.key?(:store)

      preferred_retain_on_success
    end

    # Overridable hook: whether purchase/authorize should attempt a network
    # token (Advanced Vault). Spreedly falls back to PAN when NT cannot be used.
    #
    # Precedence:
    #   1. explicit per-call gateway_options[:attempt_network_token] wins
    #   2. else the :attempt_network_token preference
    #   3. else false
    #
    # @param _source [SolidusSpreedly::Source]
    # @param gateway_options [Hash]
    # @return [Boolean]
    def attempt_network_token_for(_source, gateway_options)
      gateway_options = gateway_options.to_h
      return !!gateway_options[:attempt_network_token] if gateway_options.key?(:attempt_network_token)

      preferred_attempt_network_token
    end

    # Overridable hook: whether to request network-token provisioning while
    # retaining (create/retain, or purchase/authorize with retain_on_success).
    #
    # Precedence:
    #   1. explicit per-call gateway_options[:provision_network_token] wins
    #   2. else the :provision_network_token preference
    #   3. else false
    #
    # @param _source [SolidusSpreedly::Source]
    # @param gateway_options [Hash]
    # @return [Boolean]
    def provision_network_token_for(_source, gateway_options)
      gateway_options = gateway_options.to_h
      return !!gateway_options[:provision_network_token] if gateway_options.key?(:provision_network_token)

      preferred_provision_network_token
    end

    protected

    # Solidus calls +gateway+/+gateway_class+ through its default delegation,
    # but we override the gateway interface directly, so the AM-style gateway
    # class is intentionally not used.
    def gateway_class
      SolidusSpreedly::Client
    end

    private

    def client_options
      {
        login: preferred_environment_key,
        password: preferred_access_secret,
        gateway_token: preferred_gateway_token,
        workflow_key: preferred_workflow_key,
        orchestration_mode: orchestration_mode,
        test: test_mode?
      }.compact
    end

    def payment_method_token_for(source)
      source.respond_to?(:payment_method_token) ? source.payment_method_token : source
    end

    # Build orchestration-specific routing options for purchase/authorize.
    #
    # In +:gateway+ mode returns +:gateway_token+ from {#gateway_token_for}. In
    # +:workflow+ mode returns +:workflow_key+ from {#workflow_key_for}.
    #
    # @param source [SolidusSpreedly::Source]
    # @param gateway_options [Hash]
    # @return [Hash] routing keys to merge into {#transaction_options}
    def routing_options(source, gateway_options)
      if orchestration_mode == :workflow
        {workflow_key: workflow_key_for(source, gateway_options)}.compact
      else
        {gateway_token: gateway_token_for(source, gateway_options)}
      end
    end

    # Build the per-call options for purchase/authorize.
    #
    # Merges common Solidus gateway options with {#routing_options} and optional
    # 3DS2 / transaction_metadata / network-tokenization fields. Supported
    # +gateway_options+ keys:
    #
    #   * +:currency+ - ISO currency code
    #   * +:order_id+ - merchant order reference
    #   * +:ip+ - buyer IP address
    #   * +:email+ - buyer email
    #   * +:browser_info+ - 3DS2 browser fingerprint hash
    #   * +:transaction_metadata+ - transaction metadata hash for Spreedly Workflow
    #     rules (also available via the overridable {#transaction_metadata_for} hook)
    #   * +:store+ - per-call override for {#retain_on_success_for}
    #   * +:attempt_network_token+ - per-call override for {#attempt_network_token_for}
    #   * +:provision_network_token+ - per-call override for {#provision_network_token_for}
    #
    # @param source [SolidusSpreedly::Source]
    # @param gateway_options [Hash]
    # @return [Hash]
    def transaction_options(source, gateway_options)
      options = {
        orchestration_mode: orchestration_mode,
        currency: gateway_options[:currency],
        order_id: gateway_options[:order_id],
        ip: gateway_options[:ip],
        email: gateway_options[:email]
      }.merge(routing_options(source, gateway_options))

      options[:sca_provider_key] = preferred_sca_provider_key if preferred_sca_provider_key.present?
      options[:browser_info] = gateway_options[:browser_info] if gateway_options[:browser_info]

      transaction_metadata = transaction_metadata_for(source, gateway_options)
      options[:transaction_metadata] = transaction_metadata if transaction_metadata.present?

      options[:store] = true if retain_on_success_for(source, gateway_options)
      options[:attempt_network_token] = true if attempt_network_token_for(source, gateway_options)
      options[:provision_network_token] = true if provision_network_token_for(source, gateway_options)

      options.compact
    end

    def currency_options(gateway_options)
      {currency: gateway_options[:currency]}.compact
    end

    def test_mode?
      preferred_test_mode.nil? || preferred_test_mode
    end

    # Whether the given Spreedly transaction (as returned by #show) can still be
    # reversed with a void rather than a credit. Overridable.
    def voidable?(response)
      transaction = transaction_params(response)
      return false if transaction.blank?
      return false unless transaction["succeeded"]

      transaction_type = transaction["transaction_type"].to_s.downcase
      REVERSAL_TRANSACTION_TYPES.exclude?(transaction_type)
    end

    def transaction_params(response)
      return {} unless response.respond_to?(:params) && response.params.is_a?(Hash)

      response.params["transaction"] || response.params
    end
  end
end
