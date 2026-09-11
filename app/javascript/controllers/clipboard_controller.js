import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["source", "iconDefault", "iconSuccess"];

  async copy(event) {
    event.preventDefault();

    const text = this.sourceTarget?.textContent?.trim();
    if (!text) return;

    try {
      // navigator.clipboard exists only in a secure context. A self-hosted
      // instance reached over plain http on anything but localhost is not one,
      // so reading .writeText there throws before any promise is created.
      if (window.isSecureContext && navigator.clipboard) {
        await navigator.clipboard.writeText(text);
      } else {
        this.#copyViaSelection(text);
      }

      this.showSuccess();
    } catch (error) {
      console.error("Failed to copy text: ", error);
    }
  }

  showSuccess() {
    // The icons are optional: some callers render a plain button.
    if (!this.hasIconDefaultTarget || !this.hasIconSuccessTarget) return;

    this.iconDefaultTarget.classList.add("hidden");
    this.iconSuccessTarget.classList.remove("hidden");
    setTimeout(() => {
      this.iconDefaultTarget.classList.remove("hidden");
      this.iconSuccessTarget.classList.add("hidden");
    }, 3000);
  }

  // execCommand is deprecated but is the only copy path available outside a
  // secure context, which is the common case for self-hosted deployments.
  #copyViaSelection(text) {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.top = "-9999px";

    // Must live inside the open dialog. A modal <dialog> makes the rest of the
    // document inert, so a textarea appended to document.body cannot hold a
    // selection -- execCommand then copies nothing and still reports success.
    const host = this.element.closest("dialog") ?? document.body;
    host.appendChild(area);

    area.select();
    area.setSelectionRange(0, text.length);

    try {
      if (!document.execCommand("copy")) throw new Error("execCommand returned false");
    } finally {
      area.remove();
    }
  }
}
