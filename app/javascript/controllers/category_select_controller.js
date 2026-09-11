import { Controller } from "@hotwired/stimulus";

// Two dependent selects in place of one long list of every category: pick a
// category, then narrow it to one of its subcategories.
//
// The subcategory select is the field that gets submitted. Its "None" option
// carries the parent category's own id, so leaving the subcategory alone submits
// the category itself -- a parent is assignable in its own right. Nothing here
// has to reconcile two values.
export default class extends Controller {
  static targets = ["parent", "child", "childWrapper"];
  static values = { subcategories: Object };

  parentChanged() {
    const parentId = this.parentTarget.value;
    const subcategories = this.subcategoriesValue[parentId] || [];

    this.childTarget.replaceChildren(
      this.#option("None", parentId),
      ...subcategories.map(([name, id]) => this.#option(name, id)),
    );

    this.childWrapperTarget.classList.toggle("hidden", subcategories.length === 0);

    // Auto-submitting forms listen on the field itself, which has not been
    // touched by the user here.
    this.childTarget.dispatchEvent(new Event("change", { bubbles: true }));
  }

  #option(text, value) {
    const option = document.createElement("option");
    option.textContent = text;
    option.value = value;
    return option;
  }
}
