/* Shared pieces: formatting, the "?" tooltips, toasts, chips, bars, cards. */

open Api;

let s = React.string;
let pct = x => Printf.sprintf("%.0f%%", x *. 100.);
let pct1 = x => Printf.sprintf("%.1f%%", x *. 100.);
let num = x => Printf.sprintf("%.2f", x);
let money = x => x == 0. ? "$0" : Printf.sprintf("$%.6f", x);
let heat = p =>
  "hsl("
  ++ string_of_int(int_of_float(Float.max(0., Float.min(1., p)) *. 120.))
  ++ ", 62%, 44%)";
let clip = (n, t) => String.length(t) > n ? String.sub(t, 0, n) ++ "..." : t;
let filter = (f, a) => Array.of_list(List.filter(f, Array.to_list(a)));
let find = (f, a) => List.find_opt(f, Array.to_list(a));
let take = (n, a) => Array.length(a) > n ? Array.sub(a, 0, n) : a;
let value = e => React.Event.Form.target(e)##value;
/* onChange for a text field kept in React state. */
let onText = (setter, e) => {
  let v: string = value(e);
  setter(_ => v);
};
let ratio = (a, b) => b == 0 ? 0. : float_of_int(a) /. float_of_int(b);
let px = x => Printf.sprintf("%.0fpx", x);
let width = x => ReactDOM.Style.make(~width=pct1(Float.min(1., x)), ());

let parts = path => Array.of_list(String.split_on_char('>', path) |> List.map(String.trim));
let root = path => parts(path)[0];
/* The last two levels of a path: enough to read, short enough for a chip.
   Business and Finance > Economy > Currencies gives Economy > Currencies. */
let short = path => {
  let a = parts(path);
  let n = Array.length(a);
  n <= 2 ? String.concat(" > ", Array.to_list(a)) : a[n - 2] ++ " > " ++ a[n - 1];
};

let ago = t => {
  let d = Js.Date.now() /. 1000. -. t;
  if (d < 60.) {
    "just now";
  } else if (d < 3600.) {
    Printf.sprintf("%.0f min ago", d /. 60.);
  } else if (d < 86400.) {
    Printf.sprintf("%.0f h ago", d /. 3600.);
  } else {
    Printf.sprintf("%.0f d ago", d /. 86400.);
  };
};

let count = (key, items) => {
  let h = Hashtbl.create(64);
  Array.iter(
    x => {
      let k = key(x);
      Hashtbl.replace(h, k, 1 + Option.value(Hashtbl.find_opt(h, k), ~default=0));
    },
    items,
  );
  Hashtbl.fold((k, n, acc) => [(k, n), ...acc], h, [])
  |> List.sort(((ka, a), (kb, b)) => a == b ? compare(ka, kb) : compare(b, a))
  |> Array.of_list;
};

/* One tooltip for the whole app, fixed to the viewport, so a panel's
   scrolling never clips it. */
module Tip = {
  type t = {
    text: string,
    x: float,
    y: float,
    below: bool,
  };
  let show: ref(option(t) => unit) = ref(_ => ());
  let at = (r, text) => {
    let x =
      Float.max(
        170.,
        Float.min(
          Browser.innerWidth -. 170.,
          Browser.left(r) +. Browser.width(r) /. 2.,
        ),
      );
    let below = Browser.top(r) < 150.;
    {text, x, y: below ? Browser.bottom(r) +. 8. : Browser.top(r) -. 8., below};
  };
  let enter = (text, e) =>
    show^(
      Some(at(Browser.rect(Browser.asEl(React.Event.Mouse.currentTarget(e))), text)),
    );
  let focus = (text, e) =>
    show^(
      Some(at(Browser.rect(Browser.asEl(React.Event.Focus.currentTarget(e))), text)),
    );
  let leave = _ => show^(None);

  [@react.component]
  let make = () => {
    let (tip, setTip) = React.useState(() => None);
    React.useEffect0(() => {
      show := (t => setTip(_ => t));
      let hide = () => setTip(_ => None);
      Browser.addWindowListener("blur", hide);
      Browser.addWindowListener("hashchange", hide);
      Some(
        () => {
          Browser.removeWindowListener("blur", hide);
          Browser.removeWindowListener("hashchange", hide);
        },
      );
    });
    switch (tip) {
    | Some(t) =>
      <div
        className={"tooltip" ++ (t.below ? " below" : "")}
        role="tooltip"
        style={ReactDOM.Style.make(~left=px(t.x), ~top=px(t.y), ())}>
        {s(t.text)}
      </div>
    | None => React.null
    };
  };
};

