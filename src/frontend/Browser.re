/* The few browser APIs the lab needs, typed by hand. */

type el;
type location;
type rect;
type keyEvent;
type url;

external asEl: Js.t({..}) => el = "%identity";

[@mel.scope "window"] external location: location = "location";
[@mel.get] external hash: location => string = "hash";
[@mel.set] external setHash: (location, string) => unit = "hash";
[@mel.scope "window"] external innerWidth: float = "innerWidth";
[@mel.scope "window"]
external addWindowListener: (string, unit => unit) => unit =
  "addEventListener";
[@mel.scope "window"]
external removeWindowListener: (string, unit => unit) => unit =
  "removeEventListener";

[@mel.get] external key: keyEvent => string = "key";
[@mel.get] external metaKey: keyEvent => bool = "metaKey";
[@mel.get] external ctrlKey: keyEvent => bool = "ctrlKey";
[@mel.get] external altKey: keyEvent => bool = "altKey";
[@mel.get] external target: keyEvent => el = "target";
[@mel.get] external tagName: el => string = "tagName";
[@mel.send] external preventDefault: keyEvent => unit = "preventDefault";
[@mel.scope "document"]
external addKeyListener: (string, keyEvent => unit) => unit =
  "addEventListener";
[@mel.scope "document"]
external removeKeyListener: (string, keyEvent => unit) => unit =
  "removeEventListener";

/* A key typed into a form field is text, not a shortcut. */
let typing = ev =>
  switch (tagName(target(ev))) {
  | "INPUT"
  | "TEXTAREA"
  | "SELECT" => true
  | _ => false
  };

[@mel.send] external rect: el => rect = "getBoundingClientRect";
[@mel.get] external left: rect => float = "left";
[@mel.get] external top: rect => float = "top";
[@mel.get] external width: rect => float = "width";
[@mel.get] external bottom: rect => float = "bottom";

[@mel.scope "document"] [@mel.return nullable]
external byId: string => option(el) = "getElementById";
[@mel.send]
external scrollIntoView: (el, {. "behavior": string, "block": string}) => unit =
  "scrollIntoView";
[@mel.send] external focus: el => unit = "focus";

let scrollTo = id =>
  switch (byId(id)) {
  | Some(e) => scrollIntoView(e, {"behavior": "smooth", "block": "center"})
  | None => ()
  };

[@mel.scope "localStorage"] [@mel.return nullable]
external getItem: string => option(string) = "getItem";
[@mel.scope "localStorage"]
external setItem: (string, string) => unit = "setItem";

[@mel.scope "document"] external documentElement: el = "documentElement";
[@mel.send] external setAttribute: (el, string, string) => unit = "setAttribute";

[@mel.new] external makeUrl: (string, string) => url = "URL";
[@mel.get] external href: url => string = "href";
external decode: string => string = "decodeURIComponent";

/* An image src from a page, made absolute against that page. */
let resolve = (~base, src) =>
  try(href(makeUrl(src, base))) {
  | _ => src
  };

[@mel.scope ("navigator", "clipboard")]
external writeText: string => Js.Promise.t(unit) = "writeText";
