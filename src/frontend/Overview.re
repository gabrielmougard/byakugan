/* The whole crawl at a glance, at the current depth level. */

open Api;
open Ui;

let nullable = x => Js.Nullable.toOption(x);
let score = x =>
  switch (nullable(x)) {
  | Some(v) => num(v)
  | None => "-"
  };

module Agreement = {
  [@react.component]
  let make = (~golden: golden, ~level) =>
    <table className="grid agreement">
      <thead>
        <tr>
          <th> {s("level")} </th>
          <th> {s("hP")} <Help tip=Glossary.hp /> </th>
          <th> {s("hR")} <Help tip=Glossary.hr /> </th>
          <th> {s("hF1")} <Help tip=Glossary.hf1 /> </th>
        </tr>
      </thead>
      <tbody>
        {golden.levels
         |> Array.map((a: agreement) => {
              let cell = x =>
                <td className="num">
                  <span className="cellbar">
                    <Bar value={Option.value(nullable(x), ~default=0.)} />
                    {s(score(x))}
                  </span>
                </td>;
              <tr key={a.preset} className={a.preset == level ? "current" : ""}>
                <td>
                  {s(a.preset)}
                  <Help tip={Glossary.level(a.preset)} />
                </td>
                {cell(a.p)}
                {cell(a.r)}
                {cell(a.f1)}
              </tr>;
            })
         |> React.array}
      </tbody>
    </table>;
};

module BarList = {
  [@react.component]
  let make = (~rows: array((string, int)), ~total, ~onPick) => {
    let most = Array.fold_left((m, (_, n)) => max(m, n), 1, rows);
    <ul className="barlist">
      {rows
       |> Array.map(((name, n)) =>
            <li key=name onClick={_ => onPick(name)}>
              <span className="name"> {s(name)} </span>
              <span className="track">
                <span
                  className="fill"
                  style={ReactDOM.Style.make(
                    ~width=pct1(ratio(n, most)),
                    (),
                  )}
                />
              </span>
              <span className="num">
                {s(Printf.sprintf("%d  %s", n, pct(ratio(n, total))))}
              </span>
            </li>
          )
       |> React.array}
    </ul>;
  };
};