module Help = {
  [@react.component]
  let make = (~tip: string) =>
    <span
      className="help"
      tabIndex=0
      role="note"
      ariaLabel=tip
      onMouseEnter={Tip.enter(tip)}
      onMouseLeave=Tip.leave
      onFocus={Tip.focus(tip)}
      onBlur=Tip.leave
      onClick={e => React.Event.Mouse.stopPropagation(e)}>
      {s("?")}
    </span>;
};

let help =
  fun
  | Some(t) => <Help tip=t />
  | None => React.null;

module Toasts = {
  type toast = {
    id: int,
    kind: string,
    text: string,
  };
  let next = ref(0);

  [@react.component]
  let make = () => {
    let (items, setItems) = React.useState(() => [||]);
    React.useEffect0(() => {
      notify :=
        (
          (kind, text) => {
            next := next^ + 1;
            let id = next^;
            setItems(a => {
              let n = Array.length(a);
              Array.append(n > 2 ? Array.sub(a, n - 2, 2) : a, [|{id, kind, text}|]);
            });
            Js.Global.setTimeout(
              ~f=() => setItems(a => a |> filter(t => t.id != id)),
              kind == "error" ? 6000 : 3500,
            )
            |> ignore;
          }
        );
      None;
    });
    <div className="toasts" role="status">
      {items
       |> Array.map(t =>
            <div key={string_of_int(t.id)} className={"toast " ++ t.kind}>
              {s(t.text)}
            </div>
          )
       |> React.array}
    </div>;
  };
};

let toast = text => notify^("ok", text);

module Bar = {
  [@react.component]
  let make = (~value: float, ~color=?) =>
    <span className="bar">
      <span
        className="fill"
        style={ReactDOM.Style.make(
          ~width=pct1(Float.max(0., Float.min(1., value))),
          ~background=Option.value(color, ~default=heat(value)),
          (),
        )}
      />
    </span>;
};

module Badge = {
  [@react.component]
  let make = (~text, ~tip=?, ~tone="") =>
    switch (tip) {
    | Some(t) =>
      <span
        className={"badge " ++ tone}
        tabIndex=0
        onMouseEnter={Tip.enter(t)}
        onMouseLeave=Tip.leave
        onFocus={Tip.focus(t)}
        onBlur=Tip.leave>
        {s(text)}
      </span>
    | None => <span className={"badge " ++ tone}> {s(text)} </span>
    };
};

let tierBadge = t =>
  <Badge
    key=t
    text={String.uppercase_ascii(Glossary.tierName(t))}
    tip={Glossary.tier(t)}
    tone={"tier " ++ Glossary.tierName(t)}
  />;

let stopTone =
  fun
  | "settled" => "good"
  | "out of budget" => "warn"
  | _ => "";

let stopBadge = stop =>
  <Badge text=stop tip={Glossary.stop(stop)} tone={stopTone(stop)} />;

module Chip = {
  [@react.component]
  let make = (~label: label, ~full=false) =>
    <span
      className={
        "chip" ++ (label.sensitive ? " sensitive" : "") ++ (label.score >= 0.5 ? "" : " weak")
      }
      onMouseEnter={Tip.enter(label.path ++ "  (" ++ num(label.score) ++ ")")}
      onMouseLeave=Tip.leave>
      <i style={ReactDOM.Style.make(~background=heat(label.score), ())} />
      {s(full ? label.path : short(label.path))}
      <b> {s(num(label.score))} </b>
    </span>;
};

let chips = (labels: array(label)) =>
  <span className="chips">
    {labels |> Array.map((l: label) => <Chip key={l.id} label=l />) |> React.array}
  </span>;

module Card = {
  [@react.component]
  let make = (~title=?, ~tip=?, ~extra=React.null, ~className="", ~children) =>
    <section className={"card " ++ className}>
      {switch (title) {
       | Some(t) =>
         <header className="card-head">
           <h3> {s(t)} {help(tip)} </h3>
           extra
         </header>
       | None => React.null
       }}
      <div className="card-body"> children </div>
    </section>;
};

module Stat = {
  [@react.component]
  let make = (~label, ~value, ~tip=?, ~sub=?, ~tone="", ~progress=?) =>
    <div className={"stat " ++ tone}>
      <div className="stat-label"> {s(label)} {help(tip)} </div>
      <div className="stat-value"> {s(value)} </div>
      {switch (progress) {
       | Some(x) => <Bar value=x color="var(--accent)" />
       | None => React.null
       }}
      {switch (sub) {
       | Some(t) => <div className="stat-sub"> {s(t)} </div>
       | None => React.null
       }}
    </div>;
};

