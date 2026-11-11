/* The Placement Lab: a hash-routed shell around five views. */

open Api;
open Ui;

let views = [|
  ("overview", "Overview"),
  ("pages", "Pages"),
  ("simulate", "Simulate"),
  ("golden", "Golden set"),
  ("crawler", "Crawler"),
|];
let formats = [|"scroll-through", "in-article", "fullscreen", "sticky", "banner"|];

type route = {
  view: string,
  url: string,
};

let drop = (c, h) =>
  String.length(h) > 0 && h.[0] == c ? String.sub(h, 1, String.length(h) - 1) : h;

let parse = hash => {
  let h = drop('/', drop('#', hash));
  switch (String.index_opt(h, '/')) {
  | Some(i) => {
      view: String.sub(h, 0, i),
      url: {
        let raw = String.sub(h, i + 1, String.length(h) - i - 1);
        try(Browser.decode(raw)) {
        | _ => raw
        };
      },
    }
  | None => {view: h == "" ? "overview" : h, url: ""}
  };
};

let href = r => "#/" ++ r.view ++ (r.url == "" ? "" : "/" ++ encode(r.url));
let go = r => Browser.setHash(Browser.location, href(r));
let pref = (key, default) => Option.value(Browser.getItem("lab." ++ key), ~default);

let every = (ms, f) => {
  f();
  let id = Js.Global.setInterval(~f, ms);
  Some(() => Js.Global.clearInterval(id));
};

module HelpDrawer = {
  [@react.component]
  let make = (~onClose) =>
    <div className="drawer-back" onClick={_ => onClose()}>
      <aside className="drawer" onClick={e => React.Event.Mouse.stopPropagation(e)}>
        <header className="row spread">
          <h2> {s("How to read the lab")} </h2>
          <button className="ghost" onClick={_ => onClose()}> {s("Close  Esc")} </button>
        </header>
        <p className="muted">
          {s("Every \"?\" in the lab shows one of these on hover. Press ? anywhere to open this list.")}
        </p>
        <dl>
          {Glossary.all
           |> Array.map(((term, text)) =>
                <React.Fragment key=term>
                  <dt> {s(term)} </dt>
                  <dd> {s(text)} </dd>
                </React.Fragment>
              )
           |> React.array}
        </dl>
      </aside>
    </div>;
};

