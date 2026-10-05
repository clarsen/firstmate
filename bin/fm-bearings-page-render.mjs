// Execute a built captain-question page's shipped inline scripts under a
// minimal DOM shim and report what the renderer actually produced, so
// bin/fm-bearings-board.sh's `page` command can PROVE every question
// rendered its answer controls before arming or printing a link, rather than
// assuming a page that built without error also drew controls. The same
// pattern - a built page's real <script> blocks run under a tiny DOM shim,
// asserting on render output rather than on the template's source text - is
// tests/assets/board-render-harness.mjs's for the /bearings board.
//
// Usage: node fm-bearings-page-render.mjs <built-page.html>
// Prints one JSON document on success:
//   { title, questions: [{ key, optionCount, radioName, hasNote,
//     questionImage, optionImageCount }], error }
// A question is counted only when its form renders exactly one radio-button
// group (every radio shares one name) with at least one option; `error` is
// set whenever the page's own fail-closed renderer fired instead.
// questionImage is true when the card carries a question-level image
// (class bb-decision__img); optionImageCount counts rendered per-option
// images (class bb-opt__img) inside the form. Both are presentational
// render-proof signals only - neither changes a question's key or its
// radio-group/note assertions above.
import { readFileSync } from "node:fs";

const path = process.argv[2];
if (!path) {
  process.stderr.write("usage: fm-bearings-page-render.mjs <built-page.html>\n");
  process.exit(2);
}
const html = readFileSync(path, "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.name = "";
    this.value = "";
    this.checked = false;
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) {
    this.attributes[k] = v;
    if (k === "name") this.name = v;
    if (k === "type") this.type = v;
  }
  addEventListener() {}
}

// Only ids the served markup actually carries resolve to an element; every
// other id resolves to null, exactly like a real DOM. This is what makes the
// harness catch a stray edit that deletes an id="..." target: the renderer
// dereferences the resulting null and throws, same as it would in a browser,
// instead of the shim silently minting a substitute element that was never
// really there.
const realIds = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));

const byId = new Map();
const dataNode = new Node("script");
const marker = '<script id="decision-page-data" type="application/json">';
if (!html.includes(marker)) {
  process.stderr.write("the page does not carry a decision-page-data script block\n");
  process.exit(1);
}
dataNode.textContent = html.split(marker)[1].split("</script>")[0];
byId.set("decision-page-data", dataNode);

globalThis.document = {
  title: "",
  createElement: (tag) => new Node(tag),
  getElementById: (id) => {
    if (byId.has(id)) return byId.get(id);
    if (!realIds.has(id)) return null;
    const n = new Node("div");
    byId.set(id, n);
    return n;
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.window = {};
globalThis.TextEncoder = TextEncoder;
globalThis.FormData = class {
  constructor() { this._entries = []; }
  get() { return null; }
};

// The built page carries two bare <script> blocks in order: the shared
// decision-card builder (.agents/skills/bearings/assets/decision-card.js)
// injected first, then the page's own rendering script, which depends on
// window.FMDecisionCard existing already. Run every bare script block in
// document order so both execute against the same window stub.
try {
  for (const m of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) {
    new Function(m[1])();
  }
} catch (e) {
  process.stdout.write(JSON.stringify({ title: "", questions: [], error: String(e) }) + "\n");
  process.exit(0);
}

// Walk a subtree collecting every element whose type === "radio", grouped by
// the <form> ancestor that carries data-lavish-question.
function findForms(root) {
  const forms = [];
  const walk = (n) => {
    if (n.tagName === "form" && n.attributes["data-lavish-question"]) forms.push(n);
    for (const c of n.children) walk(c);
  };
  walk(root);
  return forms;
}
function radiosIn(form) {
  const out = [];
  const walk = (n) => {
    if (n.tagName === "input" && n.type === "radio") out.push(n);
    for (const c of n.children) walk(c);
  };
  walk(form);
  return out;
}
function hasNoteField(form) {
  const out = [];
  const walk = (n) => {
    if (n.tagName === "input" && n.name === "note") out.push(n);
    for (const c of n.children) walk(c);
  };
  walk(form);
  return out.length > 0;
}
function optionImageCount(form) {
  const out = [];
  const walk = (n) => {
    if (n.tagName === "img" && n.className === "bb-opt__img") out.push(n);
    for (const c of n.children) walk(c);
  };
  walk(form);
  return out.length;
}
function hasQuestionImage(form) {
  const pad = form.parentNode;
  if (!pad) return false;
  return pad.children.some((c) => c.tagName === "img" && c.className === "bb-decision__img");
}

const container = byId.get("dp-questions") || new Node("div");
const forms = findForms(container);
const questions = forms.map((form) => {
  const radios = radiosIn(form);
  const names = new Set(radios.map((r) => r.name));
  return {
    key: form.attributes["data-lavish-question"],
    optionCount: radios.length,
    radioName: names.size === 1 ? [...names][0] : names.size === 0 ? null : "(mixed)",
    hasNote: hasNoteField(form),
    questionImage: hasQuestionImage(form),
    optionImageCount: optionImageCount(form),
  };
});

const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");

process.stdout.write(
  JSON.stringify({ title: document.title, questions, error: errorText }) + "\n");
