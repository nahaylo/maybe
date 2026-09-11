import { Controller } from "@hotwired/stimulus";

// Basic functionality to filter a list based on a provided text attribute.
export default class extends Controller {
  static targets = ["input", "list", "emptyMessage"];

  connect() {
    this.inputTarget.focus();
  }

  filter() {
    const filterValue = this.inputTarget.value.toLowerCase();
    const items = this.listTarget.querySelectorAll(".filterable-item");
    let noMatchFound = true;

    if (this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.add("hidden");
    }

    items.forEach((item) => {
      const text = item.getAttribute("data-filter-name").toLowerCase();
      const shouldDisplay = text.includes(filterValue);
      item.style.display = shouldDisplay ? "" : "none";

      if (shouldDisplay) {
        noMatchFound = false;
      }
    });

    if (noMatchFound && this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.remove("hidden");
    }

    this.hideEmptyGroups();
  }

  // A grouped list (categories under their parent) would otherwise leave the
  // group container behind as an empty box once all of its items are filtered
  // out. No-op for flat lists, which have no groups.
  hideEmptyGroups() {
    this.listTarget.querySelectorAll("[data-filter-group]").forEach((group) => {
      const hasVisibleItem = Array.from(
        group.querySelectorAll(".filterable-item"),
      ).some((item) => item.style.display !== "none");

      group.style.display = hasVisibleItem ? "" : "none";
    });
  }
}
