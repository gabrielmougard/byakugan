/* A creative described in words, scored against every crawled page. */

open Api;
open Ui;

let examples = [|
  "luxury Swiss watch for men who love sailing",
  "family SUV with seven seats and a hybrid engine",
  "organic skincare for sensitive skin",
  "cheap flights to sunny beaches this winter",
  "cast iron casserole dish for slow cooking family roasts",
  "football boots for young players",
  "retirement savings plan with low fees",
|];

module Histogram = {
  [@react.component]
  let make = (~bins: array(int), ~threshold) => {
    let most = Array.fold_left(max, 1, bins);
    <div className="histogram">
      {bins
       |> Array.mapi((i, n) => {
            let lo = float_of_int(i) /. 10.;
            <div
              key={string_of_int(i)}
              className={"hbar" ++ (float_of_int(i + 1) /. 10. > threshold ? " in" : "")}
              onMouseEnter={Tip.enter(
                Printf.sprintf("fit %d-%d%%: %d pages", i * 10, i * 10 + 10, n),
              )}
              onMouseLeave=Tip.leave>
              <span
                style={ReactDOM.Style.make(
                  ~height=pct1(Float.max(0.02, ratio(n, most))),
                  ~background=heat(lo +. 0.05),
                  (),
                )}
              />
              <em> {s(string_of_int(i * 10))} </em>
            </div>;
          })
       |> React.array}
    </div>;
  };
};

