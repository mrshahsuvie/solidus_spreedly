//
// Spreedly Express source-capture for Solidus checkout.
//
// This is a reference integration: it loads the Spreedly Express drop-in,
// lets the buyer enter their card in Spreedly's hosted modal (so card data
// never touches your server), and writes the resulting payment method token
// into the Solidus checkout form before submitting.
//
// It is intentionally framework-agnostic (vanilla JS, no jQuery). Adapt the
// selectors/markup to match your storefront. See the example partial copied by
// `bin/rails g solidus_spreedly:install` at
// app/views/spree/checkout/payment/_spreedly.html.erb.
//
(function () {
  "use strict";

  var EXPRESS_SCRIPT_URL = "https://core.spreedly.com/iframe/express/v1/spreedly-express.min.js";

  function loadExpress(callback) {
    if (window.SpreedlyExpress) {
      callback();
      return;
    }

    var script = document.createElement("script");
    script.src = EXPRESS_SCRIPT_URL;
    script.async = true;
    script.onload = callback;
    document.head.appendChild(script);
  }

  function setupContainer(container) {
    if (container.dataset.spreedlyInitialized === "true") {
      return;
    }
    container.dataset.spreedlyInitialized = "true";

    var environmentKey = container.dataset.spreedlyEnvironmentKey;
    var tokenField = container.querySelector("[data-spreedly-token-field]");
    var trigger = container.querySelector("[data-spreedly-trigger]");
    var form = container.closest("form");

    if (!environmentKey || !tokenField || !trigger) {
      return;
    }

    trigger.addEventListener("click", function (event) {
      event.preventDefault();

      SpreedlyExpress.init(environmentKey, {
        amount: container.dataset.spreedlyAmount || "",
        company_name: container.dataset.spreedlyCompanyName || ""
      });

      SpreedlyExpress.onPaymentMethod(function (token, paymentMethod) {
        tokenField.value = token;

        var summary = container.querySelector("[data-spreedly-summary]");
        if (summary && paymentMethod) {
          summary.textContent =
            (paymentMethod.card_type || "Card") +
            " ending in " +
            (paymentMethod.last_four_digits || "????");
        }

        if (form) {
          form.submit();
        }
      });

      SpreedlyExpress.openHandler();
    });
  }

  function init() {
    var containers = document.querySelectorAll("[data-spreedly-express]");
    Array.prototype.forEach.call(containers, function (container) {
      loadExpress(function () {
        setupContainer(container);
      });
    });
  }

  document.addEventListener("DOMContentLoaded", init);
})();
