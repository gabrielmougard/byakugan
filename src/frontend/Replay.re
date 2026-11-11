/* The page itself, as archived (GET /replay: the WARC record, scripts off),
   with what the cascade and the matcher made of it drawn on top: each
   block's score for a label or for Sensitive Topics, the slots and their P,
   and for the selected slot its context boundary (the decay kernel above
   and below, the co-visible window). The layout measured in the frame goes
   back to /api/placement, so slots are scored on the real geometry.

     GET /replay?url=...  ─▶  iframe, sandboxed, at the device width
       │ onLoad, and again 1.5 s later: late images move the layout
       ▼
     measure: each extracted segment ─▶ its rendered element
              (same tag and squashed text, in document order)
       │ boxes: segment i, top, height, left, width, in CSS px
       ▼
     POST /api/placement, when there is a creative prompt and a box:
       │ geometry (i, top / vh, height / vh) in viewports, format, level, avoid
       ▼ slots (after, p, blocked, flagged) and the format geometry
     overlays on the frame:
       ov-seg      one per box, shaded by the lens (label, Sensitive Topics,
                   main vs boilerplate, stories)
       ov-slot     under the block each slot follows, with its P or blocked
       ov-kernel   selected slot: exp(-|d| / reach) gradients, 3 reaches each way
       ov-window   selected slot: the co-visible window, co_visible viewports
                   each side */

open Api;
open Ui;

type box = {
  i: int,
  top: float,
  height: float,
  left: float,
  width: float,
};

type geometry = {
  page_weight: float,
  reach_above: float,
  reach_below: float,
  co_visible: float,
};

type measuredPlacement = {
  measured: bool,
  geometry,
  slots: array(slot),
};

type frame = Dom.element;

/* Align the extracted segments to the frame's elements (same tag, same
   text, in document order) and measure them. Text is compared as the
   extractor squashes it: ASCII whitespace only, no-break spaces kept. A
   block with nested blocks (a menu item and its submenu) is a prefix of the
   element's text. A media segment without text takes the next element of
   its tag. Elements not rendered (hidden menus, zero size) are left out. */
let measure: (Js.Nullable.t(frame), array(segment)) => array(box) = [%mel.raw
  {|
  function (frame, segs) {
    var doc = frame && frame.contentDocument;
    if (!doc || !doc.body || doc.contentType !== "text/html") return [];
    var norm = function (s) { return (s || "").replace(/[ \t\n\r\f]+/g, " ").trim(); };
    var els = Array.prototype.slice.call(
      doc.querySelectorAll("h1,h2,h3,p,li,blockquote,figcaption,img,iframe,video"));
    var texts = els.map(function (e) {
      return e.tagName === "IMG" ? norm((e.getAttribute("alt") || "") + " " + (e.getAttribute("title") || ""))
                                 : norm(e.textContent);
    });
    var scroll = doc.documentElement.scrollTop || 0, out = [], j = 0;
    segs.forEach(function (g) {
      var want = norm(g.text), tag = g.tag.toUpperCase(), key = want.slice(0, 80), found = -1;
      for (var k = j; k < Math.min(els.length, j + 400); k++) {
        if (els[k].tagName !== tag) continue;
        var t = texts[k];
        if (t === want || (want.length >= 8 && t.slice(0, want.length) === want)
            || (key.length >= 12 && t.slice(0, 80) === key)
            || (want === "" && (tag === "IMG" || tag === "IFRAME" || tag === "VIDEO"))) { found = k; break; }
      }
      if (found < 0) return;
      j = found + 1;
      var r = els[found].getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return;
      out.push({ i: g.i, top: r.top + scroll, height: r.height, left: r.left, width: r.width });
    });
    return out;
  }
|}
];

let docHeight: Js.Nullable.t(frame) => float = [%mel.raw
  {|
  function (frame) {
    var doc = frame && frame.contentDocument;
    return doc && doc.documentElement ? Math.max(doc.documentElement.scrollHeight, doc.body ? doc.body.scrollHeight : 0) : 0;
  }
|}
];

let isArchive: Js.Nullable.t(frame) => bool = [%mel.raw
  {| function (frame) { var d = frame && frame.contentDocument; return !!d && d.contentType === "text/html"; } |}
];

let containerWidth: Js.Nullable.t(Dom.element) => float = [%mel.raw
  {| function (el) { return el ? el.clientWidth : 0; } |}
];

/* Width of the frame and height of one viewport, CSS pixels. */
let devices = [|("phone", 390., 844.), ("desktop", 1280., 900.)|];

let score = (labels: array(label), id) =>
  switch (find((l: label) => l.id == id, labels)) {
  | Some(l) => l.score
  | None => 0.
  };

