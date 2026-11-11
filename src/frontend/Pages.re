/* Every crawled page: find one, then read what each level made of it. */

open Api;
open Ui;

let levels = Golden.levels;

type filters = {
  query: string,
  site: string,
  judged: string,
  sensitive: bool,
  stop: string,
  sort: string,
};

let initial = {
  query: "",
  site: "",
  judged: "all",
  sensitive: false,
  stop: "",
  sort: "newest",
};
let withQuery = query => {...initial, query};
let withSite = site => {...initial, site};

let best = (p: summary) => Array.length(p.labels) > 0 ? p.labels[0].score : 0.;

let matches = (f, p: summary) => {
  let q = lower(f.query);
  (
    q == ""
    || includes(
         lower(
           p.title
           ++ " "
           ++ p.url
           ++ " "
           ++ String.concat(" ", Array.to_list(Array.map((l: label) => l.path, p.labels))),
         ),
         q,
       )
  )
  && (f.site == "" || p.site == f.site)
  && (f.judged == "all" || f.judged == "judged" == p.adjudicated)
  && (!f.sensitive || p.sensitive)
  && (f.stop == "" || p.stop == f.stop);
};

let visible = (f, pages) => {
  let a = pages |> filter(matches(f));
  let cmp =
    switch (f.sort) {
    | "title" => ((x: summary, y: summary) => compare(lower(x.title), lower(y.title)))
    | "site" => ((x: summary, y: summary) => compare(x.site, y.site))
    | "spend" => ((x: summary, y: summary) => compare(y.spent, x.spent))
    | "confidence" => ((x, y) => compare(best(y), best(x)))
    | _ => ((x: summary, y: summary) => compare(y.fetched_at, x.fetched_at))
    };
  Array.stable_sort(cmp, a);
  a;
};

module PageList = {
  [@react.component]
  let make = (~pages: array(summary), ~shown: array(summary), ~filters, ~setFilters, ~selected, ~onSelect) => {
    let (more, setLimit) = React.useState(() => 150);
    let rec index = i =>
      i >= Array.length(shown) ? (-1) : shown[i].url == selected ? i : index(i + 1);
    /* j / k may walk past the rendered rows: keep the selection rendered. */
    let limit = max(more, index(0) + 30);
    let sites = React.useMemo1(() => count((p: summary) => p.site, pages), [|pages|]);
    let set = f => setFilters(_ => f);
    <div className="pagelist">
      <div className="side-head">
        <input
          className="search"
          placeholder="Search title, URL or category"
          value={filters.query}
          onChange={e => set({...filters, query: value(e)})}
        />
        <div className="row">
          <select value={filters.site} onChange={e => set({...filters, site: value(e)})}>
            <option value=""> {s(Printf.sprintf("All sites (%d)", Array.length(sites)))} </option>
            {sites
             |> Array.map(((site, n)) =>
                  <option key=site value=site>
                    {s(Printf.sprintf("%s (%d)", site, n))}
                  </option>
                )
             |> React.array}
          </select>
          <select value={filters.sort} onChange={e => set({...filters, sort: value(e)})}>
            <option value="newest"> {s("Newest")} </option>
            <option value="confidence"> {s("Most confident")} </option>
            <option value="spend"> {s("Most spent")} </option>
            <option value="title"> {s("Title")} </option>
            <option value="site"> {s("Site")} </option>
          </select>
        </div>
        <div className="row">
          <Tabs
            tabs=[|("all", "All"), ("unjudged", "To judge"), ("judged", "Judged")|]
            current={filters.judged}
            onChange={j => set({...filters, judged: j})}
          />
        </div>
        <div className="row">
          <label className="check">
            <input
              type_="checkbox"
              checked={filters.sensitive}
              onChange={_ => set({...filters, sensitive: !filters.sensitive})}
            />
            {s("Sensitive only")}
          </label>
          <select value={filters.stop} onChange={e => set({...filters, stop: value(e)})}>
            <option value=""> {s("Any stop")} </option>
            <option value="settled"> {s("settled")} </option>
            <option value="out of budget"> {s("out of budget")} </option>
            <option value="no more tiers"> {s("no more tiers")} </option>
          </select>
        </div>
        <div className="row spread muted">
          <span>
            {s(Printf.sprintf("%d of %d pages", Array.length(shown), Array.length(pages)))}
          </span>
          {filters == initial
             ? <span> {s("j / k to move")} </span>
             : <button className="link" onClick={_ => set(initial)}>
                 {s("Clear filters")}
               </button>}
        </div>
      </div>
      <ul className="items">
        {shown
         |> take(limit)
         |> Array.map((p: summary) =>
              <li
                key={p.url}
                id={"item-" ++ p.url}
                className={selected == p.url ? "selected" : ""}
                onClick={_ => onSelect(p.url)}>
                <div className="title"> {s(clip(110, p.title == "" ? p.url : p.title))} </div>
                <div className="meta">
                  {s(p.site ++ "  |  " ++ ago(p.fetched_at))}
                  {p.adjudicated ? <Badge text="judged" tone="good" /> : React.null}
                  {p.sensitive ? <Badge text="sensitive" tone="bad" /> : React.null}
                </div>
                {chips(p.labels)}
              </li>
            )
         |> React.array}
      </ul>
      {Array.length(shown) > limit
         ? <button className="ghost more" onClick={_ => setLimit(l => l + 300)}>
             {s(Printf.sprintf("Show more (%d left)", Array.length(shown) - limit))}
           </button>
         : React.null}
    </div>;
  };
};