[@react.component]
let make =
    (
      ~pages: array(summary),
      ~status: option(status),
      ~golden: option(golden),
      ~level,
      ~onTopic,
      ~onSite,
      ~go,
    ) => {
  let n = Array.length(pages);
  let judged = Array.length(pages |> filter((p: summary) => p.adjudicated));
  let sensitive = Array.length(pages |> filter((p: summary) => p.sensitive));
  let stops = count((p: summary) => p.stop, pages);
  let stopShare = name =>
    ratio(
      Array.fold_left((acc, (k, c)) => k == name ? acc + c : acc, 0, stops),
      n,
    );
  let spent = Array.fold_left((acc, p: summary) => acc +. p.spent, 0., pages);
  let main = (p: summary) =>
    Array.length(p.labels) > 0 ? Some(p.labels[0].path) : None;
  let labelled = pages |> filter(p => main(p) != None);
  let topics =
    count(p => Option.fold(~none="", ~some=root, main(p)), labelled) |> take(14);
  let categories =
    count(p => Option.value(main(p), ~default=""), labelled) |> take(14);
  let sites = count((p: summary) => p.site, pages);
  /* site -> (judged, sensitive, main topics), in one pass. */
  let perSite =
    React.useMemo1(
      () => {
        let h = Hashtbl.create(64);
        Array.iter(
          (p: summary) => {
            let (j, sn, topics) = Option.value(Hashtbl.find_opt(h, p.site), ~default=(0, 0, []));
            Hashtbl.replace(
              h,
              p.site,
              (
                j + (p.adjudicated ? 1 : 0),
                sn + (p.sensitive ? 1 : 0),
                switch (main(p)) {
                | Some(m) => [root(m), ...topics]
                | None => topics
                },
              ),
            );
          },
          pages,
        );
        h;
      },
      [|pages|],
    );

  if (n == 0) {
    <div className="view scroll">
      <Empty
        title="No crawled page yet"
        text="Queue a page or a site in the crawler, or point the online server at a Valkey that holds profiles.">
        <button className="primary" onClick={_ => go("crawler")}>
          {s("Open the crawler")}
        </button>
      </Empty>
    </div>;
  } else {
    <div className="view scroll">
      <div className="stats">
        <Stat
          label="Crawled pages"
          value={string_of_int(n)}
          sub={Printf.sprintf("%d sites", Array.length(sites))}
          tip=Glossary.stored
        />
        <Stat
          label="Golden set"
          value={Printf.sprintf("%d / %d", judged, n)}
          progress={ratio(judged, n)}
          tip=Glossary.golden
        />
        <Stat
          label={"Settled at " ++ level}
          value={pct(stopShare("settled"))}
          tip=Glossary.settledShare
          tone="good"
        />
        <Stat
          label={"Sensitive at " ++ level}
          value={pct(ratio(sensitive, n))}
          sub={Printf.sprintf("%d pages", sensitive)}
          tip=Glossary.sensitive
          tone="bad"
        />
        <Stat
          label="Spend per page"
          value={money(spent /. float_of_int(n))}
          sub={level ++ ", averaged"}
          tip=Glossary.spent
        />
        {switch (status) {
         | Some(st) =>
           <Stat
             label="Crawler"
             value={Printf.sprintf("%d queued", st.queued)}
             sub={Printf.sprintf(
               "%d in flight, %d replicas",
               st.in_flight,
               Array.length(st.replicas),
             )}
             tip=Glossary.queued
           />
         | None =>
           <Stat label="Crawler" value="offline" tone="bad" sub="no answer from /crawler/status" />
         }}
      </div>
      <div className="cols">
        <Card title={"Why levels stop, at " ++ level} tip={Glossary.level(level)}>
          <>
            <div className="stacked">
              {stops
               |> Array.map(((name, c)) =>
                    <span
                      key=name
                      className={"part " ++ stopTone(name)}
                      style={width(ratio(c, n))}
                      onMouseEnter={Tip.enter(
                        Printf.sprintf("%s: %d pages. %s", name, c, Glossary.stop(name)),
                      )}
                      onMouseLeave=Tip.leave
                    />
                  )
               |> React.array}
            </div>
            <ul className="legend">
              {stops
               |> Array.map(((name, c)) =>
                    <li key=name>
                      {stopBadge(name)}
                      {s(Printf.sprintf(" %d (%s)", c, pct(ratio(c, n))))}
                    </li>
                  )
               |> React.array}
            </ul>
          </>
        </Card>
        <Card
          title="Agreement with the golden set"
          tip=Glossary.golden
          extra={
            <button className="ghost" onClick={_ => go("golden")}>
              {s("Open")}
            </button>
          }>
          {switch (golden) {
           | Some(g) when g.judged > 0 => <Agreement golden=g level />
           | _ => <p className="muted"> {s("No judged page yet.")} </p>
           }}
        </Card>
      </div>
      <div className="cols">
        <Card title={"Main topics at " ++ level} tip=Glossary.topCategories>
          <BarList rows=topics total={Array.length(labelled)} onPick=onTopic />
        </Card>
        <Card title="Main categories" tip=Glossary.topCategories>
          <BarList rows=categories total={Array.length(labelled)} onPick=onTopic />
        </Card>
      </div>
      <Card title="Sites">
        <table className="grid">
          <thead>
            <tr>
              <th> {s("site")} </th>
              <th className="num"> {s("pages")} </th>
              <th className="num"> {s("judged")} </th>
              <th className="num">
                {s("sensitive")}
                <Help tip=Glossary.sensitive />
              </th>
              <th> {s("main topic")} </th>
            </tr>
          </thead>
          <tbody>
            {sites
             |> take(40)
             |> Array.map(((site, c)) => {
                  let (j, sn, topics) = Option.value(Hashtbl.find_opt(perSite, site), ~default=(0, 0, []));
                  let topic =
                    switch (count(t => t, Array.of_list(topics))) {
                    | [||] => "-"
                    | a => fst(a[0])
                    };
                  <tr key=site className="link" onClick={_ => onSite(site)}>
                    <td> {s(site)} </td>
                    <td className="num"> {s(string_of_int(c))} </td>
                    <td className="num"> {s(string_of_int(j))} </td>
                    <td className="num"> {s(pct(ratio(sn, c)))} </td>
                    <td> {s(topic)} </td>
                  </tr>;
                })
             |> React.array}
          </tbody>
        </table>
      </Card>
    </div>;
  };
};
