// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges,detail}],
//     charted:[{title,sub,badges,pickable,pick,rank,detail}], empty, more,
//     projects:{shown, cards:[{name,open,badges,groups:[{label,rows}],more}],
//               quiet, sub, empty}, dispatch:[{id,hidden,count}], error }
// `detail` is null for a row with no expandable panel, or
// {body, links:[{label,url}]} for a row that carries one. `pick` is the row's
// dispatch id when it carries a picker, and `rank` its rank label when shown.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
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
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener() {}
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.window = {};
globalThis.TextEncoder = TextEncoder;

// The built page now carries two bare <script> blocks in order: the shared
// decision-card builder (.agents/skills/bearings/assets/decision-card.js)
// injected first, then the board's own rendering script, which depends on
// window.FMDecisionCard existing already. Run every bare script block in
// document order so both execute against the same window stub.
for (const m of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) {
  new Function(m[1])();
}

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

// A Charted Next row with a detail panel is followed in the container by a
// sibling `.bb-detail` element (see board-template.html); anything else
// means the row carries no detail and renders exactly as it did before that
// feature existed.
const detailOf = (panel) => {
  if (!panel) return null;
  const body = panel.children.find((c) => c.className.includes("bb-detail__body"));
  const linkWrap = panel.children.find((c) => c.className.includes("bb-detail__links"));
  const links = linkWrap
    ? linkWrap.children.map((a) => ({ label: a.textContent, url: a.href || "" }))
    : [];
  return { body: body ? body.textContent : null, links };
};

const rowsOf = (container) => {
  const kids = container.children;
  const out = [];
  for (let i = 0; i < kids.length; i++) {
    const row = kids[i];
    if (!row.className.split(/\s+/).includes("bb-row")) continue;
    const main = row.children.find((c) => c.className.includes("bb-row__main"));
    const next = kids[i + 1];
    const hasDetailPanel = !!next && next.className.split(/\s+/).includes("bb-detail");
    const pick = row.children.find((c) => c.className.split(/\s+/).includes("bb-pick"));
    out.push({
      title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
      sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
      badges: badgesOf(row),
      pickable: !!pick,
      pick: pick ? pick.value : null,
      rank: row.children.find((c) => c.className.includes("bb-row__rank"))?.textContent ?? null,
      detail: hasDetailPanel ? detailOf(next) : null,
    });
  }
  return out;
};

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

// The Projects drilldown: one card per project with charted work, each holding
// labelled groups of rows, plus the one-line list of projects with nothing charted.
const projSection = byId.get("bb-projects-section");
const pw = byId.get("bb-projects") || new Node("div");
const has = (n, c) => n.className.split(/\s+/).includes(c);
const cards = pw.children.filter((c) => has(c, "bb-proj")).map((card) => {
  const head = card.children.find((c) => has(c, "bb-proj__head"));
  const body = card.children.find((c) => has(c, "bb-proj__body"));
  const groups = [];
  let moreChip = null;
  if (body) {
    for (let i = 0; i < body.children.length; i++) {
      const c = body.children[i];
      if (!has(c, "bb-proj__label")) continue;
      const rows = body.children[i + 1];
      groups.push({ label: c.textContent, rows: rows ? rowsOf(rows) : [] });
      const chip = rows?.children.find((r) => has(r, "bb-morechip"));
      if (chip) moreChip = chip.textContent;
    }
  }
  return {
    name: head?.children.find((c) => has(c, "bb-proj__name"))?.textContent ?? "",
    open: !!card.open,
    badges: head ? badgesOf(head) : [],
    groups,
    more: moreChip,
  };
});
const projects = {
  shown: projSection ? !projSection.hidden : false,
  cards,
  quiet: pw.children.filter((c) => has(c, "bb-proj-quiet")).map((c) => c.textContent),
  empty: pw.children.filter((c) => has(c, "bb-empty")).map((c) => c.textContent),
  sub: byId.get("bb-projects-sub")?.textContent ?? "",
};
const dispatch = ["bb-dispatch", "bb-proj-dispatch"].map((id) => ({
  id,
  hidden: byId.has(id) ? byId.get(id).hidden : true,
  count: byId.get(id + "-count")?.textContent ?? "",
}));

process.stdout.write(
  JSON.stringify({ stats, underway, charted, empty, more, projects, dispatch, error: errorText }) + "\n");