module Evidence = {
  [@react.component]
  let make = (~base, ~evidence: array(evidence)) =>
    Array.length(evidence) == 0
      ? <p className="muted"> {s("No evidence kept for this label at this level.")} </p>
      : <ul className="evidence">
          {evidence
           |> Array.mapi((i, e: evidence) =>
                <li key={string_of_int(i)}>
                  {tierBadge(e.tier)}
                  <span className="zone"> {s(e.zone)} </span>
                  <span className="why"> {s(e.why)} </span>
                  {e.tier == "t3" && e.zone == "image"
                     ? <img
                         className="thumb"
                         src={Browser.resolve(~base, e.quote)}
                         alt=""
                         referrerPolicy="no-referrer"
                       />
                     : e.quote == "" ? React.null : <q> {s(clip(400, e.quote))} </q>}
                </li>
              )
           |> React.array}
        </ul>;
};

type row = {
  id: string,
  path: string,
  sensitive: bool,
  scores: array(option(float)),
  top: float,
};

/* Labels as rows, levels as columns, plus the gold labels no level found. */
let matrix = (page: page) => {
  let h = Hashtbl.create(32);
  Array.iteri(
    (i, preset) =>
      switch (page.levels |> find((l: level) => l.preset == preset)) {
      | Some(l) =>
        Array.iter(
          (x: label) => {
            let r =
              switch (Hashtbl.find_opt(h, x.id)) {
              | Some(r) => r
              | None => {
                  id: x.id,
                  path: x.path,
                  sensitive: x.sensitive,
                  scores: Array.make(Array.length(levels), None),
                  top: 0.,
                }
              };
            r.scores[i] = Some(x.score);
            Hashtbl.replace(h, x.id, {...r, top: Float.max(r.top, x.score)});
          },
          l.labels,
        )
      | None => ()
      },
    levels,
  );
  switch (Js.Nullable.toOption(page.gold)) {
  | Some(g) =>
    Array.iter(
      (x: label) =>
        if (!Hashtbl.mem(h, x.id)) {
          Hashtbl.replace(
            h,
            x.id,
            {
              id: x.id,
              path: x.path,
              sensitive: x.sensitive,
              scores: Array.make(Array.length(levels), None),
              top: -1.,
            },
          );
        },
      g.labels,
    )
  | None => ()
  };
  let rows = Array.of_list(Hashtbl.fold((_, r, acc) => [r, ...acc], h, []));
  Array.stable_sort((a, b) => compare(b.top, a.top), rows);
  rows;
};

