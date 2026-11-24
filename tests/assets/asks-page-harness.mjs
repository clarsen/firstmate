// Render a built captain-asks ledger page's shipped inline script under a
// minimal DOM shim, optionally drive its row decisions, and print what the
// page actually produced, so the ledger table and its Accept/Rework capture
// are asserted through the real page rather than by reading its source.
//
// Usage: node asks-page-harness.mjs <built-page.html> [actions-json]
// actions-json is a list of {key, choose: "accept"|"rework", note?, cancel?};
// each opens the decision strip of the row with that question key, types the note, and sends it (or
// cancels instead when `cancel` is true).
// Prints one JSON document:
//   { count, captain, empty,
//     rows: [{ key, cells: {<column label>: text}, tones: {<column label>: tone},
//              details: [{text, clipped}], actions: [label],
//              panelOpen, noteLabel, send, error }],
//     queued: [{ prompt, tag, text, question, data }] }
// `tones` carries a status cell's emphasis ("attn", "ok", or ""). A detail is
// `clipped` when the page turned it into an expand control because it did not
// fit; the shim reports a detail longer than 60 characters as not fitting.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");
const actions = JSON.parse(process.argv[3] || "[]");

class Node {
  constructor(tag) {
    this.localName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this.dataset = {};
    this.listeners = {};
    this._text = "";
    this.hidden = false;
    this.parentNode = null;
    this.value = "";
    this.title = "";
    this.clientWidth = 60;
  }
  get textContent() {
    return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  get scrollWidth() { return this.attributes["aria-expanded"] === "true" ? 0 : this.textContent.length; }
  get lastChild() { return this.children[this.children.length - 1]; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  append(...nodes) { nodes.forEach((n) => this.appendChild(n)); }
  replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
  replaceWith(n) {
    const siblings = this.parentNode.children;
    siblings[siblings.indexOf(this)] = n;
    n.parentNode = this.parentNode;
  }
  insertAdjacentHTML() {}
  setAttribute(k, v) { this.attributes[k] = String(v); }
  getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  fire(type, event = {}) {
    (this.listeners[type] || []).forEach((fn) => fn({ preventDefault() {}, ...event }));
  }
  focus() {}
  hasClass(name) { return this.className.split(/\s+/).includes(name); }
  querySelectorAll(sel) {
    const out = [];
    const walk = (n) => n.children.forEach((c) => { if (c.hasClass(sel.slice(1))) out.push(c); walk(c); });
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="decision-page-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("decision-page-data", dataNode);

const queued = [];
globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for, each under its own parent so
  // the page can replace it.
  getElementById: (id) => {
    if (!byId.has(id)) byId.set(id, new Node("div").appendChild(new Node("div")));
    return byId.get(id);
  },
};
globalThis.window = {
  addEventListener() {},
  lavish: {
    queuePrompt: (prompt, opts) => queued.push({
      prompt, tag: opts.tag, text: opts.text,
      question: opts.element.getAttribute("data-lavish-question"), data: opts.data,
    }),
  },
};

for (const m of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) {
  new Function(m[1])();
}

const body = byId.get("rows") || new Node("tbody");
const asks = () => body.children.filter((n) => n.hasClass("ask"));
const formOf = (tr) => body.children[body.children.indexOf(tr) + 1].children[0].children[0];
const cellOf = (tr, label) => tr.children.find((c) => c.dataset.label === label);

for (const action of actions) {
  const tr = asks().find((row) => formOf(row).getAttribute("data-lavish-question") === action.key);
  const form = formOf(tr);
  cellOf(tr, "Decide").children.find((b) => b.title.toLowerCase() === action.choose).fire("click");
  form.children.find((c) => c.localName === "input").value = action.note || "";
  if (action.cancel) form.children.find((c) => c.hasClass("cancel")).fire("click");
  else form.fire("submit");
}

const rows = asks().map((tr) => {
  const form = formOf(tr);
  const cells = {};
  const tones = {};
  for (const td of tr.children) {
    const mark = td.children.find((c) => c.hasClass("st"));
    cells[td.dataset.label] = td.dataset.label === "Ask"
      ? td.children.find((c) => c.hasClass("ask-title")).textContent
      : td.textContent;
    if (mark) tones[td.dataset.label] = mark.hasClass("attn") ? "attn" : mark.hasClass("ok") ? "ok" : "";
  }
  const decide = cellOf(tr, "Decide");
  return {
    key: form.getAttribute("data-lavish-question"),
    cells,
    tones,
    details: cellOf(tr, "Ask").children.filter((c) => c.hasClass("detail"))
      .map((c) => ({ text: c.textContent, clipped: c.localName === "button" })),
    actions: decide.children.filter((c) => c.hasClass("act")).map((b) => b.getAttribute("aria-label")),
    panelOpen: !form.parentNode.parentNode.hidden,
    noteLabel: form.children.find((c) => c.localName === "label").textContent,
    send: form.children.find((c) => c.hasClass("send")).textContent,
    error: form.children.find((c) => c.hasClass("error")).textContent,
  };
});

const ledger = byId.get("ledger");
const shown = ledger ? ledger.parentNode.children[0] : null;
process.stdout.write(JSON.stringify({
  count: byId.get("count")?.textContent ?? "",
  captain: byId.get("captain")?.textContent ?? "",
  empty: shown && shown !== ledger ? shown.textContent : "",
  rows,
  queued,
}) + "\n");
