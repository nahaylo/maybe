import { Controller } from "@hotwired/stimulus";

// Makes a parent checkbox act as a toggle for its whole group.
//
// The parent stays a checkbox of its own rather than becoming a heading,
// because it is a real value in its own right -- a parent category can be
// assigned to a transaction directly -- so ticking it means "the parent and
// everything under it".
//
// Deliberately one-way: unticking a single child leaves the parent alone, since
// the parent's own value is still a valid part of the selection.
export default class extends Controller {
  static targets = ["parent", "child"];

  toggleAll() {
    this.childTargets.forEach((child) => {
      child.checked = this.parentTarget.checked;
    });
  }
}