let evidenceOf = (page: page, level, id) => {
  let at = preset =>
    switch (page.levels |> find((l: level) => l.preset == preset)) {
    | Some(l) => find((x: label) => x.id == id, l.labels)
    | None => None
    };
  switch (at(level)) {
  | Some(x) => x.evidence
  | None =>
    switch (List.find_map(at, ["deep", "rich", "standard", "zero_fetch"])) {
    | Some(x) => x.evidence
    | None => [||]
    }
  };
};

module Matrix = {
  [@react.component]
  let make = (~page: page, ~level) => {
    let (opened, setOpened) = React.useState(() => None);
    let rows = matrix(page);
    let current =
      switch (List.find_opt(i => levels[i] == level, List.init(Array.length(levels), i => i))) {
      | Some(i) => i
      | None => 1
      };
    let gold = Js.Nullable.toOption(page.gold);
    let served =
      switch (find((l: level) => l.preset == level, page.levels)) {
      | Some(l) => l.served
      | None => [||]
      };
    /* As hierarchical F1 counts: a served label (ancestors included) is right
       when gold implies it; a gold leaf the level does not serve is missed. */
    let verdict = r => {
      let isServed = Array.mem(r.id, served);
      switch (gold) {
      | None => React.null
      | Some(g) =>
        if (Array.mem(r.id, g.closure)) {
          isServed
            ? <Badge text="right" tone="good" />
            : Array.exists((x: label) => x.id == r.id, g.labels)
                ? <Badge text="missed" tone="warn" /> : React.null;
        } else if (isServed) {
          <Badge text="wrong" tone="bad" />;
        } else {
          React.null;
        }
      };
    };
    <table className="grid matrix">
      <thead>
        <tr>
          <th> {s("category")} <Help tip=Glossary.matrix /> </th>
          {levels
           |> Array.mapi((i, l) =>
                <th key=l className={"num" ++ (i == current ? " current" : "")}>
                  {s(l)}
                  <Help tip={Glossary.level(l)} />
                </th>
              )
           |> React.array}
          {gold == None
             ? React.null
             : <th> {s("gold")} <Help tip=Glossary.verdict /> </th>}
        </tr>
      </thead>
      <tbody>
        {rows
         |> Array.map(r => {
              let isOpen = opened == Some(r.id);
              <React.Fragment key={r.id}>
                <tr
                  className={"link" ++ (r.sensitive ? " sensitive" : "") ++ (isOpen ? " open" : "")}
                  onClick={_ => setOpened(o => o == Some(r.id) ? None : Some(r.id))}>
                  <td className="path">
                    <span className="caret"> {s(isOpen ? "v" : ">")} </span>
                    {s(r.path)}
                  </td>
                  {r.scores
                   |> Array.mapi((i, sc) =>
                        switch (sc) {
                        | Some(x) =>
                          <td
                            key={string_of_int(i)}
                            className={
                              "num"
                              ++ (i == current ? " current" : "")
                              ++ (x >= 0.5 ? " served" : "")
                            }
                            style={tint(x)}>
                            {s(num(x))}
                          </td>
                        | None =>
                          <td
                            key={string_of_int(i)}
                            className={"num muted" ++ (i == current ? " current" : "")}>
                            {s("-")}
                          </td>
                        }
                      )
                   |> React.array}
                  {gold == None ? React.null : <td> {verdict(r)} </td>}
                </tr>
                {isOpen
                   ? <tr className="expand">
                       <td colSpan=6>
                         <Evidence base={page.url} evidence={evidenceOf(page, level, r.id)} />
                       </td>
                     </tr>
                   : React.null}
              </React.Fragment>;
            })
         |> React.array}
      </tbody>
    </table>;
  };
};

