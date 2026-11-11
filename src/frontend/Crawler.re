/* The crawl daemon, through the online server's /crawler proxy. */

open Api;
open Ui;

let tone = outcome =>
  String.length(outcome) >= 2 && String.sub(outcome, 0, 2) == "ok"
    ? "good" : includes(outcome, "failed") ? "bad" : "";

[@react.component]
let make = (~status: option(status), ~known: string => bool, ~openPage) => {
  let (url, setUrl) = React.useState(() => "");
  let (site, setSite) = React.useState(() => "");
  let (most, setMost) = React.useState(() => "20");
  let (bulk, setBulk) = React.useState(() => "");
  let (show, setShow) = React.useState(() => "all");
  let (query, setQuery) = React.useState(() => "");

  let crawlSite = () =>
    load(
      ~what="Site discovery",
      post(
        "/crawler/crawl",
        {"site": site, "max_pages": Option.value(int_of_string_opt(most), ~default=20)},
      ),
      _ => toast("Discovering " ++ site ++ ": see the events below"),
    );
  let queueBulk = () => {
    let urls =
      String.split_on_char('\n', bulk)
      |> List.map(String.trim)
      |> List.filter(u => u != "")
      |> Array.of_list;
    load(
      ~what="Queueing",
      post("/crawler/crawl", {"urls": urls}),
      (r: {. "queued": array(string)}) => {
        toast(
          Printf.sprintf(
            "Queued %d of %d (the rest were seen before)",
            Array.length(r##queued),
            Array.length(urls),
          ),
        );
        setBulk(_ => "");
      },
    );
  };

  <div className="view scroll">
    {switch (status) {
     | None =>
       <Empty
         title="Crawler unreachable"
         text="The online server proxies /crawler/* to the crawl daemon (--crawler). Start it, or check that flag."
       />
     | Some(st) =>
       <>
         <div className="stats">
           <Stat label="Queued" value={string_of_int(st.queued)} tip=Glossary.queued />
           <Stat label="In flight" value={string_of_int(st.in_flight)} tip=Glossary.inFlight />
           <Stat label="Fetched" value={string_of_int(st.ok)} tip=Glossary.ok tone="good" />
           <Stat
             label="Failed"
             value={string_of_int(st.failed)}
             sub={pct(ratio(st.failed, st.ok + st.failed)) ++ " of attempts"}
             tip=Glossary.failed
             tone="bad"
           />
           <Stat label="Stored" value={string_of_int(st.stored)} tip=Glossary.stored />
           {switch (Js.Nullable.toOption(st.llm)) {
            | Some(l) =>
              <Stat
                label="T4 spend"
                value={Printf.sprintf("$%.4f", l.spent_usd)}
                sub={Printf.sprintf("%d calls, %d errors, %s", l.calls, l.errors, l.model)}
                tip=Glossary.llm
              />
            | None => <Stat label="T4" value="off" sub="crawler runs without --llm" tip=Glossary.llm />
            }}
         </div>
         <div className="cols">
           <Card title="Crawl" tip=Glossary.crawlPage>
             <>
               <div className="row">
                 <input
                   placeholder="https://publisher.example/article"
                   value=url
                   onChange={onText(setUrl)}
                 />
                 <button className="primary" disabled={url == ""} onClick={_ => crawlPage(url)}>
                   {s("Crawl page")}
                 </button>
               </div>
               <div className="row">
                 <input
                   placeholder="https://publisher.example (site root)"
                   value=site
                   onChange={onText(setSite)}
                 />
                 <input className="small" value=most onChange={onText(setMost)} />
                 <button disabled={site == ""} onClick={_ => crawlSite()}>
                   {s("Crawl site")}
                 </button>
                 <Help tip=Glossary.crawlSite />
               </div>
               <textarea
                 rows=4
                 placeholder="Or paste URLs, one per line"
                 value=bulk
                 onChange={onText(setBulk)}
               />
               <div className="row">
                 <button disabled={bulk == ""} onClick={_ => queueBulk()}> {s("Queue all")} </button>
                 <Help tip=Glossary.bulk />
               </div>
             </>
           </Card>
           <Card title="Replicas" tip=Glossary.replicas>
             {Array.length(st.replicas) == 0
                ? <p className="muted"> {s("No heartbeat in the last 30 s.")} </p>
                : <table className="grid">
                    <tbody>
                      {st.replicas
                       |> Array.map((r: replica) =>
                            <tr key={r.id}>
                              <td> <span className="dot good" /> {s(r.id)} </td>
                              <td className="num"> {s(Printf.sprintf("%d pages", r.crawled))} </td>
                            </tr>
                          )
                       |> React.array}
                    </tbody>
                  </table>}
           </Card>
         </div>
         <Card
           title="Recent events"
           extra={
             <span className="row">
               <input
                 className="search"
                 placeholder="filter"
                 value=query
                 onChange={onText(setQuery)}
               />
               <Tabs
                 tabs=[|("all", "All"), ("ok", "OK"), ("failed", "Failed"), ("other", "Other")|]
                 current=show
                 onChange={v => setShow(_ => v)}
               />
             </span>
           }>
           <table className="grid events">
             <tbody>
               {st.recent
                |> filter((ev: event) => {
                     let t = tone(ev.outcome);
                     (
                       show == "all"
                       || show == "ok"
                       && t == "good"
                       || show == "failed"
                       && t == "bad"
                       || show == "other"
                       && t == ""
                     )
                     && (query == "" || includes(lower(ev.url ++ " " ++ ev.outcome), lower(query)));
                   })
                |> Array.mapi((i, ev: event) =>
                     <tr key={string_of_int(i)}>
                       <td className="when"> {s(ago(ev.at))} </td>
                       <td className="outcome">
                         <span
                           className={"dot " ++ tone(ev.outcome)}
                           onMouseEnter={Tip.enter(ev.outcome)}
                           onMouseLeave=Tip.leave
                         />
                         {s(clip(120, ev.outcome))}
                       </td>
                       <td className="url">
                         {known(ev.url)
                            ? <button className="link" onClick={_ => openPage(ev.url)}>
                                {s(clip(90, ev.url))}
                              </button>
                            : <a href={ev.url} target="_blank" rel="noreferrer"> {s(clip(90, ev.url))} </a>}
                       </td>
                     </tr>
                   )
                |> React.array}
             </tbody>
           </table>
         </Card>
       </>
     }}
  </div>;
};
