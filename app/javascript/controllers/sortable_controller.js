import { Controller } from "@hotwired/stimulus";

// Drag-to-reorder for a list of records, built on native HTML5 drag events so
// no third-party sortable library is needed.
//
// Rows carry draggable="true" from the server. Flipping it on during mousedown
// instead is unreliable in Chrome and Safari, which decide draggability before
// the handler runs -- so rows are always draggable and a drag that did not start
// on a handle is cancelled in dragstart. That also stops the browser from
// natively dragging the links inside a row.
//
// Dragging is confined to the list the row started in: on this page lists are
// account groups, and an account cannot change group by being dragged.
//
//   <div data-controller="sortable" data-sortable-url-value="/accounts/reorder">
//     <div data-sortable-target="list">
//       <div data-sortable-target="item" data-sortable-id="123" draggable="true">
//         <span data-action="mousedown->sortable#grabHandle
//                            touchstart->sortable#grabHandle">handle</span>
//       </div>
//     </div>
//   </div>
export default class extends Controller {
  static targets = ["list", "item"];
  static values = {
    url: String,
    paramName: { type: String, default: "account_ids" },
  };

  connect() {
    this.dragging = null;
    this.grabbed = false;

    this.onPointerDown = this.releaseHandle.bind(this);
    this.onDragStart = this.handleDragStart.bind(this);
    this.onDragOver = this.handleDragOver.bind(this);
    this.onDragEnd = this.handleDragEnd.bind(this);

    // Capture phase so this runs before the handle's own action.
    this.element.addEventListener("mousedown", this.onPointerDown, true);
    this.element.addEventListener("touchstart", this.onPointerDown, true);
    this.element.addEventListener("dragstart", this.onDragStart);
    this.element.addEventListener("dragover", this.onDragOver);
    this.element.addEventListener("dragend", this.onDragEnd);
  }

  disconnect() {
    this.element.removeEventListener("mousedown", this.onPointerDown, true);
    this.element.removeEventListener("touchstart", this.onPointerDown, true);
    this.element.removeEventListener("dragstart", this.onDragStart);
    this.element.removeEventListener("dragover", this.onDragOver);
    this.element.removeEventListener("dragend", this.onDragEnd);
  }

  // Any pointer press clears the flag; the handle's own action re-arms it.
  releaseHandle() {
    this.grabbed = false;
  }

  grabHandle() {
    this.grabbed = true;
  }

  handleDragStart(event) {
    const item = event.target.closest('[data-sortable-target="item"]');

    // Not a handle drag -- cancel it so links and text do not drag either.
    if (!item || !this.grabbed) {
      event.preventDefault();
      return;
    }

    this.dragging = item;
    this.originalOrder = this.#currentIds();
    item.classList.add("opacity-50");

    // setData is required for Firefox to emit drag events at all.
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", item.dataset.sortableId ?? "");
  }

  handleDragOver(event) {
    if (!this.dragging) return;

    // Without preventDefault the pointer shows "no drop" for the whole drag.
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";

    const over = event.target.closest('[data-sortable-target="item"]');
    if (!over || over === this.dragging) return;

    // Confine the drag to the list it started in.
    const list = this.dragging.closest('[data-sortable-target="list"]');
    if (over.closest('[data-sortable-target="list"]') !== list) return;

    const box = over.getBoundingClientRect();
    const insertAfter = event.clientY > box.top + box.height / 2;
    over.parentNode.insertBefore(
      this.dragging,
      insertAfter ? over.nextSibling : over,
    );
  }

  handleDragEnd() {
    this.grabbed = false;
    if (!this.dragging) return;

    this.dragging.classList.remove("opacity-50");
    this.dragging = null;

    const ids = this.#currentIds();
    if (ids.join() !== this.originalOrder.join()) this.#persist(ids);
  }

  #currentIds() {
    return this.itemTargets.map((item) => item.dataset.sortableId);
  }

  #persist(ids) {
    const body = new URLSearchParams();
    ids.forEach((id) => body.append(`${this.paramNameValue}[]`, id));

    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('[name="csrf-token"]').content,
        Accept: "application/json",
      },
      body: body.toString(),
    });
  }
}