module Minimap = {
  [@react.component]
  let make = (~segments: array(segment), ~slots: array(slot), ~active, ~onSegment, ~onSlot) => {
    let total =
      Array.fold_left((m, g: segment) => Float.max(m, g.top +. g.height), 0.01, segments);
    let y = v => pct1(v /. total);
    let bottom = i =>
      switch (segments |> find((g: segment) => g.i == i)) {
      | Some(g) => g.top +. g.height
      | None => 0.
      };
    <div className="minimap">
      {segments
       |> Array.map((g: segment) =>
            <span
              key={string_of_int(g.i)}
              className={"mm-seg " ++ (g.main ? g.tag : "boiler")}
              style={ReactDOM.Style.make(
                ~top=y(g.top),
                ~height=y(Float.max(g.height, total *. 0.003)),
                (),
              )}
              onClick={_ => onSegment(g.i)}
            />
          )
       |> React.array}
      {slots
       |> Array.map((sl: slot) =>
            <span
              key={"slot" ++ string_of_int(sl.after)}
              className={"mm-slot" ++ (active == Some(sl.after) ? " active" : "")}
              style={ReactDOM.Style.make(
                ~top=y(bottom(sl.after)),
                ~background=sl.blocked ? "var(--bad)" : heat(sl.p),
                (),
              )}
              onMouseEnter={Tip.enter(
                sl.blocked
                  ? "blocked: " ++ String.concat("; ", Array.to_list(sl.reasons))
                  : Printf.sprintf("P %s (fit %s, reach %s)", pct(sl.p), pct(sl.fit), pct(sl.reach)),
              )}
              onMouseLeave=Tip.leave
              onClick={_ => onSlot(sl.after)}
            />
          )
       |> React.array}
    </div>;
  };
};

module Article = {
  [@react.component]
  let make = (~page: page, ~placement: option(placement), ~prompt, ~onSimulate) => {
    let (boiler, setBoiler) = React.useState(() => false);
    let (active, setActive) = React.useState(() => None);
    let slots =
      switch (placement) {
      | Some(p) => p.slots
      | None => [||]
      };
    let slotAfter = i => slots |> find((sl: slot) => sl.after == i);
    let activeSlot = Option.bind(active, slotAfter);
    let flagged = i =>
      switch (activeSlot) {
      | Some(sl) => Array.mem(i, sl.flagged)
      | None => false
      };
    let hidden = Array.length(page.segments |> filter((g: segment) => !g.main));
    let open_ = Array.length(slots |> filter((sl: slot) => !sl.blocked));
    let bestP = Array.fold_left((m, sl: slot) => sl.blocked ? m : Float.max(m, sl.p), 0., slots);
    let pick = i => {
      setActive(_ => Some(i));
      Browser.scrollTo("slot-" ++ string_of_int(i));
    };
    let bar = (sl: slot) =>
      <div id={"slot-" ++ string_of_int(sl.after)} key={"slot" ++ string_of_int(sl.after)}>
        <SlotBar slot=sl active={active == Some(sl.after)} onPick=pick />
      </div>;
    <div className="article-view">
      <div className="toolbar">
        <label className="check">
          <input type_="checkbox" checked=boiler onChange={_ => setBoiler(b => !b)} />
          {s(Printf.sprintf("Show %d boilerplate blocks", hidden))}
        </label>
        <Help tip=Glossary.boilerplate />
        <span className="spacer" />
        {switch (placement) {
         | Some(_) =>
           <span className="row">
             <span className="muted"> {s("Creative: " ++ clip(48, prompt))} </span>
             <Badge text={Printf.sprintf("%d open slots", open_)} tip=Glossary.p />
             <Badge
               text={"best P " ++ pct(bestP)}
               tip=Glossary.p
               tone={bestP >= 0.4 ? "good" : ""}
             />
             {Array.length(slots) > open_
                ? <Badge
                    text={Printf.sprintf("%d blocked", Array.length(slots) - open_)}
                    tip=Glossary.blocked
                    tone="bad"
                  />
                : React.null}
           </span>
         | None =>
           prompt == ""
             ? <button className="ghost" onClick={_ => onSimulate()}>
                 {s("Show slots for the example creative")}
               </button>
             : <span className="muted"> {s("Scoring slots...")} </span>
         }}
      </div>
      {switch (activeSlot) {
       | Some(sl) =>
         <div className="slot-detail">
           <b> {s(Printf.sprintf("Slot %.1f viewports down", sl.y))} </b>
           <span>
             {s(Printf.sprintf(" fit %s ", pct(sl.fit)))}
             <Help tip=Glossary.fit />
             {s(Printf.sprintf(" reach %s ", pct(sl.reach)))}
             <Help tip=Glossary.reach />
           </span>
           <ul>
             {sl.reasons
              |> Array.mapi((i, r) => <li key={string_of_int(i)}> {s(r)} </li>)
              |> React.array}
           </ul>
           {Array.length(sl.flagged) > 0
              ? <div className="muted">
                  {s(Printf.sprintf("%d co-visible blocks flagged ", Array.length(sl.flagged)))}
                  <Help tip=Glossary.flagged />
                </div>
              : React.null}
         </div>
       | None => React.null
       }}
      <div className="article-body">
        <Minimap
          segments={page.segments}
          slots
          active
          onSegment={i => Browser.scrollTo("seg-" ++ string_of_int(i))}
          onSlot=pick
        />
        <div className="article">
          {switch (slotAfter(-1)) {
           | Some(sl) => bar(sl)
           | None => React.null
           }}
          {page.segments
           |> filter((g: segment) => g.main || boiler || flagged(g.i))
           |> Array.map((g: segment) =>
                <div key={string_of_int(g.i)}>
                  <div
                    id={"seg-" ++ string_of_int(g.i)}
                    className={
                      "seg "
                      ++ g.tag
                      ++ (g.main ? "" : " boiler")
                      ++ (flagged(g.i) ? " flagged" : "")
                    }>
                    <span className="tag"> {s(g.tag)} </span>
                    <span className="text">
                      {s(g.text == "" ? "(no text)" : clip(600, g.text))}
                    </span>
                    {Array.length(g.labels) == 0 ? React.null : chips(g.labels)}
                  </div>
                  {switch (slotAfter(g.i)) {
                   | Some(sl) => bar(sl)
                   | None => React.null
                   }}
                </div>
              )
           |> React.array}
        </div>
      </div>
    </div>;
  };
};

