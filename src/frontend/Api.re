/* Mirrors the online server's JSON. Melange compiles records to plain JS
   objects with the same field names, so a decoded response is used as is. */

type evidence = {
  tier: string,
  zone: string,
  quote: string,
  why: string,
};

type label = {
  id: string,
  path: string,
  score: float,
  sensitive: bool,
  evidence: array(evidence),
};

type summary = {
  url: string,
  site: string,
  title: string,
  fetched_at: float,
  segments: int,
  stop: string,
  spent: float,
  sensitive: bool,
  adjudicated: bool,
  labels: array(label),
};

type level = {
  preset: string,
  ran: array(string),
  spent: float,
  stop: string,
  served_count: int,
  served: array(string),
  labels: array(label),
};

type segment = {
  i: int,
  tag: string,
  text: string,
  main: bool,
  article: int,
  top: float,
  height: float,
  labels: array(label),
};

type gold = {
  labels: array(label),
  closure: array(string),
};

type adSlot = {
  id: string,
  index: int,
  learned: bool,
};

type story = {
  article: int,
  labels: array(label),
};

type page = {
  url: string,
  site: string,
  title: string,
  fetched_at: float,
  keywords: array(string),
  levels: array(level),
  segments: array(segment),
  t4_gate: string,
  gold: Js.Nullable.t(gold),
  ad_slots: array(adSlot),
  articles: array(story),
};

type slot = {
  ad: string,
  after: int,
  y: float,
  reach: float,
  fit: float,
  p: float,
  blocked: bool,
  reasons: array(string),
  flagged: array(int),
};

type creative = {
  labels: array(label),
  keywords: array(string),
};

type placement = {
  creative,
  slots: array(slot),
};

type siteStat = {
  site: string,
  total: int,
  matched: int,
};

type hit = {
  url: string,
  title: string,
  site: string,
  fit: float,
  after: int,
  blocked: bool,
  reason: string,
};

type outreach = {
  total: int,
  matched: int,
  creative,
  histogram: array(int),
  sites: array(siteStat),
  pages: array(hit),
};

type candidate = {
  id: string,
  path: string,
  score: float,
  sensitive: bool,
  evidence: array(evidence),
  scores: Js.Dict.t(float),
};

type judgement = {
  gold: array(string),
  rejected: array(string),
  at: float,
};

type adjudication = {
  candidates: array(candidate),
  saved: Js.Nullable.t(judgement),
};

type tally = {
  id: string,
  path: string,
  n: int,
};

type agreement = {
  preset: string,
  p: Js.Nullable.t(float),
  r: Js.Nullable.t(float),
  f1: Js.Nullable.t(float),
  false_positives: array(tally),
  missed: array(tally),
};

type golden = {
  judged: int,
  pages: int,
  levels: array(agreement),
};

type event = {
  url: string,
  outcome: string,
  at: float,
};

type replica = {
  id: string,
  crawled: int,
};

type llm = {
  model: string,
  calls: int,
  errors: int,
  spent_usd: float,
};

type status = {
  queued: int,
  in_flight: int,
  ok: int,
  failed: int,
  stored: int,
  recent: array(event),
  replicas: array(replica),
  llm: Js.Nullable.t(llm),
};

type response;

exception Http(string);

external fetch: (string, Js.t({..})) => Js.Promise.t(response) = "fetch";
[@mel.send] external json: response => Js.Promise.t('a) = "json";
[@mel.get] external ok: response => bool = "ok";
[@mel.get] external httpStatus: response => int = "status";
[@mel.scope "JSON"] external stringify: 'a => string = "stringify";
external encode: string => string = "encodeURIComponent";
[@mel.send] external includes: (string, string) => bool = "includes";
[@mel.send] external lower: string => string = "toLowerCase";

/* Set by Ui.Toasts: (kind, text). */
let notify: ref((string, string) => unit) = ref((_, _) => ());

let request = (url, init) =>
  fetch(url, init)
  |> Js.Promise.then_(r =>
       ok(r)
         ? json(r)
         : Js.Promise.reject(
             Http(Printf.sprintf("%s: HTTP %d", url, httpStatus(r))),
           )
     );

let get = (url: string): Js.Promise.t('a) => request(url, {"method": "GET"});

let send = (meth, url: string, body: 'b): Js.Promise.t('a) =>
  request(
    url,
    {
      "method": meth,
      "headers": {
        "content-type": "application/json",
      },
      "body": stringify(body),
    },
  );

let post = (url, body) => send("POST", url, body);
let delete = url => request(url, {"method": "DELETE"});

/* Hand the decoded value to [k]. [what] names the request in a toast when
   it fails; polling leaves it out and shows staleness its own way. */
let load = (~what=?, ~failed=() => (), promise: Js.Promise.t('a), k: 'a => unit) =>
  promise
  |> Js.Promise.then_(v => {
       k(v);
       Js.Promise.resolve();
     })
  |> Js.Promise.catch(_ => {
       switch (what) {
       | Some(w) => notify^("error", w ++ " failed")
       | None => ()
       };
       failed();
       Js.Promise.resolve();
     })
  |> ignore;
