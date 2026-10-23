import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Connects to data-controller="portfolio-treemap"
//
// Draws the family's holdings as a treemap: a block per group, a tile per
// holding sized by value and coloured by return. Clicking a tile opens the
// holding drawer, the same one the Holdings tab opens.
export default class extends Controller {
  static values = { tree: Object };

  // Clamped so one outlier does not wash every other tile out to grey.
  #limit = 30;
  #groupHeader = 22;

  connect() {
    this.#draw();
    this.resizeObserver = new ResizeObserver(() => this.#redraw());
    this.resizeObserver.observe(this.element);
  }

  disconnect() {
    this.resizeObserver?.disconnect();
    this.#teardown();
  }

  #redraw() {
    this.#teardown();
    this.#draw();
  }

  #teardown() {
    d3.select(this.element).selectAll("*").remove();
  }

  #color = d3
    .scaleLinear()
    .domain([-this.#limit, 0, this.#limit])
    .range(["#c2413b", "#6b7280", "#2f9e5a"])
    .interpolate(d3.interpolateRgb)
    .clamp(true);

  #fill(percent) {
    return percent === null || percent === undefined ? "#6b7280" : this.#color(percent);
  }

  #draw() {
    const width = this.element.clientWidth;
    const height = this.element.clientHeight;
    if (width === 0 || height === 0) return;

    const root = d3
      .hierarchy(this.treeValue)
      .sum((d) => d.value || 0)
      .sort((a, b) => b.value - a.value);

    d3
      .treemap()
      .size([width, height])
      .paddingOuter(2)
      .paddingTop((node) => (node.depth === 1 ? this.#groupHeader : 2))
      .paddingInner(2)
      .round(true)(root);

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("class", "block font-sans");

    // Group blocks and their headers.
    const groups = svg
      .selectAll("g.group")
      .data(root.children || [])
      .join("g")
      .attr("class", "group");

    // The container behind the SVG supplies the group background, so both
    // themes come from the design system rather than a colour set here.
    groups
      .append("text")
      .attr("x", (d) => d.x0 + 6)
      .attr("y", (d) => d.y0 + 15)
      .attr("fill", "currentColor")
      .attr("class", "text-secondary")
      .attr("font-size", 12)
      .attr("font-weight", 500)
      .text((d) => this.#fit(`${d.data.name} · ${d.data.value_label}`, d.x1 - d.x0 - 16, 7));

    // Holding tiles.
    const tiles = svg
      .selectAll("g.tile")
      .data(root.leaves())
      .join("g")
      .attr("class", "tile cursor-pointer")
      .attr("transform", (d) => `translate(${d.x0},${d.y0})`)
      .on("click", (_event, d) => {
        if (d.data.url) Turbo.visit(d.data.url, { frame: "drawer" });
      });

    tiles
      .append("rect")
      .attr("width", (d) => Math.max(0, d.x1 - d.x0))
      .attr("height", (d) => Math.max(0, d.y1 - d.y0))
      .attr("rx", 3)
      .attr("fill", (d) => this.#fill(d.data.percent))
      .on("mouseenter", function () { d3.select(this).attr("opacity", 0.85); })
      .on("mouseleave", function () { d3.select(this).attr("opacity", 1); });

    tiles.append("title").text((d) => this.#tooltip(d.data));

    tiles.each((d, i, nodes) => this.#label(d3.select(nodes[i]), d));
  }

  // Ticker and return, scaled to the tile; dropped when the tile is too small
  // to read. The tooltip still carries everything.
  #label(tile, d) {
    const w = d.x1 - d.x0;
    const h = d.y1 - d.y0;
    if (w < 34 || h < 20) return;

    const size = Math.max(10, Math.min(28, Math.sqrt(w * h) / 6));
    const percent = d.data.percent;
    const showPercent = h > size * 2.2 && percent !== null && percent !== undefined;
    const block = showPercent ? size * 1.9 : size;
    const top = (h - block) / 2 + size * 0.85;

    tile
      .append("text")
      .attr("x", w / 2)
      .attr("y", top)
      .attr("text-anchor", "middle")
      .attr("fill", "#fff")
      .attr("font-size", size)
      .attr("font-weight", 600)
      .attr("pointer-events", "none")
      .text(this.#fit(d.data.ticker, w - 6, size * 0.62));

    if (showPercent) {
      tile
        .append("text")
        .attr("x", w / 2)
        .attr("y", top + size * 0.95)
        .attr("text-anchor", "middle")
        .attr("fill", "#fff")
        .attr("fill-opacity", 0.9)
        .attr("font-size", size * 0.62)
        .attr("pointer-events", "none")
        .text(`${percent > 0 ? "+" : ""}${percent.toFixed(1)}%`);
    }
  }

  #tooltip(data) {
    const lines = [`${data.ticker} · ${data.name}`, `Value ${data.value_label}${data.native_label ? ` (${data.native_label})` : ""}`];
    if (data.gain_label) lines.push(`Unrealised ${data.gain_label}${data.percent !== null ? ` (${data.percent > 0 ? "+" : ""}${data.percent.toFixed(1)}%)` : ""}`);
    lines.push(`${data.weight}% of portfolio`);
    return lines.join("\n");
  }

  // Shortens a label to what fits, assuming an average glyph width.
  #fit(text, width, glyph) {
    const max = Math.floor(width / glyph);
    if (max <= 0) return "";
    return text.length <= max ? text : `${text.slice(0, Math.max(1, max - 1))}…`;
  }
}