module Cascade = {
  [@react.component]
  let make = (~page: page, ~level) => {
    let gate = lower(page.t4_gate);
    <>
      <Card title="What each level ran" tip=Glossary.depth>
        <table className="grid">
          <thead>
            <tr>
              <th> {s("level")} </th>
              <th> {s("tiers that ran")} </th>
              <th className="num"> {s("spent")} <Help tip=Glossary.spent /> </th>
              <th> {s("stop")} </th>
              <th className="num"> {s("served")} <Help tip=Glossary.score /> </th>
            </tr>
          </thead>
          <tbody>
            {page.levels
             |> Array.map((l: level) =>
                  <tr key={l.preset} className={l.preset == level ? "current" : ""}>
                    <td> {s(l.preset)} <Help tip={Glossary.level(l.preset)} /> </td>
                    <td className="tiers"> {l.ran |> Array.map(tierBadge) |> React.array} </td>
                    <td className="num"> {s(money(l.spent))} </td>
                    <td> {stopBadge(l.stop)} </td>
                    <td className="num"> {s(string_of_int(l.served_count))} </td>
                  </tr>
                )
             |> React.array}
          </tbody>
        </table>
      </Card>
      <div className="cols">
        <Card title="T4 gate" tip=Glossary.t4Gate>
          <p
            className={
              String.length(gate) >= 7 && String.sub(gate, 0, 7) == "allowed"
                ? "good" : includes(gate, "denied") ? "bad" : "muted"
            }>
            {s(page.t4_gate)}
          </p>
        </Card>
        <Card title="Keywords" tip=Glossary.keywords>
          {Array.length(page.keywords) == 0
             ? <p className="muted"> {s("None extracted.")} </p>
             : <div className="keywords">
                 {page.keywords |> Array.map(k => <span key=k className="kw"> {s(k)} </span>) |> React.array}
               </div>}
        </Card>
      </div>
      <Card title="Raw data">
        <div className="row">
          <a className="button ghost" href={"/crawler/inspect?url=" ++ encode(page.url)} target="_blank">
            {s("Stored profile and cascade trace")}
          </a>
          <a className="button ghost" href={"/api/page?url=" ++ encode(page.url)} target="_blank">
            {s("Page JSON")}
          </a>
        </div>
      </Card>
    </>;
  };
};