[@react.component]
let make =
    (
      ~pages: array(summary),
      ~prompt,
      ~setPrompt,
      ~submitted,
      ~submit,
      ~level,
      ~format,
      ~avoid,
      ~threshold,
      ~setThreshold,
      ~openPage,
    ) => {
  let (outreach, setOutreach) = React.useState(() => None);
  let (busy, setBusy) = React.useState(() => false);
  let (preview, setPreview) = React.useState(() => "");
  /* Debounced: the threshold slider fires on every step while dragged. */
  React.useEffect6(
    () =>
      if (submitted == "") {
        None;
      } else {
        let live = ref(true);
        let t =
          Js.Global.setTimeout(
            ~f=
              () => {
                setBusy(_ => true);
                load(
                  ~what="Outreach",
                  ~failed=() => if (live^) {setBusy(_ => false)},
          post(
            "/api/outreach",
            {
              "prompt": submitted,
              "format": format,
              "level": level,
              "avoid_sensitive": avoid,
              "threshold": threshold,
            },
          ),
                  (o: outreach) =>
                    if (live^) {
                      setOutreach(_ => Some(o));
                      setBusy(_ => false);
                    },
                );
              },
            250,
          );
        Some(
          () => {
            live := false;
            Js.Global.clearTimeout(t);
          },
        );
      },
    (submitted, level, format, avoid, threshold, Array.length(pages)),
  );
  let placement = usePlacement(~prompt=submitted, ~url=preview, ~level, ~format, ~avoid);
  let run = p => {
    setPrompt(p);
    submit(p);
  };

  <div className="view scroll">
    <div className="cols wide-left">
      <Card title="Creative, described in words" tip=Glossary.creative>
        <>
          <textarea
            rows=3
            value=prompt
            onChange={e => setPrompt(value(e))}
            onKeyDown={e =>
              if (React.Event.Keyboard.key(e) == "Enter"
                  && (React.Event.Keyboard.metaKey(e) || React.Event.Keyboard.ctrlKey(e))) {
                submit(prompt);
              }
            }
          />
          <div className="examples">
            {examples
             |> Array.map(x =>
                  <button key=x className="pill-button" onClick={_ => run(x)}> {s(x)} </button>
                )
             |> React.array}
          </div>
          <div className="row">
            <button className="primary" onClick={_ => submit(prompt)}>
              {s(busy ? "Scoring..." : "Simulate")}
              <kbd> {s("Cmd+Enter")} </kbd>
            </button>
            <span className="muted">
              {s(
                 Printf.sprintf(
                   "%s at %s%s, over %d pages",
                   format,
                   level,
                   avoid ? ", avoiding Sensitive Topics" : "",
                   Array.length(pages),
                 ),
               )}
            </span>
          </div>
        </>
      </Card>
      <Card title="Creative profile" tip=Glossary.creative>
        {switch (outreach) {
         | Some(o) =>
           <>
             {chips(o.creative.labels)}
             <div className="keywords">
               {o.creative.keywords
                |> Array.map(k => <span key=k className="kw"> {s(k)} </span>)
                |> React.array}
             </div>
           </>
         | None =>
           <p className="muted">
             {s("Simulate to see the categories and keywords the prompt becomes.")}
           </p>
         }}
      </Card>
    </div>
    {switch (outreach) {
     | None =>
       <Empty
         title="No simulation yet"
         text="Describe a creative and press Simulate, or pick an example. Outreach scores the best slot of every crawled page."
       />
     | Some(o) =>
       <>
         <div className="cols">
           <Card title="Outreach" tip=Glossary.outreach>
             <>
               <div className="big">
                 {s(Printf.sprintf("%d / %d", o.matched, o.total))}
                 <span className="muted">
                   {s(Printf.sprintf(" pages (%s) with a slot at fit %s or more", pct(ratio(o.matched, o.total)), pct(threshold)))}
                 </span>
               </div>
               <label className="slider">
                 <span> {s("Threshold " ++ pct(threshold))} <Help tip=Glossary.threshold /> </span>
                 <input
                   type_="range"
                   min="0"
                   max="1"
                   step=0.05
                   value={Js.Float.toString(threshold)}
                   onChange={e => setThreshold(float_of_string(value(e)))}
                 />
               </label>
               <div className="row">
                 <span className="muted"> {s("Best fit per page")} </span>
                 <Help tip=Glossary.histogram />
               </div>
               <Histogram bins={o.histogram} threshold />
             </>
           </Card>
           <Card title="By site">
             <table className="grid">
               <tbody>
                 {let sites = Array.copy(o.sites);
                  Array.stable_sort(
                    (a: siteStat, b: siteStat) =>
                      a.matched == b.matched ? compare(b.total, a.total) : compare(b.matched, a.matched),
                    sites,
                  );
                  sites
                  |> take(12)
                  |> Array.map((st: siteStat) =>
                       <tr key={st.site}>
                         <td> {s(st.site)} </td>
                         <td className="wide"> <Bar value={ratio(st.matched, st.total)} color="var(--accent)" /> </td>
                         <td className="num"> {s(Printf.sprintf("%d / %d", st.matched, st.total))} </td>
                       </tr>
                     )
                  |> React.array}
               </tbody>
             </table>
           </Card>
         </div>
         <div className="cols">
           <Card title="Best pages" tip=Glossary.fit>
             <ol className="hits">
               {o.pages
                |> Array.map((h: hit) =>
                     <li
                       key={h.url}
                       className={h.url == preview ? "selected" : ""}
                       onClick={_ => setPreview(_ => h.url)}>
                       <span className="hit-fit" style={ReactDOM.Style.make(~color=heat(h.fit), ())}>
                         {s(pct(h.fit))}
                       </span>
                       <div>
                         <div className="title"> {s(clip(90, h.title == "" ? h.url : h.title))} </div>
                         <div className="meta">
                           {s(h.site ++ "  |  ")}
                           {h.blocked ? <Badge text="blocked" tip=Glossary.blocked tone="bad" /> : React.null}
                           {s(" " ++ clip(110, h.reason))}
                         </div>
                       </div>
                     </li>
                   )
                |> React.array}
             </ol>
           </Card>
           <Card
             title="Slots on the selected page"
             tip=Glossary.p
             extra={
               preview == ""
                 ? React.null
                 : <button className="ghost" onClick={_ => openPage(preview)}>
                     {s("Open in Pages")}
                   </button>
             }>
             {switch (preview, placement) {
              | ("", _) => <p className="muted"> {s("Pick a page in the list.")} </p>
              | (_, None) => <p className="muted"> {s("Scoring slots...")} </p>
              | (_, Some(p)) =>
                let slots = Array.copy(p.slots);
                Array.stable_sort((a: slot, b: slot) => compare(b.p, a.p), slots);
                <div className="slots">
                  {slots
                   |> take(20)
                   |> Array.map((sl: slot) =>
                        <SlotBar key={string_of_int(sl.after)} slot=sl onPick={_ => openPage(preview)} />
                      )
                   |> React.array}
                </div>;
              }}
           </Card>
         </div>
       </>
     }}
  </div>;
};