module Tabs = {
  [@react.component]
  let make = (~tabs: array((string, string)), ~current, ~onChange) =>
    <nav className="tabs" role="tablist">
      {tabs
       |> Array.map(((id, label)) =>
            <button
              key=id
              role="tab"
              className={id == current ? "tab on" : "tab"}
              onClick={_ => onChange(id)}>
              {s(label)}
            </button>
          )
       |> React.array}
    </nav>;
};

module Empty = {
  [@react.component]
  let make = (~title, ~text="", ~children=React.null) =>
    <div className="empty">
      <h4> {s(title)} </h4>
      {text == "" ? React.null : <p> {s(text)} </p>}
      children
    </div>;
};

type remote('a) =
  | Loading
  | Missing
  | Ready('a);

/* Fetch one page's full profile; [version] forces a reload after a save. */
let usePage = (url, version) => {
  let (page, setPage) = React.useState(() => (url, Loading));
  React.useEffect2(
    () => {
      let live = ref(true);
      if (url != "") {
        load(
          ~failed=() => if (live^) {setPage(_ => (url, Missing))},
          get("/api/page?url=" ++ encode(url)),
          (p: page) => if (live^) {setPage(_ => (url, Ready(p)))},
        );
      };
      Some(() => live := false);
    },
    (url, version),
  );
  switch (page) {
  | (u, r) when u == url => r
  | _ => Loading
  };
};

let ready =
  fun
  | Ready(p) => Some(p)
  | Loading
  | Missing => None;

let usePlacement = (~prompt, ~url, ~level, ~format, ~avoid) => {
  let (placement, setPlacement) = React.useState(() => None);
  React.useEffect5(
    () => {
      let live = ref(true);
      setPlacement(_ => None);
      if (prompt != "" && url != "") {
        load(
          ~what="Placement",
          post(
            "/api/placement",
            {
              "prompt": prompt,
              "format": format,
              "level": level,
              "avoid_sensitive": avoid,
              "url": url,
            },
          ),
          (p: placement) =>
          if (live^) {
            setPlacement(_ => Some(p));
          }
        );
      };
      Some(() => live := false);
    },
    (prompt, url, level, format, avoid),
  );
  placement;
};

let crawlPage = url =>
  load(
    ~what="Crawl request",
    post("/crawler/crawl", {"url": url, "force": true}),
    _ => toast("Queued for a re-crawl: " ++ clip(60, url)),
  );

let copy = text =>
  Browser.writeText(text)
  |> Js.Promise.then_(() => {
       toast("Copied");
       Js.Promise.resolve();
     })
  |> ignore;

/* A score as a translucent background, so a column of them reads as a heat map. */
let tint = x =>
  ReactDOM.Style.make(
    ~background=
      Printf.sprintf(
        "hsla(%d, 62%%, 50%%, %.2f)",
        int_of_float(Float.max(0., Float.min(1., x)) *. 120.),
        0.06 +. Float.max(0., Float.min(1., x)) *. 0.26,
      ),
    (),
  );

module SlotBar = {
  [@react.component]
  let make = (~slot: slot, ~active=false, ~onPick) =>
    <div
      className={
        "slot" ++ (slot.blocked ? " blocked" : "") ++ (active ? " active" : "")
      }
      style={
        slot.blocked
          ? ReactDOM.Style.make()
          : ReactDOM.Style.make(~borderLeftColor=heat(slot.p), ())
      }
      onClick={_ => onPick(slot.after)}>
      {slot.blocked
         ? <>
             <Badge text="blocked" tip=Glossary.blocked tone="bad" />
             <span className="reasons">
               {s(String.concat("; ", Array.to_list(slot.reasons)))}
             </span>
           </>
         : <>
             <span
               className="slot-p"
               style={ReactDOM.Style.make(~color=heat(slot.p), ())}>
               {s("P " ++ pct(slot.p))}
             </span>
             <Bar value={slot.p} />
             <span className="muted">
               {s(Printf.sprintf("fit %s, reach %s", pct(slot.fit), pct(slot.reach)))}
             </span>
             <span className="reasons">
               {s(clip(120, String.concat("; ", Array.to_list(slot.reasons))))}
             </span>
           </>}
    </div>;
};