module Detail = {
  [@react.component]
  let make =
      (~url, ~version, ~level, ~format, ~avoid, ~prompt, ~onSimulate, ~tab, ~setTab, ~onSaved) => {
    let page = usePage(url, version);
    let placement =
      usePlacement(~prompt=tab == "content" ? prompt : "", ~url, ~level, ~format, ~avoid);
    switch (page) {
    | Loading => <div className="loading"> {s("Loading the page...")} </div>
    | Missing =>
      <Empty title="Not crawled" text={"No stored profile for " ++ url ++ "."}>
        <button className="primary" onClick={_ => crawlPage(url)}> {s("Crawl it now")} </button>
      </Empty>
    | Ready(p) =>
      let gold = Js.Nullable.toOption(p.gold);
      let current = find((l: level) => l.preset == level, p.levels);
      <div className="detail">
        <header className="detail-head">
          <div>
            <h2> {s(p.title == "" ? p.url : p.title)} </h2>
            <div className="meta">
              <a href={p.url} target="_blank" rel="noreferrer"> {s(clip(90, p.url))} </a>
              {s("  |  " ++ p.site ++ "  |  fetched " ++ ago(p.fetched_at))}
            </div>
            <div className="row">
              {switch (current) {
               | Some(l) =>
                 <>
                   {stopBadge(l.stop)}
                   <Badge text={money(l.spent)} tip=Glossary.spent />
                   {chips(take(5, l.labels))}
                 </>
               | None => React.null
               }}
            </div>
          </div>
          <div className="actions">
            {gold == None
               ? React.null
               : <Badge text="in the golden set" tip=Glossary.gold tone="good" />}
            <button className="ghost" onClick={_ => copy(p.url)}> {s("Copy URL")} </button>
            <button className="ghost" onClick={_ => crawlPage(p.url)}> {s("Re-crawl")} </button>
          </div>
        </header>
        <Tabs
          tabs=[|
            ("labels", "Labels"),
            ("page", "Page"),
            ("content", "Extracted blocks"),
            ("cascade", "Cascade"),
            ("judge", "Golden set"),
          |]
          current=tab
          onChange=setTab
        />
        {switch (tab) {
         | "page" => <Replay key={p.url} page=p prompt level format avoid onSimulate />
         | "content" => <Article page=p placement prompt onSimulate />
         | "cascade" => <Cascade page=p level />
         | "judge" => <Golden.Judge key={p.url} url={p.url} onSaved={_ => onSaved()} />
         | _ =>
           <Card>
             <Matrix page=p level />
           </Card>
         }}
      </div>
    };
  };
};

[@react.component]
let make =
    (
      ~pages: array(summary),
      ~filters,
      ~setFilters,
      ~url,
      ~select,
      ~version,
      ~level,
      ~format,
      ~avoid,
      ~prompt,
      ~onSimulate,
      ~tab,
      ~setTab,
      ~onSaved,
    ) => {
  let shown = React.useMemo2(() => visible(filters, pages), (filters, pages));
  React.useEffect3(
    () => {
      let handler = ev =>
        if (!Browser.typing(ev) && !Browser.metaKey(ev) && !Browser.ctrlKey(ev) && tab != "judge") {
          let n = Array.length(shown);
          let rec index = i => i >= n ? (-1) : shown[i].url == url ? i : index(i + 1);
          let move = d =>
            if (n > 0) {
              let i = index(0);
              let j = i < 0 ? 0 : max(0, min(n - 1, i + d));
              select(shown[j].url);
              Browser.scrollTo("item-" ++ shown[j].url);
            };
          switch (Browser.key(ev)) {
          | "j" => move(1)
          | "k" => move(-1)
          | _ => ()
          };
        };
      Browser.addKeyListener("keydown", handler);
      Some(() => Browser.removeKeyListener("keydown", handler));
    },
    (shown, url, tab),
  );
  <div className="view split">
    <aside className="side">
      <PageList pages shown filters setFilters selected=url onSelect=select />
    </aside>
    <main className="pane">
      {url == ""
         ? <Empty
             title="Pick a page"
             text="Choose a page on the left, or press j to open the first one. Search matches titles, URLs and categories."
           />
         : <Detail url version level format avoid prompt onSimulate tab setTab onSaved />}
    </main>
  </div>;
};
