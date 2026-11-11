(* Online placement simulator. Reads crawled profiles from Valkey (every 3 s),
   turns a text prompt into a creative profile, then scores every candidate
   slot of one page, or the best slot of every crawled page (outreach) on the
   Domainslib pool. Serves the ReasonML front end and proxies /crawler/* to
   the crawl daemon.

   GET  /api/pages?level=          crawled pages with their headline labels
   GET  /api/page?url=&level=      one page: labels per level with evidence, segments, gold
   POST /api/placement             {prompt, format, level, avoid_sensitive, url}
   POST /api/outreach              {prompt, format, level, avoid_sensitive, threshold}
   GET  /api/adjudication?url=     one page's candidate labels and its saved judgement
   POST /api/adjudication          {url, gold, rejected}: the judge's labels for a page
   DELETE /api/adjudication?url=   forget a page's judgement
   GET  /api/adjudication.tsv      every judgement: url, gold ids, rejected ids, time
   GET  /api/golden                each level's agreement with the judgements
   GET  /api/taxonomy?q=           categories whose path contains q
   GET  /replay?url=               the archived page itself, scripts off, for the lab's frame

     watch, every 3 s   ctx:profiles ─> keys new or re-crawled ─> MGET, parsed on
                        the pool ─> st.pages, in memory, newest first
     /api/placement     the page from st.pages, else its section's or site's
                        serving profile from Valkey ─> the geometry the lab's
                        frame measured, if sent ─> Engine.slots on the pool
     /api/outreach      Engine.best_slot on every page, in parallel on the pool
     /replay?url=       ctx:warc names the replica ─> GET /record?url= on it
                        (--replicas, {replica} filled in) ─> Replay.prepare
     /crawler/*         proxied to --crawler, /crawler stripped *)

open Contextual
open Serve
open Lwt.Syntax

type t = {
  engine : Engine.t;
  pool : Web.pool;
  kv : Valkey.t;
  web : string;
  crawler : string;
  replicas : string; (* crawler replica URL, "{replica}" replaced; "" = [crawler] *)
  cache : (string, float * Profile.t) Hashtbl.t; (* key -> fetched_at, profile *)
  mutable pages : Profile.t array;
}

(* Fetch only what is new or re-crawled since the last pass, parse on the pool. *)
let reload st =
  let* index = Lab.profile_index st.kv in
  let changed =
    List.filter_map
      (fun (key, at) -> match Hashtbl.find_opt st.cache key with Some (a, _) when a = at -> None | _ -> Some key)
      index
  in
  if changed = [] && List.length index = Hashtbl.length st.cache then Lwt.return_unit
  else
    let* bodies = Lwt_list.map_s (Lab.profiles st.kv) (Lab.chunks 100 changed) in
    let bodies = Array.of_list (List.filter_map Fun.id (List.concat bodies)) in
    let+ loaded =
      Web.detach st.pool
        (fun bs ->
          (Web.parallel st.pool).Engine.map
            (fun b -> try Some (Profile.of_json (Yojson.Safe.from_string b)) with _ -> None)
            bs)
        bodies
    in
    Array.iter (Option.iter (fun (p : Profile.t) -> Hashtbl.replace st.cache p.key (p.fetched_at, p))) loaded;
    let live = Hashtbl.create (List.length index) in
    List.iter (fun (key, _) -> Hashtbl.replace live key ()) index;
    Hashtbl.filter_map_inplace (fun key v -> if Hashtbl.mem live key then Some v else None) st.cache;
    st.pages <-
      Hashtbl.fold (fun _ (_, p) acc -> p :: acc) st.cache []
      |> List.sort (fun (a : Profile.t) b -> compare b.fetched_at a.fetched_at)
      |> Array.of_list

let rec watch st =
  let* () = Lwt.catch (fun () -> reload st) (fun _ -> Lwt.return_unit) in
  let* () = Lwt_unix.sleep 3. in
  watch st

let strings l = `List (List.map (fun s -> `String s) l)
let onto st = st.engine.onto

(* Golden-set adjudication, a hash: url -> {gold, rejected, at} (JSON). *)
let judgements = Lab.k "adjudication"
let gold_ids j = Yojson.Safe.Util.(List.map to_string (to_list (member "gold" j)))

let gold_of st url =
  let+ saved = Valkey.string_opt st.kv [ "HGET"; judgements; url ] in
  Option.map (fun s -> gold_ids (Yojson.Safe.from_string s)) saved

let evidence_json (e : Label.evidence) =
  `Assoc [ ("tier", `String e.tier); ("zone", `String e.zone); ("quote", `String e.quote); ("why", `String e.why) ]

let label_json st ?(evidence = []) (id, score) =
  `Assoc
    [ ("id", `String id); ("path", `String (Ontology.path (onto st) id)); ("score", `Float score);
      ("sensitive", `Bool (Engine.is_sensitive (onto st) id)); ("evidence", `List (List.map evidence_json evidence)) ]

(* Labels a tier found itself, not ancestors filled in by the hierarchy. *)
let headline (labels : Label.t list) =
  List.filter (fun (l : Label.t) -> List.exists (fun (e : Label.evidence) -> e.tier <> "hierarchy") l.evidence) labels

let served (l : Profile.level) = List.filter (fun (x : Label.t) -> x.score >= 0.5) l.result.labels

(* [served] is closed under ancestors, so the front end checks gold verdicts
   the way hierarchical F1 counts them. *)
let level_json st (l : Profile.level) =
  let r = l.result in
  let last4 ev = List.filteri (fun i _ -> i >= List.length ev - 4) ev in
  let ids = List.map (fun (x : Label.t) -> x.id) (served l) in
  `Assoc
    [ ("preset", `String l.preset); ("ran", strings r.ran); ("spent", `Float r.spent);
      ("stop", `String (Cascade.stop_name r.stop)); ("served_count", `Int (List.length ids));
      ("served", strings (Golden.closure (onto st) ids));
      ( "labels",
        `List
          (List.map
             (fun (x : Label.t) -> label_json st ~evidence:(last4 x.evidence) (x.id, x.score))
             (Engine.top 8 (headline r.labels))) ) ]

let summary_json st ~level ~judged (p : Profile.t) =
  let labels, stop, spent, sensitive =
    match Profile.level p level with
    | Some l ->
        ( Engine.top 3 (headline l.result.labels), Cascade.stop_name l.result.stop, l.result.spent,
          List.exists (fun (x : Label.t) -> Engine.is_sensitive (onto st) x.id) (served l) )
    | None -> ([], "", 0., false)
  in
  `Assoc
    [ ("url", `String p.url); ("site", `String p.site); ("title", `String p.title);
      ("fetched_at", `Float p.fetched_at); ("segments", `Int (List.length p.segments)); ("stop", `String stop);
      ("spent", `Float spent); ("sensitive", `Bool sensitive); ("adjudicated", `Bool (Hashtbl.mem judged p.url));
      ("labels", `List (List.map (fun (l : Label.t) -> label_json st (l.id, l.score)) labels)) ]

let page_json st ~gold (p : Profile.t) =
  let segment i (s : Profile.segment) =
    `Assoc
      [ ("i", `Int i); ("tag", `String s.tag); ("text", `String s.text); ("main", `Bool s.main); ("article", `Int s.article);
        ("top", `Float s.top); ("height", `Float s.height); ("labels", `List (List.map (label_json st) s.labels)) ]
  in
  let gold =
    match gold with
    | None -> `Null
    | Some ids ->
        `Assoc
          [ ("labels", `List (List.map (fun id -> label_json st (id, 1.)) ids));
            ("closure", strings (Golden.closure (onto st) ids)) ]
  in
  `Assoc
    [ ("url", `String p.url); ("site", `String p.site); ("title", `String p.title);
      ("fetched_at", `Float p.fetched_at); ("keywords", strings p.keywords);
      ("levels", `List (List.map (level_json st) p.levels)); ("segments", `List (List.mapi segment p.segments));
      ("t4_gate", `String p.t4_gate); ("gold", gold);
      ( "ad_slots",
        `List
          (List.map
             (fun (a : Profile.ad_slot) -> `Assoc [ ("id", `String a.id); ("index", `Int a.index); ("learned", `Bool a.learned) ])
             p.ad_slots) );
      ( "articles",
        `List
          (List.map
             (fun (a, labels) -> `Assoc [ ("article", `Int a); ("labels", `List (List.map (label_json st) (Engine.top 6 labels))) ])
             p.articles) ) ]

let verdict_parts = function Matcher.Blocked why -> (true, [ why ]) | Matcher.Eligible e -> (false, e.reasons)

let slot_json (s : Engine.slot) =
  let blocked, reasons = verdict_parts s.verdict in
  `Assoc
    [ ("ad", `String s.ad); ("after", `Int s.after); ("y", `Float s.y); ("reach", `Float s.reach); ("fit", `Float s.fit);
      ("p", `Float (s.reach *. s.fit)); ("blocked", `Bool blocked); ("reasons", strings reasons);
      ("flagged", `List (List.map (fun i -> `Int i) s.flagged)) ]

type ask = { creative : Matcher.creative; format : string; level : string; request : Yojson.Safe.t }

let ask st j =
  let open Yojson.Safe.Util in
  let str k default = Option.value (to_string_option (member k j)) ~default in
  let format = str "format" "scroll-through" and level = str "level" "standard" in
  if not (List.mem format Slot.formats) then invalid_arg ("unknown format " ^ format);
  if not (List.mem_assoc level Engine.presets) then invalid_arg ("unknown level " ^ level);
  let avoid_sensitive = Option.value (to_bool_option (member "avoid_sensitive" j)) ~default:true in
  { creative = Engine.creative_of_prompt st.engine ~avoid_sensitive (str "prompt" ""); format; level; request = j }

let creative_json st (c : Matcher.creative) =
  `Assoc [ ("labels", `List (List.map (label_json st) c.labels)); ("keywords", strings c.keywords) ]

let find_page st url = Array.find_opt (fun (p : Profile.t) -> p.url = url) st.pages

(* A page nobody crawled: its top section's profile, else its site's, as
   the bidder backs off (Store.sections). *)
let section_profile st url =
  let presets = List.map fst Engine.presets in
  Lwt_list.fold_left_s
    (fun found prefix ->
      match found with
      | Some _ -> Lwt.return found
      | None ->
          let+ body = Valkey.string_opt st.kv [ "GET"; Store.section_key prefix ] in
          Option.map (Profile.of_serving ~presets ~key:prefix) body)
    None (Store.sections url)

let placement st a =
  let url = Yojson.Safe.Util.(to_string (member "url" a.request)) in
  let* found =
    match find_page st url with
    | Some p -> Lwt.return_some (p, "page")
    | None -> Lwt.map (Option.map (fun (p : Profile.t) -> (p, if String.contains p.key '/' then "section" else "site"))) (section_profile st url)
  in
  match found with
  | None -> Web.error `Not_found "page not crawled, and no section or site profile"
  | Some (p, from) ->
      (* "geometry": [[segment, top, height], ...] in viewports, as the lab's
         frame rendered the page; without it, heights are estimated. *)
      let geometry =
        match Yojson.Safe.Util.member "geometry" a.request with
        | `List rows ->
            List.filter_map
              (function
                | `List [ `Int i; top; h ] -> (
                    match (Yojson.Safe.Util.to_number_option top, Yojson.Safe.Util.to_number_option h) with
                    | Some top, Some h -> Some (i, top, h)
                    | _ -> None)
                | _ -> None)
              rows
        | _ -> []
      in
      let p = if geometry = [] then p else Profile.measured p geometry in
      let* slots = Web.detach st.pool (fun () -> Engine.slots st.engine ~format:a.format ~level:a.level p a.creative) () in
      let g = Slot.geometry a.format in
      Web.json
        (`Assoc
           [ ("creative", creative_json st a.creative); ("profile", `Assoc [ ("from", `String from); ("key", `String p.key) ]);
             ("measured", `Bool (geometry <> []));
             ( "geometry",
               `Assoc
                 [ ("page_weight", `Float g.page_weight); ("reach_above", `Float g.reach_above);
                   ("reach_below", `Float g.reach_below); ("co_visible", `Float Slot.co_visible) ] );
             ("slots", `List (List.map slot_json slots)) ])

(* Outreach: share of crawled pages where the creative fits somewhere, by
   site. shortcut: counts pages, not impressions; weight by bid-log traffic
   per URL (README roadmap M0) for a real reach figure. *)
let outreach st a =
  let threshold = Option.value Yojson.Safe.Util.(to_number_option (member "threshold" a.request)) ~default:0.5 in
  let pages = st.pages in
  let* best =
    Web.detach st.pool
      (fun () ->
        (Web.parallel st.pool).Engine.map
          (fun p -> (p, Engine.best_slot st.engine ~format:a.format ~level:a.level p a.creative))
          pages)
      ()
  in
  let best = Array.to_list best in
  let matched = List.filter (fun (_, (s : Engine.slot)) -> s.fit >= threshold) best in
  let histogram = Array.make 10 0 in
  List.iter (fun (_, (s : Engine.slot)) -> let b = min 9 (int_of_float (s.fit *. 10.)) in histogram.(b) <- histogram.(b) + 1) best;
  let sites = List.sort_uniq compare (List.map (fun ((p : Profile.t), _) -> p.site) best) in
  let count site l = List.length (List.filter (fun ((p : Profile.t), _) -> p.site = site) l) in
  let site_json site =
    `Assoc [ ("site", `String site); ("total", `Int (count site best)); ("matched", `Int (count site matched)) ]
  in
  let hit ((p : Profile.t), (s : Engine.slot)) =
    let blocked, reasons = verdict_parts s.verdict in
    `Assoc
      [ ("url", `String p.url); ("title", `String p.title); ("site", `String p.site); ("fit", `Float s.fit);
        ("after", `Int s.after); ("blocked", `Bool blocked);
        ("reason", `String (match reasons with r :: _ -> r | [] -> "no topical overlap")) ]
  in
  let ranked = List.sort (fun (_, (a : Engine.slot)) (_, b) -> compare b.fit a.fit) best in
  Web.json
    (`Assoc
      [ ("total", `Int (List.length best)); ("matched", `Int (List.length matched));
        ("creative", creative_json st a.creative);
        ("histogram", `List (Array.to_list (Array.map (fun n -> `Int n) histogram)));
        ("sites", `List (List.map site_json sites)); ("pages", `List (List.map hit (Engine.top 50 ranked))) ])

(* Candidates are the top 12 labels each level found itself; the judge keeps
   or drops them and adds what all levels missed. Ancestors are left out:
   hierarchical F1 adds them on both sides. *)

let candidate_json st (p : Profile.t) id =
  let found =
    List.filter_map
      (fun (l : Profile.level) ->
        List.find_opt (fun (x : Label.t) -> x.id = id) (Engine.top 12 (headline l.result.labels))
        |> Option.map (fun x -> (l.preset, x)))
      p.levels
  in
  let score, evidence =
    match List.rev found with
    | (_, (x : Label.t)) :: _ -> (x.score, List.filter (fun (e : Label.evidence) -> e.tier <> "hierarchy") x.evidence)
    | [] -> (0., [])
  in
  let scores = List.map (fun (preset, (x : Label.t)) -> (preset, `Float x.score)) found in
  match label_json st ~evidence:(List.filteri (fun i _ -> i < 3) evidence) (id, score) with
  | `Assoc fields -> `Assoc (("scores", `Assoc scores) :: fields)
  | j -> j

(* Plus the judge's earlier additions, so a saved judgement shows in full. *)
let candidates st (p : Profile.t) ~saved =
  let found = List.concat_map (fun (l : Profile.level) -> List.map (fun (x : Label.t) -> x.id) (Engine.top 12 (headline l.result.labels))) p.levels in
  let added = match saved with `Null -> [] | j -> gold_ids j in
  List.sort_uniq compare (found @ added) |> List.map (candidate_json st p)

let adjudication st url =
  match find_page st url with
  | None -> Web.error `Not_found "page not crawled"
  | Some p ->
      let* saved = Valkey.string_opt st.kv [ "HGET"; judgements; p.url ] in
      let saved = match saved with Some s -> Yojson.Safe.from_string s | None -> `Null in
      Web.json (`Assoc [ ("candidates", `List (candidates st p ~saved)); ("saved", saved) ])

let adjudicate st j =
  let open Yojson.Safe.Util in
  let url = to_string (member "url" j) in
  let ids k = List.map to_string (to_list (member k j)) in
  let gold = ids "gold" and rejected = ids "rejected" in
  match List.find_opt (fun id -> Ontology.ancestors (onto st) id = []) (gold @ rejected) with
  | Some id -> Web.error `Bad_request ("unknown category " ^ id)
  | None when find_page st url = None -> Web.error `Not_found "page not crawled"
  | None ->
      let saved = `Assoc [ ("gold", strings gold); ("rejected", strings rejected); ("at", `Float (Unix.gettimeofday ())) ] in
      let* () = Valkey.run st.kv [ "HSET"; judgements; url; Yojson.Safe.to_string saved ] in
      Web.json saved

let forget st url =
  let* () = Valkey.run st.kv [ "HDEL"; judgements; url ] in
  Web.json (`Assoc [ ("url", `String url) ])

let all_judgements st =
  let+ pairs = Valkey.strings st.kv [ "HGETALL"; judgements ] in
  let rec go = function Some url :: Some j :: rest -> (url, Yojson.Safe.from_string j) :: go rest | _ -> [] in
  go pairs

(* Each level's served labels (>= 0.5) against the judgements, as the golden
   report scores the stored profiles, with what it gets wrong most often. *)
let golden_scores st =
  let+ all = all_judgements st in
  let by_url = Hashtbl.create (Array.length st.pages) in
  Array.iter (fun (p : Profile.t) -> Hashtbl.replace by_url p.url p) st.pages;
  let judged = List.filter_map (fun (url, j) -> Option.map (fun p -> (p, gold_ids j)) (Hashtbl.find_opt by_url url)) all in
  let num x = if Float.is_nan x then `Null else `Float x in
  let tally ids =
    let h = Hashtbl.create 64 in
    List.iter (fun id -> Hashtbl.replace h id (1 + Option.value (Hashtbl.find_opt h id) ~default:0)) ids;
    List.sort (fun (_, a) (_, b) -> compare b a) (List.of_seq (Hashtbl.to_seq h))
    |> Engine.top 8
    |> List.map (fun (id, n) -> `Assoc [ ("id", `String id); ("path", `String (Ontology.path (onto st) id)); ("n", `Int n) ])
  in
  let level (preset, _) =
    let predicted (p : Profile.t) =
      match Profile.level p preset with Some l -> List.map (fun (x : Label.t) -> x.id) (served l) | None -> []
    in
    let p, r, f = Golden.prf (List.map (fun (pg, gold) -> Golden.overlap (onto st) ~gold ~predicted:(predicted pg)) judged) in
    let wrong, missed =
      List.fold_left
        (fun (w, m) (pg, gold) ->
          let truth = Golden.closure (onto st) gold and got = Golden.closure (onto st) (predicted pg) in
          (List.filter (fun id -> not (List.mem id truth)) (predicted pg) @ w, List.filter (fun id -> not (List.mem id got)) gold @ m))
        ([], []) judged
    in
    `Assoc
      [ ("preset", `String preset); ("p", num p); ("r", num r); ("f1", num f); ("false_positives", `List (tally wrong));
        ("missed", `List (tally missed)) ]
  in
  `Assoc
    [ ("judged", `Int (List.length judged)); ("pages", `Int (Array.length st.pages));
      ("levels", `List (List.map level Engine.presets)) ]

let export st =
  let* pairs = Valkey.strings st.kv [ "HGETALL"; judgements ] in
  let rec rows = function
    | Some url :: Some j :: rest ->
        let j = Yojson.Safe.from_string j in
        let ids k = String.concat "," (List.map Yojson.Safe.Util.to_string (Yojson.Safe.Util.(to_list (member k j)))) in
        Printf.sprintf "%s\t%s\t%s\t%.0f\n" url (ids "gold") (ids "rejected") (Yojson.Safe.Util.(to_number (member "at" j)))
        :: rows rest
    | _ -> []
  in
  let body = "url\tgold\trejected\tat\n" ^ String.concat "" (List.sort compare (rows pairs)) in
  Web.Server.respond_string ~status:`OK ~headers:(Web.headers "text/tab-separated-values; charset=utf-8") ~body ()

let taxonomy st q =
  let q = Text.words q in
  Ontology.ids (onto st)
  |> List.filter (fun id -> q <> "" && Text.contains (Text.normalize (Ontology.path (onto st) id)) q)
  |> List.map (fun id -> (String.length (Ontology.path (onto st) id), id))
  |> List.sort compare |> Engine.top 20
  |> List.map (fun (_, id) -> label_json st (id, 1.))

(* An archived page (Archive), from the crawler replica that holds it, made
   safe to show in the lab's frame (Replay). *)
let replay st url =
  let* entry = Lab.warc_entry st.kv (Store.normalize url) in
  match entry with
  | None -> Web.error `Not_found "not archived: crawl the page again"
  | Some (replica, _, _, _) -> (
      let base =
        if st.replicas = "" then st.crawler
        else Re.replace_string (Re.Perl.compile_pat {|\{replica\}|}) ~by:replica st.replicas
      in
      let target = Uri.add_query_param' (Uri.of_string (base ^ "/record")) ("url", url) in
      let* resp, body = Cohttp_lwt_unix.Client.get target in
      let* html = Cohttp_lwt.Body.to_string body in
      match Cohttp.Response.status resp with
      | `OK ->
          let get k = Option.value (Cohttp.Header.get (Cohttp.Response.headers resp) k) ~default:"" in
          let headers =
            Cohttp.Header.of_list
              ((("content-type", get "content-type") :: ("x-warc-date", get "x-warc-date") :: Replay.headers))
          in
          Web.Server.respond_string ~status:`OK ~headers ~body:(Replay.prepare ~url html) ()
      | s -> Web.Server.respond_string ~status:s ~headers:(Web.headers "application/json") ~body:html ())

let proxy st req body =
  let path = Web.path req in
  let target =
    Uri.with_query
      (Uri.with_path (Uri.of_string st.crawler) (String.sub path 8 (String.length path - 8)))
      (Uri.query (Cohttp.Request.uri req))
  in
  let* body = Cohttp_lwt.Body.to_string body in
  let* resp, rbody = Cohttp_lwt_unix.Client.call ~body:(Cohttp_lwt.Body.of_string body) (Cohttp.Request.meth req) target in
  let* s = Cohttp_lwt.Body.to_string rbody in
  Web.Server.respond_string ~status:(Cohttp.Response.status resp) ~headers:(Web.headers "application/json") ~body:s ()

let file st name content_type =
  Web.Server.respond_file ~headers:(Web.headers content_type) ~fname:(Filename.concat st.web name) ()

let handler st req body =
  let level () = Option.value (Web.param req "level") ~default:"standard" in
  match (Cohttp.Request.meth req, Web.path req) with
  | `GET, "/" -> file st "index.html" "text/html; charset=utf-8"
  | `GET, "/style.css" -> file st "style.css" "text/css"
  | `GET, "/app.js" -> file st "dist/app.js" "text/javascript"
  | `GET, "/api/pages" ->
      let level = level () in
      let* keys = Valkey.strings st.kv [ "HKEYS"; judgements ] in
      let judged = Hashtbl.create 512 in
      List.iter (Option.iter (fun k -> Hashtbl.replace judged k ())) keys;
      Web.json (`List (Array.to_list (Array.map (summary_json st ~level ~judged) st.pages)))
  | `GET, "/api/page" -> (
      match Option.bind (Web.param req "url") (find_page st) with
      | Some p ->
          let* gold = gold_of st p.url in
          Web.json (page_json st ~gold p)
      | None -> Web.error `Not_found "page not crawled")
  | `POST, "/api/placement" ->
      let* j = Web.body_json body in
      placement st (ask st j)
  | `POST, "/api/outreach" ->
      let* j = Web.body_json body in
      outreach st (ask st j)
  | `GET, "/api/adjudication" -> adjudication st (Option.value (Web.param req "url") ~default:"")
  | `POST, "/api/adjudication" ->
      let* j = Web.body_json body in
      adjudicate st j
  | `DELETE, "/api/adjudication" -> forget st (Option.value (Web.param req "url") ~default:"")
  | `GET, "/api/adjudication.tsv" -> export st
  | `GET, "/api/golden" -> Lwt.bind (golden_scores st) Web.json
  | `GET, "/api/taxonomy" -> Web.json (`List (taxonomy st (Option.value (Web.param req "q") ~default:"")))
  | `GET, "/replay" -> (
      match Web.param req "url" with Some url -> replay st url | None -> Web.error `Bad_request "url required")
  | _, path when String.starts_with ~prefix:"/crawler/" path -> proxy st req body
  | _ -> Web.error `Not_found "no such route"

let () =
  let port = ref 8080 and data = ref "data" and valkey = ref "valkey://localhost:6379" and web = ref "frontend" in
  let crawler = ref "http://localhost:8081" and replicas = ref "" in
  Arg.parse
    [ ("--port", Arg.Set_int port, "PORT (8080)");
      ("--data", Arg.Set_string data, "DIR taxonomy, lexicon, embedding model (data)");
      ("--valkey", Arg.Set_string valkey, "URI valkey://host:port or sentinel://host:port/name (valkey://localhost:6379)");
      ("--web", Arg.Set_string web, "DIR front end: index.html, style.css, dist/app.js (frontend)");
      ("--crawler", Arg.Set_string crawler, "URL crawl daemon (http://localhost:8081)");
      ("--replicas", Arg.Set_string replicas, "URL one crawler replica, {replica} its name: who holds an archived page (--crawler)") ]
    ignore "online [options]";
  let st =
    { engine = Engine.load ~vision:false !data; pool = Web.setup_pool (); kv = Valkey.create !valkey; web = !web; crawler = !crawler; replicas = !replicas;
      cache = Hashtbl.create 1024; pages = [||] }
  in
  Lwt_main.run
    (let* () = reload st in
     Printf.printf "%d crawled pages\n%!" (Array.length st.pages);
     Lwt.async (fun () -> watch st);
     Web.serve ~port:!port (handler st))