module App = {
  [@react.component]
  let make = () => {
    let (route, setRoute) = React.useState(() => parse(Browser.hash(Browser.location)));
    let (level, setLevel) = React.useState(() => pref("level", "standard"));
    let (format, setFormat) =
      React.useState(() => {
        let f = pref("format", "scroll-through");
        Js.Array.includes(~value=f, formats) ? f : "scroll-through";
      });
    let (avoid, setAvoid) = React.useState(() => pref("avoid", "true") == "true");
    let (theme, setTheme) = React.useState(() => pref("theme", "auto"));
    let (pages, setPages) = React.useState(() => [||]);
    let (loaded, setLoaded) = React.useState(() => false);
    let (status, setStatus) = React.useState(() => None);
    let (golden, setGolden) = React.useState(() => None);
    let (version, setVersion) = React.useState(() => 0);
    let (filters, setFilters) = React.useState(() => Pages.initial);
    let (tab, setTab) = React.useState(() => "page");
    let (prompt, setPrompt) = React.useState(() => Simulate.examples[0]);
    let (submitted, setSubmitted) = React.useState(() => "");
    let (threshold, setThreshold) = React.useState(() => 0.5);
    let (helpOpen, setHelpOpen) = React.useState(() => false);

    React.useEffect0(() => {
      let sync = () => setRoute(_ => parse(Browser.hash(Browser.location)));
      Browser.addWindowListener("hashchange", sync);
      Some(() => Browser.removeWindowListener("hashchange", sync));
    });

    React.useEffect4(
      () => {
        Browser.setItem("lab.level", level);
        Browser.setItem("lab.format", format);
        Browser.setItem("lab.avoid", avoid ? "true" : "false");
        Browser.setItem("lab.theme", theme);
        Browser.setAttribute(Browser.documentElement, "data-theme", theme);
        None;
      },
      (level, format, avoid, theme),
    );

    React.useEffect2(
      () => {
        /* A slow answer for the previous level must not land after this one. */
        let live = ref(true);
        let stop =
          every(10000, () =>
            load(get("/api/pages?level=" ++ level), (ps: array(summary)) =>
              if (live^) {
                setPages(_ => ps);
                setLoaded(_ => true);
              }
            )
          );
        Some(
          () => {
            live := false;
            Option.iter(f => f(), stop);
          },
        );
      },
      (level, version),
    );

    /* Only a changed status re-renders the app. */
    let lastStatus = React.useRef("");
    React.useEffect0(() =>
      every(3000, () =>
        load(
          ~failed=
            () => {
              lastStatus.current = "";
              setStatus(_ => None);
            },
          get("/crawler/status"),
          (st: status) => {
            let j = stringify(st);
            if (j != lastStatus.current) {
              lastStatus.current = j;
              setStatus(_ => Some(st));
            };
          },
        )
      )
    );

    React.useEffect1(
      () => every(20000, () => load(get("/api/golden"), (g: golden) => setGolden(_ => Some(g)))),
      [|version|],
    );

    React.useEffect1(
      () => {
        let handler = ev =>
          if (!Browser.typing(ev)) {
            switch (Browser.key(ev)) {
            | "?" => setHelpOpen(o => !o)
            | "Escape" => setHelpOpen(_ => false)
            | _ => ()
            };
          };
        Browser.addKeyListener("keydown", handler);
        Some(() => Browser.removeKeyListener("keydown", handler));
      },
      [|helpOpen|],
    );

    let openPage = url => go({view: "pages", url});
    let onSaved = () => setVersion(v => v + 1);
    let submit = p => setSubmitted(_ => p);
    let judged = Array.length(pages |> filter((p: summary) => p.adjudicated));
    let urls =
      React.useMemo1(
        () => {
          let h = Hashtbl.create(Array.length(pages));
          Array.iter((p: summary) => Hashtbl.replace(h, p.url, ()), pages);
          h;
        },
        [|pages|],
      );
    let known = url => Hashtbl.mem(urls, url);
    let nextTheme =
      fun
      | "auto" => "light"
      | "light" => "dark"
      | _ => "auto";
    let health =
      switch (status) {
      | Some(st) =>
        <span
          className="pill good"
          onMouseEnter={Tip.enter(
            Printf.sprintf(
              "Crawler up: %d replicas, %d queued, %d in flight, %d stored.",
              Array.length(st.replicas),
              st.queued,
              st.in_flight,
              st.stored,
            ),
          )}
          onMouseLeave=Tip.leave
          onClick={_ => go({view: "crawler", url: ""})}>
          <span className="dot good" />
          {s(
             st.queued + st.in_flight > 0
               ? Printf.sprintf("crawling, %d queued", st.queued)
               : Printf.sprintf("idle, %d stored", st.stored),
           )}
        </span>
      | None =>
        <span
          className="pill bad"
          onMouseEnter={Tip.enter("No answer from /crawler/status: the online server's --crawler is not running.")}
          onMouseLeave=Tip.leave>
          <span className="dot bad" />
          {s("crawler offline")}
        </span>
      };

    <div className="app">
      <header className="topbar">
        <a className="brand" href="#/overview">
          <span className="logo" />
          <b> {s("Placement Lab")} </b>
        </a>
        <nav className="nav">
          {views
           |> Array.map(((id, label)) =>
                <a key=id href={href({view: id, url: ""})} className={route.view == id ? "on" : ""}>
                  {s(label)}
                  {id == "golden" && Array.length(pages) > 0
                     ? <span className="count">
                         {s(Printf.sprintf("%d/%d", judged, Array.length(pages)))}
                       </span>
                     : React.null}
                </a>
              )
           |> React.array}
        </nav>
        <div className="controls">
          <label>
            <span> <span className="lbl"> {s("Depth")} </span> <Help tip=Glossary.depth /> </span>
            <select value=level onChange={onText(setLevel)}>
              {Golden.levels
               |> Array.map(l => <option key=l value=l> {s(l)} </option>)
               |> React.array}
            </select>
          </label>
          <label>
            <span> <span className="lbl"> {s("Format")} </span> <Help tip=Glossary.format /> </span>
            <select value=format onChange={onText(setFormat)}>
              {formats |> Array.map(f => <option key=f value=f> {s(f)} </option>) |> React.array}
            </select>
          </label>
          <label className="check">
            <input type_="checkbox" checked=avoid onChange={_ => setAvoid(a => !a)} />
            <span> <span className="lbl keep"> {s("Avoid sensitive")} </span> <Help tip=Glossary.avoid /> </span>
          </label>
          health
          <button
            className="icon"
            onMouseEnter={Tip.enter("Theme: " ++ theme ++ ". Click for " ++ nextTheme(theme) ++ ".")}
            onMouseLeave=Tip.leave
            onClick={_ => setTheme(t => nextTheme(t))}>
            {s(
               switch (theme) {
               | "light" => "Light"
               | "dark" => "Dark"
               | _ => "Auto"
               },
             )}
          </button>
          <button
            className="icon"
            onMouseEnter={Tip.enter("Every explanation in one place. Shortcut: ?")}
            onMouseLeave=Tip.leave
            onClick={_ => setHelpOpen(o => !o)}>
            {s("Help")}
          </button>
        </div>
      </header>
      {!loaded
         ? <div className="loading"> {s("Loading the crawled pages...")} </div>
         : switch (route.view) {
           | "pages" =>
             <Pages
               pages
               filters
               setFilters
               url={route.url}
               select=openPage
               version
               level
               format
               avoid
               prompt=submitted
               onSimulate={() => submit(prompt)}
               tab
               setTab={t => setTab(_ => t)}
               onSaved
             />
           | "simulate" =>
             <Simulate
               pages
               prompt
               setPrompt={p => setPrompt(_ => p)}
               submitted
               submit
               level
               format
               avoid
               threshold
               setThreshold={t => setThreshold(_ => t)}
               openPage={url => {
                 setTab(_ => "page");
                 openPage(url);
               }}
             />
           | "golden" =>
             <Golden
               pages
               golden
               url={route.url}
               select={url => go({view: "golden", url})}
               openPage
               level
               version
               onSaved
             />
           | "crawler" => <Crawler status known openPage />
           | _ =>
             <Overview
               pages
               status
               golden
               level
               onTopic={t => {
                 setFilters(_ => Pages.withQuery(t));
                 go({view: "pages", url: ""});
               }}
               onSite={site => {
                 setFilters(_ => Pages.withSite(site));
                 go({view: "pages", url: ""});
               }}
               go={view => go({view, url: ""})}
             />
           }}
      {helpOpen ? <HelpDrawer onClose={() => setHelpOpen(_ => false)} /> : React.null}
      <Tip />
      <Toasts />
    </div>;
  };
};

switch (ReactDOM.querySelector("#root")) {
| Some(root) => ReactDOM.Client.render(ReactDOM.Client.createRoot(root), <App />)
| None => ()
};
