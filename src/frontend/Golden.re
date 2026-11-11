/* The golden set: judge a page's categories, fast, and see how each level
   agrees with the judgements so far. */

open Api;
open Ui;

let levels = [|"zero_fetch", "standard", "rich", "deep"|];
let deep = (c: candidate) =>
  Option.value(Js.Dict.get(c.scores, "deep"), ~default=0.);
let best = (c: candidate) =>
  Array.fold_left(Float.max, 0., Js.Dict.values(c.scores));
let sortedIds = a => {
  let b = Array.copy(a);
  Array.sort(compare, b);
  b;
};

module Judge = {
  [@react.component]
  let make = (~url, ~onSaved, ~onNext=() => (), ~onPrev=() => ()) => {
    /* Remounted per page (key=url) by its callers; the latest callbacks are
       read through a ref so the key handler and a late save never act on a
       stale queue. */
    let callbacks = React.useRef((onSaved, onNext, onPrev));
    callbacks.current = (onSaved, onNext, onPrev);
    let (loaded, setLoaded) = React.useState(() => false);
    let (rows, setRows) = React.useState(() => [||]);
    let (gold, setGold) = React.useState(() => [||]);
    let (initial, setInitial) = React.useState(() => [||]);
    let (savedAt, setSavedAt) = React.useState(() => None);
    let (query, setQuery) = React.useState(() => "");
    let (found, setFound) = React.useState(() => [||]);
    let (opened, setOpened) = React.useState(() => None);

    React.useEffect1(
      () => {
        let live = ref(true);
        load(
          ~what="Loading the candidates",
          get("/api/adjudication?url=" ++ encode(url)),
          (a: adjudication) => if (live^) {
            let saved = Js.Nullable.toOption(a.saved);
            let start =
              switch (saved) {
              | Some(j) => j.gold
              | None =>
                a.candidates
                |> filter(c => deep(c) >= 0.5)
                |> Array.map((c: candidate) => c.id)
              };
            let rs = Array.copy(a.candidates);
            Array.stable_sort((x, y) => compare(best(y), best(x)), rs);
            setRows(_ => rs);
            setGold(_ => start);
            setInitial(_ => start);
            setSavedAt(_ => Option.map((j: judgement) => j.at, saved));
            setLoaded(_ => true);
          },
        );
        Some(() => live := false);
      },
      [|url|],
    );

    React.useEffect1(
      () =>
        if (String.length(query) < 2) {
          setFound(_ => [||]);
          None;
        } else {
          let live = ref(true);
          let t =
            Js.Global.setTimeout(
              ~f=
                () =>
                  load(get("/api/taxonomy?q=" ++ encode(query)), (ls: array(label)) =>
                    if (live^) {
                      setFound(_ => ls);
                    }
                  ),
              150,
            );
          Some(
            () => {
              live := false;
              Js.Global.clearTimeout(t);
            },
          );
        },
      [|query|],
    );

    let toggle = id =>
      setGold(g =>
        Array.mem(id, g) ? g |> filter(x => x != id) : Array.append(g, [|id|])
      );
    let add = (l: label) => {
      if (!Array.exists((c: candidate) => c.id == l.id, rows)) {
        let row: candidate = {
          id: l.id,
          path: l.path,
          score: 0.,
          sensitive: l.sensitive,
          evidence: [||],
          scores: Js.Dict.empty(),
        };
        setRows(r => Array.append(r, [|row|]));
      };
      setGold(g => Array.mem(l.id, g) ? g : Array.append(g, [|l.id|]));
      setQuery(_ => "");
    };
    let defaults = () =>
      setGold(_ =>
        rows |> filter(c => deep(c) >= 0.5) |> Array.map((c: candidate) => c.id)
      );
    let save = next =>
      if (loaded) {
      let rejected =
        rows
        |> filter((c: candidate) => !Array.mem(c.id, gold))
        |> Array.map((c: candidate) => c.id);
      load(
        ~what="Saving the judgement",
        post("/api/adjudication", {"url": url, "gold": gold, "rejected": rejected}),
        (j: judgement) => {
          setSavedAt(_ => Some(j.at));
          setInitial(_ => gold);
          toast(Printf.sprintf("Saved %d categories", Array.length(gold)));
          let (saved, _, _) = callbacks.current;
          saved(next);
        },
      );
      };
    let forget = () =>
      load(
        ~what="Forgetting the judgement",
        delete("/api/adjudication?url=" ++ encode(url)),
        _ => {
          setSavedAt(_ => None);
          toast("Judgement removed");
          let (saved, _, _) = callbacks.current;
          saved(false);
        },
      );
    let dirty = sortedIds(gold) != sortedIds(initial);

    React.useEffect3(
      () => {
        let handler = ev =>
          if (!Browser.typing(ev)
              && !Browser.metaKey(ev)
              && !Browser.ctrlKey(ev)
              && !Browser.altKey(ev)) {
            switch (Browser.key(ev)) {
            | "Enter" =>
              Browser.preventDefault(ev);
              save(true);
            | "d" => defaults()
            | "j" =>
              let (_, next, _) = callbacks.current;
              next();
            | "k" =>
              let (_, _, prev) = callbacks.current;
              prev();
            | "/" =>
              Browser.preventDefault(ev);
              switch (Browser.byId("taxonomy-search")) {
              | Some(e) => Browser.focus(e)
              | None => ()
              };
            | k when String.length(k) == 1 && k >= "1" && k <= "9" =>
              let i = int_of_string(k) - 1;
              if (i < Array.length(rows)) {
                toggle(rows[i].id);
              };
            | _ => ()
            };
          };
        Browser.addKeyListener("keydown", handler);
        Some(() => Browser.removeKeyListener("keydown", handler));
      },
      (rows, gold, url),
    );

    <div className="judge">
      <div className="judge-head">
        <h3>
          {s("Tick every category this page is about")}
          <Help tip=Glossary.candidates />
        </h3>
        <span className="row">
          {dirty
             ? <Badge text="unsaved changes" tone="warn" />
             : switch (savedAt) {
               | Some(t) => <Badge text={"saved " ++ ago(t)} tone="good" />
               | None => <Badge text="not judged yet" />
               }}
          <Badge text="shortcuts" tip=Glossary.shortcuts />
        </span>
      </div>
      {!loaded
         ? <p className="muted"> {s("Loading the candidates...")} </p>
         : Array.length(rows) == 0
         ? <p className="muted"> {s("No level found a label here: add the page's categories below.")} </p>
         : <table className="grid judge-table">
             <thead>
               <tr>
                 <th />
                 <th> {s("category")} </th>
                 {levels
                  |> Array.map(l =>
                       <th key=l className="num">
                         {s(l)}
                         <Help tip={Glossary.level(l)} />
                       </th>
                     )
                  |> React.array}
               </tr>
             </thead>
             <tbody>
               {rows
                |> Array.mapi((i, c: candidate) => {
                     let on = Array.mem(c.id, gold);
                     let isOpen = opened == Some(c.id);
                     <tr
                       key={c.id}
                       className={
                         (on ? "on" : "") ++ (c.sensitive ? " sensitive" : "")
                       }
                       onClick={_ => toggle(c.id)}>
                       <td className="tick">
                         <input type_="checkbox" checked=on readOnly=true />
                         {i < 9
                            ? <kbd> {s(string_of_int(i + 1))} </kbd>
                            : React.null}
                       </td>
                       <td>
                         <div className="path"> {s(c.path)} </div>
                         {switch (c.evidence) {
                          | [||] =>
                            Js.Dict.keys(c.scores) == [||]
                              ? <div className="muted"> {s("added by the judge")} </div>
                              : React.null
                          | ev =>
                            <div
                              className="quote"
                              onClick={e => {
                                React.Event.Mouse.stopPropagation(e);
                                setOpened(o => o == Some(c.id) ? None : Some(c.id));
                              }}>
                              {(isOpen ? ev : take(1, ev))
                               |> Array.mapi((j, e: evidence) =>
                                    <div key={string_of_int(j)}>
                                      {tierBadge(e.tier)}
                                      <q> {s(clip(isOpen ? 400 : 110, e.quote))} </q>
                                    </div>
                                  )
                               |> React.array}
                              {Array.length(ev) > 1 && !isOpen
                                 ? <span className="more">
                                     {s(Printf.sprintf("+%d more", Array.length(ev) - 1))}
                                   </span>
                                 : React.null}
                            </div>
                          }}
                       </td>
                       {levels
                        |> Array.map(l =>
                             switch (Js.Dict.get(c.scores, l)) {
                             | Some(x) =>
                               <td key=l className="num" style={tint(x)}>
                                 {s(num(x))}
                               </td>
                             | None => <td key=l className="num muted"> {s("-")} </td>
                             }
                           )
                        |> React.array}
                     </tr>;
                   })
                |> React.array}
             </tbody>
           </table>}
      <div className="add">
        <input
          id="taxonomy-search"
          placeholder="Add a category every level missed  ( / )"
          value=query
          onChange={e => {
            let v = value(e);
            setQuery(_ => v);
          }}
          onKeyDown={e =>
            switch (React.Event.Keyboard.key(e)) {
            | "Enter" when Array.length(found) > 0 => add(found[0])
            | "Escape" => setQuery(_ => "")
            | _ => ()
            }
          }
        />
        {Array.length(found) == 0
           ? React.null
           : <ul className="found">
               {found
                |> Array.map((l: label) =>
                     <li
                       key={l.id}
                       className={l.sensitive ? "sensitive" : ""}
                       onClick={_ => add(l)}>
                       {s(l.path)}
                     </li>
                   )
                |> React.array}
             </ul>}
      </div>
      <div className="actions">
        <button className="primary" onClick={_ => save(true)}>
          {s("Save and next")}
          <kbd> {s("Enter")} </kbd>
        </button>
        <button onClick={_ => save(false)}> {s("Save")} </button>
        <button className="ghost" onClick={_ => defaults()}>
          {s("Deep defaults")}
          <kbd> {s("d")} </kbd>
        </button>
        <Help tip=Glossary.defaults />
        {savedAt == None
           ? React.null
           : <button className="ghost danger" onClick={_ => forget()}>
               {s("Forget judgement")}
             </button>}
        <span className="spacer" />
        <a className="button ghost" href="/api/adjudication.tsv">
          {s("Export TSV")}
        </a>
      </div>
    </div>;
  };
};