let worst = (labels: array(label)) =>
  Array.fold_left((m, l: label) => l.sensitive ? Float.max(m, l.score) : m, 0., labels);

/* exp(-|d| / reach) as a CSS gradient from the slot (strong) outwards. */
let kernel = (~toward, reach) =>
  Printf.sprintf(
    "linear-gradient(to %s, %s)",
    toward,
    String.concat(
      ", ",
      List.map(
        d => Printf.sprintf("rgba(91, 108, 255, %.3f) %.0f%%", 0.42 *. exp(-. d /. reach), 100. *. d /. (3. *. reach)),
        [0., 0.25, 0.5, 1., 1.5, 2., 3.] |> List.map(x => x *. reach),
      ),
    ),
  );

[@react.component]
let make = (~page: page, ~prompt, ~level, ~format, ~avoid, ~onSimulate) => {
  let frame = React.useRef(Js.Nullable.null);
  let stage = React.useRef(Js.Nullable.null);
  let (device, setDevice) = React.useState(() => "phone");
  let (boxes, setBoxes) = React.useState(() => [||]);
  let (height, setHeight) = React.useState(() => 0.);
  let (archived, setArchived) = React.useState(() => None);
  let (lens, setLens) = React.useState(() => "topic");
  let current = find((l: Api.level) => l.preset == level, page.levels);
  let topLabels =
    switch (current) {
    | Some(l) => take(12, l.labels |> filter((x: label) => !x.sensitive))
    | None => [||]
    };
  let (labelId, setLabelId) = React.useState(() => Array.length(topLabels) > 0 ? topLabels[0].id : "");
  let (active, setActive) = React.useState(() => None);
  let (placement, setPlacement) = React.useState(() => None);
  let (scale, setScale) = React.useState(() => 1.);
  let (_, deviceWidth, viewport) =
    switch (find(((d, _, _)) => d == device, devices)) {
    | Some(d) => d
    | None => devices[0]
    };
  let remeasure = () => {
    let f = frame.current;
    let ok = isArchive(f);
    setArchived(_ => Some(ok));
    if (ok) {
      setHeight(_ => docHeight(f));
      setBoxes(_ => measure(f, page.segments));
    };
    let w = containerWidth(stage.current);
    setScale(_ => w > 0. ? Float.min(1., w /. deviceWidth) : 1.);
  };
  /* Images arrive after load and move the layout: measure once more. */
  let onLoad = _ => {
    remeasure();
    Js.Global.setTimeout(~f=remeasure, 1500) |> ignore;
  };
  React.useEffect1(
    () => {
      setBoxes(_ => [||]);
      setActive(_ => None);
      None;
    },
    [|device|],
  );
  /* Slots scored on the measured layout: (segment, top, height) in viewports. */
  React.useEffect6(
    () => {
      let live = ref(true);
      if (prompt != "" && Array.length(boxes) > 0) {
        let geometry = boxes |> Array.map(b => (b.i, b.top /. viewport, b.height /. viewport));
        load(
          ~what="Placement",
          post(
            "/api/placement",
            {
              "prompt": prompt,
              "format": format,
              "level": level,
              "avoid_sensitive": avoid,
              "url": page.url,
              "geometry": geometry,
            },
          ),
          (p: measuredPlacement) => if (live^) {setPlacement(_ => Some(p))},
        );
      };
      Some(() => live := false);
    },
    (boxes, prompt, level, format, avoid, viewport),
  );
  let segmentOf = i => find((g: segment) => g.i == i, page.segments);
  let boxOf = i => find(b => b.i == i, Array.to_list(boxes) |> Array.of_list);
  let slots =
    switch (placement) {
    | Some(p) => p.slots
    | None => [||]
    };
  /* A slot sits under the block it follows; page-level slots at the top. */
  let slotY = (sl: slot) =>
    sl.after < 0
      ? Some(0.)
      : Option.map(b => b.top +. b.height, boxOf(sl.after));
  let activeSlot = Option.bind(active, a => find((sl: slot) => sl.after == a, slots));
  let flagged = i =>
    switch (activeSlot) {
    | Some(sl) => Array.mem(i, sl.flagged)
    | None => false
    };
  let shade = (g: segment) =>
    switch (lens) {
    | "sensitive" =>
      let w = worst(g.labels);
      w > 0.05 ? Some(Printf.sprintf("rgba(214, 48, 49, %.2f)", 0.12 +. 0.5 *. w)) : None;
    | "structure" => Some(g.main ? "rgba(91, 108, 255, 0.10)" : "rgba(120, 120, 120, 0.28)")
    | "stories" =>
      Array.exists((a: story) => a.article == g.article, page.articles)
        ? Some(Printf.sprintf("hsla(%d, 70%%, 55%%, 0.22)", g.article * 67 mod 360)) : None
    | _ =>
      let x = score(g.labels, labelId);
      x > 0.05 ? Some(Printf.sprintf("rgba(22, 163, 74, %.2f)", 0.08 +. 0.5 *. x)) : None;
    };
  let tip = (g: segment) =>
    Printf.sprintf(
      "%s%s: %s",
      g.tag,
      g.main ? "" : " (boilerplate)",
      g.labels
      |> take(4)
      |> Array.map((l: label) => Printf.sprintf("%s %s", short(l.path), pct(l.score)))
      |> Array.to_list
      |> String.concat(", "),
    );
  let src = "/replay?url=" ++ encode(page.url);
  <div className="replay">
    <div className="toolbar">
      <Tabs tabs=[|("phone", "Phone 390 px"), ("desktop", "Desktop 1280 px")|] current=device onChange={d => setDevice(_ => d)} />
      <Tabs
        tabs=[|
          ("topic", "Label"),
          ("sensitive", "Sensitive Topics"),
          ("structure", "Main vs boilerplate"),
          ("stories", "Stories"),
        |]
        current=lens
        onChange={l => setLens(_ => l)}
      />
      {lens == "topic"
         ? <select value=labelId onChange={e => setLabelId(value(e))}>
             {topLabels
              |> Array.map((l: label) =>
                   <option key={l.id} value={l.id}> {s(short(l.path) ++ " " ++ pct(l.score))} </option>
                 )
              |> React.array}
           </select>
         : React.null}
      <Help tip=Glossary.replay />
      <span className="spacer" />
      {switch (placement) {
       | Some(p) =>
         <span className="row">
           <Badge text={p.measured ? "measured layout" : "estimated layout"} tip=Glossary.measured tone={p.measured ? "good" : ""} />
           <Badge text={Printf.sprintf("%d slots", Array.length(p.slots))} tip=Glossary.p />
         </span>
       | None =>
         prompt == ""
           ? <button className="ghost" onClick={_ => onSimulate()}> {s("Show slots for the example creative")} </button>
           : React.null
       }}
    </div>
    {switch (archived) {
     | Some(false) =>
       <Empty
         title="Not archived yet"
         text="Pages crawled before the archive existed have no raw record. Re-crawl it to see the page itself.">
         <button className="primary" onClick={_ => crawlPage(page.url)}> {s("Re-crawl")} </button>
       </Empty>
     | _ => React.null
     }}
    <div className="replay-body">
      <div className="replay-stage" ref={ReactDOM.Ref.domRef(stage)}>
        <div
          className="replay-scaler"
          style={ReactDOM.Style.make(
            ~width=px(deviceWidth),
            ~height=px(Float.max(viewport, height)),
            ~transform=Printf.sprintf("scale(%.4f)", scale),
            (),
          )}>
          <iframe
            key={device ++ page.url}
            ref={ReactDOM.Ref.domRef(frame)}
            src
            sandbox="allow-same-origin"
            title={page.title}
            onLoad
            style={ReactDOM.Style.make(~width=px(deviceWidth), ~height=px(Float.max(viewport, height)), ())}
          />
          <div className="replay-overlay">
            {switch (activeSlot) {
             | Some(sl) =>
               switch (slotY(sl), placement) {
               | (Some(y), Some(p)) =>
                 let g = p.geometry;
                 let above = 3. *. g.reach_above *. viewport and below = 3. *. g.reach_below *. viewport;
                 <>
                   <div
                     className="ov-kernel"
                     style={ReactDOM.Style.make(
                       ~top=px(Float.max(0., y -. above)),
                       ~height=px(Float.min(y, above)),
                       ~background=kernel(~toward="top", g.reach_above),
                       (),
                     )}
                   />
                   <div
                     className="ov-kernel"
                     style={ReactDOM.Style.make(~top=px(y), ~height=px(below), ~background=kernel(~toward="bottom", g.reach_below), ())}
                   />
                   <div
                     className="ov-window"
                     style={ReactDOM.Style.make(
                       ~top=px(Float.max(0., y -. g.co_visible *. viewport)),
                       ~height=px(2. *. g.co_visible *. viewport),
                       (),
                     )}
                     onMouseEnter={Tip.enter(Glossary.coVisible)}
                     onMouseLeave=Tip.leave
                   />
                 </>;
               | _ => React.null
               }
             | None => React.null
             }}
            {boxes
             |> Array.map(b =>
                  switch (segmentOf(b.i)) {
                  | Some(g) =>
                    let fill = shade(g);
                    <div
                      key={string_of_int(b.i)}
                      className={"ov-seg" ++ (g.main ? "" : " boiler") ++ (flagged(b.i) ? " flagged" : "")}
                      style={ReactDOM.Style.make(
                        ~top=px(b.top),
                        ~left=px(b.left),
                        ~width=px(b.width),
                        ~height=px(b.height),
                        ~background=Option.value(fill, ~default="transparent"),
                        (),
                      )}
                      onMouseEnter={Tip.enter(tip(g))}
                      onMouseLeave=Tip.leave
                    />;
                  | None => React.null
                  }
                )
             |> React.array}
            {slots
             |> Array.map((sl: slot) =>
                  switch (slotY(sl)) {
                  | Some(y) =>
                    <div
                      key={"slot" ++ string_of_int(sl.after)}
                      className={"ov-slot" ++ (sl.blocked ? " blocked" : "") ++ (active == Some(sl.after) ? " active" : "")}
                      style={ReactDOM.Style.make(~top=px(y), ~borderColor=sl.blocked ? "var(--bad)" : heat(sl.p), ())}
                      onClick={_ => setActive(a => a == Some(sl.after) ? None : Some(sl.after))}>
                      <span style={ReactDOM.Style.make(~background=sl.blocked ? "var(--bad)" : heat(sl.p), ())}>
                        {s((sl.ad == "" ? "" : sl.ad ++ "  ") ++ (sl.blocked ? "blocked" : "P " ++ pct(sl.p)))}
                      </span>
                    </div>
                  | None => React.null
                  }
                )
             |> React.array}
          </div>
        </div>
      </div>
      <aside className="replay-side">
        <Card title="Selected slot" tip=Glossary.boundary>
          {switch (activeSlot, placement) {
           | (Some(sl), Some(p)) =>
             <>
               <div className="row">
                 <b> {s(Printf.sprintf("%.1f viewports down", sl.y))} </b>
                 {sl.ad == ""
                    ? <Badge text="between blocks" tip=Glossary.heuristicSlot />
                    : <Badge
                        text={sl.ad ++ (switch (find((a: adSlot) => a.id == sl.ad, page.ad_slots)) {
                                        | Some(a) when a.learned => " (learned)"
                                        | _ => ""
                                        })}
                        tip=Glossary.adSlot
                        tone="good"
                      />}
                 {sl.blocked ? <Badge text="blocked" tip=Glossary.blocked tone="bad" /> : <Badge text={"P " ++ pct(sl.p)} tip=Glossary.p />}
               </div>
               <p className="muted">
                 {s(
                    Printf.sprintf(
                      "%s: the page counts for %s, the blocks around for %s, weighted by exp(-d / %.1f) above and exp(-d / %.1f) below (d in viewports). Sensitive blocks within %.0f viewport block it.",
                      format,
                      pct(p.geometry.page_weight),
                      pct(1. -. p.geometry.page_weight),
                      p.geometry.reach_above,
                      p.geometry.reach_below,
                      p.geometry.co_visible,
                    ),
                  )}
               </p>
               <ul className="reasons">
                 {sl.reasons |> Array.mapi((i, r) => <li key={string_of_int(i)}> {s(r)} </li>) |> React.array}
               </ul>
             </>
           | _ => <p className="muted"> {s("Click a slot on the page.")} </p>
           }}
        </Card>
        <Card title="Slots by P" tip=Glossary.p>
          {let sorted = Array.copy(slots);
           Array.stable_sort((a: slot, b: slot) => compare(b.p, a.p), sorted);
           <div className="slots">
             {sorted
              |> take(12)
              |> Array.map((sl: slot) =>
                   <SlotBar key={string_of_int(sl.after)} slot=sl active={active == Some(sl.after)} onPick={a => setActive(_ => Some(a))} />
                 )
              |> React.array}
           </div>}
        </Card>
        <p className="muted">
          {s(
             Printf.sprintf(
               "%d of the %d extracted blocks are on screen; the others are hidden in the rendered page (menus, dialogs). %s %s",
               Array.length(boxes),
               Array.length(page.segments),
               switch (Array.length(page.ad_slots)) {
               | 0 => "No ad container in the HTML: slots go between blocks."
               | n => Printf.sprintf("%d ad containers from the template.", n)
               },
               Array.length(page.articles) > 1
                 ? Printf.sprintf("%d stories on this URL: each slot takes its own as its page.", Array.length(page.articles)) : "",
             ),
           )}
        </p>
      </aside>
    </div>
  </div>;
};
