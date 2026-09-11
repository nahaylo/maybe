import { Controller } from "@hotwired/stimulus";
import { ExchangeRatesService } from "services/exchange_rates_service";

// Connects to data-controller="transfer-form"
//
// Shows the converted destination amount when the two accounts use different
// currencies, and lets the user override it. The conversion itself is done
// server-side; this controller never multiplies or rounds.
export default class extends Controller {
  static targets = [
    "fromAccount",
    "toAccount",
    "amount",
    "date",
    "destinationSection",
    "destinationAmount",
    "rateNote",
    "fetchButton",
  ];

  connect() {
    // Also runs after a server-side validation failure re-renders the form.
    this.refresh();
  }

  disconnect() {
    clearTimeout(this.debounceTimer);
  }

  // Any change to the source amount, the accounts or the date invalidates a
  // previous manual override -- a stale-but-plausible number is the exact
  // failure mode this feature exists to remove.
  refresh() {
    const from = this.#currencyOf(this.fromAccountTarget);
    const to = this.#currencyOf(this.toAccountTarget);

    if (!from || !to || from === to) {
      this.#hideDestination();
      return;
    }

    this.#showDestination();

    clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => this.#requestRate(from, to), 250);
  }

  #requestRate(from, to) {
    // Ignore a slow earlier response that resolves after a newer request.
    const requestId = (this.requestId || 0) + 1;
    this.requestId = requestId;

    new ExchangeRatesService()
      .get({
        from,
        to,
        date: this.dateTarget.value,
        amount: this.amountTarget.value,
      })
      .then(
        ({
          rate,
          converted_amount: convertedAmount,
          rate_date: rateDate,
          stale,
        }) => {
          if (requestId !== this.requestId) return;

          this.#render({ from, to, rate, convertedAmount, rateDate, stale });
        },
      );
  }

  // Imports the pair on demand, for when nothing is stored for these currencies.
  fetchRate() {
    const from = this.#currencyOf(this.fromAccountTarget);
    const to = this.#currencyOf(this.toAccountTarget);
    if (!from || !to) return;

    this.fetchButtonTarget.disabled = true;
    this.fetchButtonTarget.textContent = "Fetching…";

    new ExchangeRatesService()
      .fetchRemotely({
        from,
        to,
        date: this.dateTarget.value,
        amount: this.amountTarget.value,
      })
      .then(
        ({
          rate,
          converted_amount: convertedAmount,
          rate_date: rateDate,
          stale,
        }) => {
          this.fetchButtonTarget.disabled = false;
          this.fetchButtonTarget.textContent = "Fetch rate";

          if (rate == null) {
            this.rateNoteTarget.textContent = `No provider could supply ${from} → ${to} for this date. Enter the amount you actually received.`;
            return;
          }

          this.#render({ from, to, rate, convertedAmount, rateDate, stale });
        },
      )
      .catch(() => {
        this.fetchButtonTarget.disabled = false;
        this.fetchButtonTarget.textContent = "Fetch rate";
        this.rateNoteTarget.textContent =
          "Could not reach the rate provider. Enter the amount manually.";
      });
  }

  #render({ from, to, rate, convertedAmount, rateDate, stale }) {
    if (rate == null) {
      // Never prefill with the source amount -- that is the 1:1 bug in client form.
      this.destinationAmountTarget.value = "";
      this.rateNoteTarget.textContent = `No exchange rate found for ${from} → ${to}.`;
      this.rateNoteTarget.classList.add("text-destructive");
      this.fetchButtonTarget.classList.remove("hidden");
      return;
    }

    this.destinationAmountTarget.value = convertedAmount ?? "";
    this.rateNoteTarget.textContent = stale
      ? `1 ${from} = ${rate} ${to} (last available rate, from ${rateDate})`
      : `1 ${from} = ${rate} ${to}`;
    this.rateNoteTarget.classList.remove("text-destructive");
    this.fetchButtonTarget.classList.add("hidden");
  }

  #currencyOf(select) {
    return select.selectedOptions[0]?.dataset.currency;
  }

  #showDestination() {
    this.destinationSectionTarget.classList.remove("hidden");
    this.destinationAmountTarget.disabled = false;
  }

  #hideDestination() {
    this.destinationSectionTarget.classList.add("hidden");
    // Disabling matters: a hidden but enabled input is still submitted.
    this.destinationAmountTarget.disabled = true;
    this.destinationAmountTarget.value = "";
    this.rateNoteTarget.textContent = "";
    this.fetchButtonTarget.classList.add("hidden");
  }
}
