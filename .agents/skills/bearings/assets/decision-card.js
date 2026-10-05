// Shared decision-card builder: the exact card markup, options/freeform
// rendering, and answer-queuing submit handler used by both the /bearings
// fleet board (.agents/skills/bearings/assets/board-template.html) and
// one-off captain question pages (.agents/skills/bearings/assets/
// page-template.html), so this exists in exactly one place rather than two
// hand-maintained copies. Each caller supplies what genuinely differs: its
// own top badges, optional context rows, an optional link, the button
// color, the queued-answer schema and prompt label, and (via opts.validate)
// any answer validation beyond the shared non-empty/512-byte checks - the
// board passes none, so its original "silently do nothing on an empty
// answer" behavior is unchanged.
window.FMDecisionCard = (function () {
  "use strict";

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function badge(tone, text) { return el("span", "fm-badge fm-badge--" + tone, text); }
  function ctxRow(k, v, rec) {
    var row = el("div", "bb-ctx__row" + (rec ? " bb-ctx__row--rec" : ""));
    row.appendChild(el("span", "bb-ctx__k", k));
    row.appendChild(el("span", "bb-ctx__v", v));
    return row;
  }
  function utf8ByteLength(text) { return new TextEncoder().encode(text).length; }
  var CHECK_SVG = '<svg class="fm-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';

  // A `video` src is a page-relative path (never a data: URI - see
  // bin/fm-bearings-board.sh's resolve_page_media), so its extension is the
  // only type signal the browser needs for the <source type> hint.
  function videoMimeForSrc(src) {
    var ext = (src.split(".").pop() || "").toLowerCase();
    if (ext === "mp4") return "video/mp4";
    if (ext === "webm") return "video/webm";
    if (ext === "mov") return "video/quicktime";
    return "";
  }
  // Plays inline without the viewer clicking through a silent poster: muted
  // (required for autoplay in every major browser), looped, with controls
  // so the viewer can pause/seek, and playsinline so mobile Safari does not
  // force fullscreen. `posterSrc` (the item's/option's own `image`, when
  // given) is shown before the first frame decodes.
  function buildVideo(cls, src, posterSrc, alt) {
    var v = document.createElement("video");
    v.className = cls;
    v.muted = true; v.setAttribute("muted", "");
    v.loop = true; v.setAttribute("loop", "");
    v.autoplay = true; v.setAttribute("autoplay", "");
    v.controls = true; v.setAttribute("controls", "");
    v.playsInline = true; v.setAttribute("playsinline", "");
    if (posterSrc) v.poster = posterSrc;
    v.setAttribute("aria-label", alt || "");
    var source = document.createElement("source");
    source.setAttribute("src", src);
    var mime = videoMimeForSrc(src);
    if (mime) source.setAttribute("type", mime);
    v.appendChild(source);
    return v;
  }

  // item: { key, title, detail, image, video,
  //         options:[{value,label,hint,recommended,image,video}],
  //         allowFreeform, freeformHint, close }
  // `image`/`video`, on the item or on any option, are caller-supplied media
  // references (an `image` is typically a data: URI, a `video` a
  // page-relative path) and are purely presentational: neither reaches
  // window.lavish.queuePrompt or changes an answer's value. When both are
  // given, `image` is the video's poster frame rather than a separate
  // static image.
  // opts: { schema, promptLabel, buttonClass, top:[Node...], context:[Node...],
  //         alwaysShowContext, link:{text,url},
  //         validate:function(value,note) -> message string | falsy,
  //         onQueued:function(card) }
  function build(item, opts) {
    opts = opts || {};
    var card = el("div", "fm-card fm-card--poster bb-decision");
    var pad = el("div", "bb-decision__pad");

    if (opts.top && opts.top.length) {
      var top = el("div", "bb-decision__top");
      opts.top.forEach(function (n) { top.appendChild(n); });
      pad.appendChild(top);
    }

    pad.appendChild(el("h3", "bb-decision__title", item.title));
    if (item.detail) pad.appendChild(el("p", "bb-decision__detail", item.detail));
    if (item.video) {
      pad.appendChild(buildVideo("bb-decision__video", item.video, item.image, item.title));
    } else if (item.image) {
      var itemImg = document.createElement("img");
      itemImg.className = "bb-decision__img";
      itemImg.src = item.image;
      itemImg.alt = item.title;
      pad.appendChild(itemImg);
    }
    if ((opts.context && opts.context.length) || opts.alwaysShowContext) {
      var ctx = el("div", "bb-ctx");
      (opts.context || []).forEach(function (n) { ctx.appendChild(n); });
      pad.appendChild(ctx);
    }
    if (opts.link) {
      var a = el("a", "bb-decision__link", opts.link.text);
      a.href = opts.link.url; a.target = "_blank"; a.rel = "noopener";
      pad.appendChild(a);
    }

    var form = document.createElement("form");
    form.setAttribute("data-lavish-question", item.key);
    var optsList = el("div", "bb-opts");
    item.options.forEach(function (o) {
      var lab = el("label", "bb-opt" + ((o.image || o.video) ? " bb-opt--img" : ""));
      var input = document.createElement("input");
      input.type = "radio"; input.name = "answer"; input.value = o.value;
      lab.appendChild(input);
      if (o.video) {
        lab.appendChild(buildVideo("bb-opt__video", o.video, o.image, o.label));
      } else if (o.image) {
        var optImg = document.createElement("img");
        optImg.className = "bb-opt__img";
        optImg.src = o.image;
        optImg.alt = o.label;
        lab.appendChild(optImg);
      }
      var body = el("span", "bb-opt__body");
      body.appendChild(el("span", "bb-opt__label", o.label));
      if (o.hint) body.appendChild(el("span", "bb-opt__hint", o.hint));
      lab.appendChild(body);
      if (o.recommended) lab.appendChild(el("span", "bb-opt__rec", "rec"));
      optsList.appendChild(lab);
    });
    form.appendChild(optsList);

    if (item.allowFreeform) {
      var ff = document.createElement("input");
      ff.type = "text"; ff.name = "note"; ff.className = "bb-freeform";
      ff.placeholder = item.freeformHint || "or answer in your own words…";
      form.appendChild(ff);
    }

    var foot = el("div", "bb-decision__foot");
    var btn = el("button", "fm-btn fm-btn--sm " + (opts.buttonClass || "fm-btn--primary"), "Queue answer");
    btn.type = "submit";
    foot.appendChild(btn);
    var q = el("span", "bb-queued");
    q.innerHTML = CHECK_SVG + " queued";
    foot.appendChild(q);
    var limit = el("span", "bb-limit");
    limit.setAttribute("role", "alert");
    foot.appendChild(limit);
    form.appendChild(foot);

    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      limit.classList.remove("is-visible");
      var fd = new FormData(form);
      var value = fd.get("answer");
      var note = (fd.get("note") || "").trim();
      if (opts.validate) {
        var msg = opts.validate(value, note);
        if (msg) {
          limit.textContent = msg;
          limit.classList.add("is-visible");
          return;
        }
      }
      var displayAnswer = value ? (note ? value + " - " + note : value) : note;
      if (!displayAnswer) return;
      if (utf8ByteLength(displayAnswer) > 512) {
        limit.textContent = "Answer is too long to queue (512 bytes maximum).";
        limit.classList.add("is-visible");
        return;
      }
      if (window.lavish && window.lavish.queuePrompt) {
        var ctxData = {
          schema: opts.schema,
          question: item.key,
          selection: value || "",
          note: note
        };
        if (item.close) ctxData.close = item.close;
        window.lavish.queuePrompt(
          (opts.promptLabel || "Answer") + " - " + item.title + ": " + displayAnswer,
          { tag: "choice", text: item.title + " -> " + displayAnswer, element: form,
            data: ctxData }
        );
      }
      card.classList.add("is-queued");
      if (opts.onQueued) opts.onQueued(card);
    });

    pad.appendChild(form);
    card.appendChild(pad);
    return card;
  }

  return { el: el, badge: badge, ctxRow: ctxRow, utf8ByteLength: utf8ByteLength, CHECK_SVG: CHECK_SVG, build: build };
})();