module Tallies = {
  [@react.component]
  let make = (~rows: array(tally)) =>
    Array.length(rows) == 0
      ? <p className="muted"> {s("Nothing yet.")} </p>
      : <ul className="barlist">
          {let most = Array.fold_left((m, t: tally) => max(m, t.n), 1, rows);
           rows
           |> Array.map((t: tally) =>
                <li key={t.id}>
                  <span className="name"> {s(short(t.path))} </span>
                  <span className="track">
                    <span
                      className="fill bad"
                      style={ReactDOM.Style.make(~width=pct1(ratio(t.n, most)), ())}
                    />
                  </span>
                  <span className="num"> {s(string_of_int(t.n))} </span>
                </li>
              )
           |> React.array}
        </ul>;
};

/* What the judge needs to read: the page's main text, in order. */
module Context = {
  [@react.component]
  let make = (~page: page) => {
    let main = page.segments |> filter((g: segment) => g.main) |> take(24);
    <Card title="What the page says" tip=Glossary.segments>
      <>
        {Array.length(page.keywords) == 0
           ? React.null
           : <div className="keywords">
               {page.keywords
                |> take(16)
                |> Array.map(k => <span key=k className="kw"> {s(k)} </span>)
                |> React.array}
             </div>}
        <div className="context">
          {main
           |> Array.map((g: segment) =>
                <p key={string_of_int(g.i)} className={g.tag}>
                  {s(clip(360, g.text))}
                </p>
              )
           |> React.array}
        </div>
      </>
    </Card>;
  };
};

