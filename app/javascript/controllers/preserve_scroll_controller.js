import { Controller } from "@hotwired/stimulus";

/*
  https://dev.to/konnorrogers/maintain-scroll-position-in-turbo-without-data-turbo-permanent-2b1i
  modified to add support for horizontal scrolling

  only requirement is that the element has an id

  Positions are keyed by element id and held in a class-level store, so they
  survive the element being replaced by a Turbo Drive visit but reset on a hard
  reload.
 */
export default class extends Controller {
  static scrollPositions = {};

  connect() {
    this.preserveScrollBound = this.preserveScroll.bind(this);
    this.restoreScrollBound = this.restoreScroll.bind(this);

    // Recording on scroll rather than only on turbo:before-cache means the
    // position is known even when the page is never cached (a visit to a
    // `data-turbo-cache="false"` page, say).
    this.element.addEventListener("scroll", this.preserveScrollBound, {
      passive: true,
    });
    window.addEventListener("turbo:before-cache", this.preserveScrollBound);
    window.addEventListener("turbo:render", this.restoreScrollBound);

    // A Turbo Drive visit replaces this element, so the fresh instance connects
    // after turbo:render has already fired and would otherwise never restore.
    // This is what actually keeps a long sidebar where the user left it.
    this.restoreScroll();
  }

  disconnect() {
    this.element.removeEventListener("scroll", this.preserveScrollBound);
    window.removeEventListener("turbo:before-cache", this.preserveScrollBound);
    window.removeEventListener("turbo:render", this.restoreScrollBound);
  }

  preserveScroll() {
    if (!this.element.id) return;

    this.constructor.scrollPositions[this.element.id] = {
      top: this.element.scrollTop,
      left: this.element.scrollLeft,
    };
  }

  restoreScroll() {
    if (!this.element.id) return;

    const position = this.constructor.scrollPositions[this.element.id];
    if (!position) return;

    this.element.scrollTop = position.top;
    this.element.scrollLeft = position.left;
  }
}
