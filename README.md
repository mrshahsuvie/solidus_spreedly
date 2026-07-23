# Solidus Spreedly

A Solidus extension that integrates [Spreedly](https://www.spreedly.com/) as a
synchronous, transaction-token payment gateway. It talks to a small, explicit
slice of the Spreedly Core API (JSON, HTTP Basic auth) and supports:

- **Two orchestration modes** — `:gateway` (route through a specific Spreedly
  gateway) and `:workflow` (route through a Spreedly Composer workflow).
- The full Solidus payment lifecycle — `purchase`, `authorize`, `capture`,
  `void`, `credit` (refund), plus transaction `show`.
- **3DS2 / SCA** via a `pending` → `complete` completion path.
- **Reusable, vaulted sources** scoped per user (Spreedly has no server-side
  customer object).

## Installation

This gem is published from a Git source. Add it to your Gemfile:

```ruby
gem 'solidus_spreedly', github: 'suvie-eng/solidus_spreedly'
```

Bundle your dependencies and run the installation generator:

```shell
bundle install
bin/rails generate solidus_spreedly:install
```

The generator:

- copies a configuration initializer (`config/initializers/solidus_spreedly.rb`),
- installs the migration that creates `solidus_spreedly_sources`,
- copies an **example** Spreedly Express checkout integration into `app/` so you
  can adapt it to your storefront (pass `--frontend=none` to skip it),
- registers the JS/CSS in classic (`solidus_frontend`) asset manifests when they
  exist.

```shell
# skip the example storefront assets (e.g. for a headless/Starter Frontend store)
bin/rails generate solidus_spreedly:install --frontend=none

# run migrations without the interactive prompt
bin/rails generate solidus_spreedly:install --auto-run-migrations
```

## Configuration

Once the gem is installed, its engine registers `SolidusSpreedly::Gateway` as an
available payment method type (no manual wiring needed) and permits the Spreedly
source attributes the storefront submits.

### Create the payment method

A payment method can take its preferences either **from a static source in code**
(recommended) or **directly entered in the admin** (stored in the database). The
available preferences are:

| Preference | Required | Description |
|---|---|---|
| `environment_key` | yes | Spreedly environment key (HTTP Basic auth login) |
| `access_secret` | yes | Spreedly access secret (HTTP Basic auth password) |
| `orchestration_mode` | yes | `"gateway"` (default) or `"workflow"` |
| `gateway_token` | `:gateway` mode | Token of the gateway configured in Spreedly |
| `workflow_key` | `:workflow` mode | Composer workflow key |
| `sca_provider_key` | optional | Enables the 3DS2 / SCA flow on purchase/authorize |
| `retain_on_success` | optional | When `true`, a successful purchase/authorize also retains (vaults) the card for reuse. Defaults to `false`. |
| `attempt_network_token` | optional | When `true`, purchase/authorize prefer a Spreedly network token (Advanced Vault). Spreedly falls back to PAN when NT is unusable. Defaults to `false`. |
| `provision_network_token` | optional | When `true`, request network-token provisioning while retaining (create/retain, or charge with `retain_on_success`). Defaults to `false`. |
| `test_mode` | optional | Defaults to `true`; set `false` in production |

#### Option A — static preferences (recommended)

As with `solidus_stripe` / `solidus_braintree`, you can declare a named set of
preferences sourced from the environment, so **sensitive credentials are not
stored in the database**. Register it in an initializer:

```ruby
# config/initializers/spree.rb
Rails.application.config.to_prepare do
  Spree::Config.static_model_preferences.add(
    SolidusSpreedly::Gateway,
    'spreedly_credentials',
    {
      environment_key: ENV.fetch('SPREEDLY_ENVIRONMENT_KEY', ''),
      access_secret: ENV.fetch('SPREEDLY_ACCESS_SECRET', ''),
      orchestration_mode: 'gateway',
      gateway_token: ENV.fetch('SPREEDLY_GATEWAY_TOKEN', ''),
      workflow_key: ENV.fetch('SPREEDLY_WORKFLOW_KEY', ''),
      sca_provider_key: ENV.fetch('SPREEDLY_SCA_PROVIDER_KEY', ''),
      retain_on_success: false,
      attempt_network_token: ENV.fetch('SPREEDLY_ATTEMPT_NETWORK_TOKEN', 'false') == 'true',
      provision_network_token: ENV.fetch('SPREEDLY_PROVISION_NETWORK_TOKEN', 'false') == 'true',
      test_mode: !Rails.env.production?
    }
  )
end
```

Then attach it to a payment method:

1. Visit `/admin/payment_methods/new`.
2. Set *Type* to `SolidusSpreedly::Gateway` and click **Save**.
3. Choose `spreedly_credentials` from the **Preference Source** select.
4. Click **Update** to save.

Or from the Rails console:

```ruby
SolidusSpreedly::Gateway.new(
  name: 'Spreedly',
  preference_source: 'spreedly_credentials'
).save!
```

#### Option B — preferences entered directly

Pick **Spreedly** from the *Type* dropdown at `/admin/payment_methods/new`, save,
then fill in the preferences above. The equivalent console/seed form:

```ruby
SolidusSpreedly::Gateway.create!(
  name: 'Spreedly',
  preferred_environment_key: ENV['SPREEDLY_ENVIRONMENT_KEY'],
  preferred_access_secret: ENV['SPREEDLY_ACCESS_SECRET'],
  preferred_orchestration_mode: 'gateway',
  preferred_gateway_token: ENV['SPREEDLY_GATEWAY_TOKEN'],
  # preferred_workflow_key: ENV['SPREEDLY_WORKFLOW_KEY'], # for :workflow mode
  # preferred_sca_provider_key: ENV['SPREEDLY_SCA_PROVIDER_KEY'], # for 3DS2
  available_to_admin: true,
  available_to_users: true
)
```

### Orchestration modes

- **`:gateway`** — money-moving calls hit
  `/gateways/{gateway_token}/{purchase,authorize}.json`. Use this to keep the
  routing decision inside Solidus (good for canary rollouts — see
  `gateway_token_for` below).
- **`:workflow`** — money-moving calls hit `/transactions/{purchase,authorize}.json`
  with the `workflow_key` in the body, delegating routing to a Spreedly Composer
  workflow managed in `app.spreedly.com`.

Follow-up calls (`capture`, `void`, `credit`, `complete`, `show`) are
transaction-token scoped and therefore identical in both modes.

### Store-wide overrides

The initializer is only for store-wide overrides. The most common one is
pointing the extension at your own gateway subclass:

```ruby
# config/initializers/solidus_spreedly.rb
SolidusSpreedly.configure do |config|
  config.default_gateway_class = 'MyStore::SpreedlyGateway'
end
```

### Canary / multi-gateway routing

In `:gateway` mode the gateway token is resolved through an overridable hook, so
you can route a percentage of traffic to a new gateway without touching the rest
of the flow:

```ruby
module MyStore
  class SpreedlyGateway < SolidusSpreedly::Gateway
    def gateway_token_for(source, gateway_options)
      rand < 0.1 ? 'canary-gateway-token' : super
    end
  end
end
```

### Retain on successful charge

By default, purchase/authorize calls do **not** retain the card.

Precedence:

1. explicit per-call `gateway_options[:store]` (`true`/`false`) wins
2. else the `:retain_on_success` payment-method preference
3. else off

When enabled, the adapter sends `store: true` to the client, which maps to
Spreedly's `retain_on_success` field on the transaction body.

Enable store-wide via the preference:

```ruby
SolidusSpreedly::Gateway.create!(
  name: 'Spreedly',
  preferred_retain_on_success: true,
  # ...
)
```

Or override the hook in a gateway subclass (for example, to retain every charge
while still honoring an explicit per-call opt-out):

```ruby
module MyStore
  class SpreedlyGateway < SolidusSpreedly::Gateway
    def retain_on_success_for(_source, gateway_options)
      return super if gateway_options.to_h.key?(:store)

      true
    end
  end
end
```

Per-call override from application code:

```ruby
payment_method.purchase(amount_cents, source, store: false)
```

### Network tokenization

[Network tokenization](https://developer.spreedly.com/docs/network-tokenization)
is part of Spreedly Advanced Vault. Before enabling it in Solidus:

1. Advanced Vault must be enabled on your Spreedly account, with TRIDs for the
   card networks you use (Visa / Mastercard).
2. For gateways that require it (e.g. Stripe Payment Intents, Braintree), enable
   network tokens on the merchant account and set
   `enabled_network_tokens: true` on the Spreedly gateway.
3. Prefer NT on charges with `attempt_network_token`, and provision tokens while
   retaining with `provision_network_token`.

Both flags are **opt-in** (`false` by default). When `attempt_network_token` is
true, Spreedly prefers a network token and falls back to the PAN when NT cannot
be used. Payment success is independent of NT provision/attempt errors; the
full Spreedly response (including `transaction.network_tokenization`) is kept
in ActiveMerchant `params`.

Precedence for each flag mirrors `retain_on_success`:

1. explicit per-call `gateway_options[:attempt_network_token]` /
   `[:provision_network_token]` wins
2. else the matching payment-method preference
3. else off

Enable via preferences:

```ruby
SolidusSpreedly::Gateway.create!(
  name: 'Spreedly',
  preferred_attempt_network_token: true,
  preferred_provision_network_token: true,
  preferred_retain_on_success: true, # often used with provisioning on charge
  # ...
)
```

Or override the hooks (for example, only attempt NT for recurring sources):

```ruby
module MyStore
  class SpreedlyGateway < SolidusSpreedly::Gateway
    def attempt_network_token_for(source, gateway_options)
      return super if gateway_options.to_h.key?(:attempt_network_token)

      source.respond_to?(:reusable?) && source.reusable?
    end
  end
end
```

Per-call override:

```ruby
payment_method.purchase(amount_cents, source, attempt_network_token: false)
```

`create_payment_method` / `store` on the client also accept
`provision_network_token: true` when vaulting outside the payment flow.

### Vault helpers

To flip Spreedly Advanced Vault's `managed` flag on a payment method without a
paid update, call `update_gratis` on the gateway client:

```ruby
response = payment_method.client.update_gratis(payment_method_token, managed: false)

response.success?              # => true when managed matches the request and there are no errors
response.payment_method_token  # => Spreedly payment method token
response.error_code            # => e.g. "errors.not_found"
```

This hits `PUT /v1/payment_methods/{token}/update_gratis.json` and returns a
`SolidusSpreedly::PaymentMethodResponse` (not an ActiveMerchant transaction
response). The same response type is reused for any Spreedly endpoint that
returns a `payment_method` payload; pass `expect:` when success depends on
specific attributes matching the request.

To permanently wipe a vaulted payment method (Spreedly Redact Payment Method):

```ruby
response = payment_method.client.redact(payment_method_token, remove_personal_data: true)

response.success?    # => ActiveMerchant::Billing::Response
response.error_code  # => e.g. "errors.not_found"
```

This hits `PUT /v1/payment_methods/{token}/redact.json`. Optional
`remove_from_gateway:` removes the card from a third-party gateway vault as
well. Empty options send an empty body (Spreedly accepts that).

## 3DS2 / pending completion

When a `sca_provider_key` is configured and the issuer requires a challenge, a
`purchase`/`authorize` comes back in the Spreedly `pending` state (which the
extension does **not** treat as success). After the shopper completes the
browser challenge, the storefront posts to the completion endpoint:

```
(GET|POST) /solidus_spreedly/payments/:payment_id/complete
```

This is handled by `SolidusSpreedly::CompletionsController`, which calls
`SolidusSpreedly::PaymentCompletion` to run `client.complete(token)` and
transition the Solidus payment to `completed` (or `failed`). The example
Spreedly Express assets show the client-side half of this flow.

## Usage in tests

When testing your application's integration with this extension you may use its
factories. Load Solidus core factories along with this extension's factories
with:

```ruby
SolidusDevSupport::TestingSupport::Factories.load_for(SolidusSpreedly::Engine)
```

Available factories: `:solidus_spreedly_payment_method` and
`:solidus_spreedly_source`.

## Development

### Testing the extension

First bundle your dependencies, then run `bin/rake`. `bin/rake` will default to
building the dummy app if it does not exist, then it will run specs. The dummy
app can be regenerated by using `bin/rake extension:test_app`.

```shell
bin/rake
```

To run [RuboCop](https://github.com/rubocop/rubocop) static code analysis:

```shell
bundle exec rubocop
```

### Releasing new versions

Please refer to the [dedicated page](https://github.com/solidusio/solidus/wiki/How-to-release-extensions) in the Solidus wiki.

## License

Copyright (c) 2026 Suvie, released under the New BSD License.