[@react.component]
let make =
    (
      ~pages: array(summary),
      ~golden: option(golden),
      ~url,
      ~select,
      ~openPage,
      ~level,
      ~version,
      ~onSaved,
    ) => {
  let (queue, setQueue) = React.useState(() => "unjudged");
  let list =
    pages
    |> filter((p: summary) =>
         queue == "all" || (queue == "judged") == p.adjudicated || p.url == url
       );
  let current =
    url != ""
      ? url
      : Array.length(list) > 0 ? list[0].url : "";
  let rec index = i =>
    i >= Array.length(list) ? (-1) : list[i].url == current ? i : index(i + 1);
  let at = index(0);
  let step = d => {
    let n = Array.length(list);
    if (n > 0) {
      let j = at < 0 ? 0 : (at + d + n) mod n;
      select(list[j].url);
    };
  };
  React.useEffect2(
    () => {
      if (url == "" && current != "") {
        select(current);
      };
      None;
    },
    (url, current),
  );
  let page = ready(usePage(current, version));
  let judged = Array.length(pages |> filter((p: summary) => p.adjudicated));
  let total = Array.length(pages);
  let agreement =
    switch (golden) {
    | Some(g) => find((a: agreement) => a.preset == level, g.levels)
    | None => None
    };

  <div className="view golden">
    <aside className="side">
      <div className="side-head">
        <div className="row spread">
          <b> {s(Printf.sprintf("%d / %d judged", judged, total))} </b>
          <Help tip=Glossary.golden />
        </div>
        <Bar value={ratio(judged, total)} color="var(--accent)" />
        <Tabs
          tabs=[|("unjudged", "To judge"), ("judged", "Judged"), ("all", "All")|]
          current=queue
          onChange={q => setQueue(_ => q)}
        />
      </div>
      <ul className="items">
        {list
         |> take(400)
         |> Array.map((p: summary) =>
              <li
                key={p.url}
                className={p.url == current ? "selected" : ""}
                onClick={_ => select(p.url)}>
                <div className="title">
                  {p.adjudicated ? <span className="tickmark"> {s({js|✓ |js})} </span> : React.null}
                  {s(clip(90, p.title == "" ? p.url : p.title))}
                </div>
                <div className="meta"> {s(p.site)} </div>
              </li>
            )
         |> React.array}
      </ul>
    </aside>
    <main className="pane">
      {current == ""
         ? <Empty
             title="Nothing to judge"
             text="Every page in this queue is judged. Switch to All to review."
           />
         : <>
             <header className="detail-head">
               <div>
                 <h2>
                   {s(
                      switch (page) {
                      | Some(p) => p.title == "" ? p.url : p.title
                      | None => current
                      },
                    )}
                 </h2>
                 <div className="meta">
                   <a href=current target="_blank" rel="noreferrer">
                     {s(clip(100, current))}
                   </a>
                   {s(
                      at >= 0
                        ? Printf.sprintf("  |  %d of %d in queue", at + 1, Array.length(list))
                        : "",
                    )}
                 </div>
               </div>
               <div className="actions">
                 <button className="ghost" onClick={_ => step(-1)}>
                   {s("Previous")}
                   <kbd> {s("k")} </kbd>
                 </button>
                 <button className="ghost" onClick={_ => step(1)}>
                   {s("Next")}
                   <kbd> {s("j")} </kbd>
                 </button>
                 <button className="ghost" onClick={_ => openPage(current)}>
                   {s("Open in Pages")}
                 </button>
               </div>
             </header>
             <Judge
               key=current
               url=current
               onSaved={next => {
                 onSaved();
                 if (next) {
                   step(1);
                 };
               }}
               onNext={() => step(1)}
               onPrev={() => step(-1)}
             />
             {switch (page) {
              | Some(p) => <Context page=p />
              | None => React.null
              }}
           </>}
    </main>
    <aside className="side right">
      <Card title="Agreement per level" tip=Glossary.hf1>
        {switch (golden) {
         | Some(g) when g.judged > 0 => <Overview.Agreement golden=g level />
         | _ => <p className="muted"> {s("Judge a page to see scores.")} </p>
         }}
      </Card>
      <Card title={"Served but rejected, " ++ level} tip=Glossary.falsePositives>
        <Tallies
          rows={
            switch (agreement) {
            | Some(a) => a.false_positives
            | None => [||]
            }
          }
        />
      </Card>
      <Card title={"Gold but not served, " ++ level} tip=Glossary.missed>
        <Tallies
          rows={
            switch (agreement) {
            | Some(a) => a.missed
            | None => [||]
            }
          }
        />
      </Card>
    </aside>
  </div>;
};
