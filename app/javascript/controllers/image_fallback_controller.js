import { Controller } from "@hotwired/stimulus";

// Swaps a remote image for its inline fallback when the image fails to load.
//
// The logo hosts are public, undocumented endpoints (Synth's disappeared),
// so every remote logo must have something behind it. Both elements are in
// the markup from the start; this only flips which one is visible.
//
// Connects to data-controller="image-fallback"
export default class extends Controller {
  static targets = ["image", "fallback"];

  connect() {
    // A cached 404 fails before Stimulus attaches, so the error event is
    // already gone; a complete image with no pixels is the same failure.
    const image = this.imageTarget;
    if (image.complete && image.naturalWidth === 0) {
      this.fallback();
    }
  }

  fallback() {
    this.imageTarget.classList.add("hidden");
    // `hidden` and `flex` both set display, so swap rather than stack them.
    this.fallbackTarget.classList.remove("hidden");
    this.fallbackTarget.classList.add("flex");
  }
}
