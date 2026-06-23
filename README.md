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
