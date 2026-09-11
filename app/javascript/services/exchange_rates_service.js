export class ExchangeRatesService {
  get({ from, to, date, amount }) {
    return fetch(
      `/exchange_rate.json?${this.#params({ from, to, date, amount })}`,
    ).then((response) => response.json());
  }

  // Imports the pair on demand when no rate is stored yet.
  fetchRemotely({ from, to, date, amount }) {
    return fetch(
      `/exchange_rate.json?${this.#params({ from, to, date, amount })}`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('[name="csrf-token"]').content,
        },
      },
    ).then((response) => response.json());
  }

  #params({ from, to, date, amount }) {
    return new URLSearchParams({
      from,
      to,
      date: date || "",
      amount: amount || "",
    });
  }
}
