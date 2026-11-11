(* Offline crawl daemon. Lwt fetches (libcurl multi, polite per host, robots.txt),
   Domainslib classifies (every depth preset, every segment in parallel), and
   the profile lands in Valkey. All crawl state lives in Valkey too (Lab):
   any number of replicas share one frontier, one seen-set, one politeness
   schedule per origin, and the robots.txt and RSL license caches.

   POST /crawl         {"url": "..."} | {"urls": [...]}
                       | {"site": "https://...", "max_pages": 30}; "force": true re-crawls
   POST /traffic       one "url<TAB>bid requests per day" line per page, busiest
                       first (deploy/traffic.example.sh)
   POST /coverage      same lines: how much of that traffic has a stored profile
                       (deploy/coverage.example.sh)
   POST /sections      adds pages stored before section profiles existed to their
                       section and site, once
   GET  /record?url=   the page's latest raw record (WARC), if this replica holds it
   POST /replay        classifies this replica's archived pages again, unfetched
   GET  /status        queue, counters, last 100 outcomes
   GET  /pages         what is stored
   GET  /inspect?url=  stored profile + the cascade's explanation per preset

   --news SITE (repeatable) queues the pages its sitemaps dated in the last 48 h,
   every 10 minutes; --pubsub SUBSCRIPTION pulls the bidder's crawl requests
   for pages served without a profile (sdks/go CrawlRequests).

   Pages with traffic are fetched again on a schedule (Refresh): with their
   validators, reclassified only when their main text moved, every 2 h for
   48 h after publication, then less and less often; hubs are served by
   their section. Each page gets zero_fetch, standard and rich, rich with a
   budget that follows its bid requests per day; --audit adds deep. Images
   are fetched and embedded only when a level the text tiers left in doubt
   can afford them. With --llm MODEL, T4 runs through OpenRouter for every
   level whose budget affords it: a dry run on the pool finds the prompts,
   Lwt sends them, the pool reruns the cascade with the answers. No worker
   ever blocks on I/O. *)

open Contextual
open Serve
open Lwt.Syntax

(* [next_at] paces this replica's discovery fetches (sitemaps, home page);
   page fetches are paced across replicas by Lab's schedule. *)
type host = { robots : Robots.t; expires : float; mutable next_at : float }

type llm = { client : Openrouter.t; cost : float }

type t = {
  engine : Engine.t;
  llm : llm option;
  pool : Web.pool;
  kv : Valkey.t;
  replica : string;
  hosts : (string, host Lwt.t) Hashtbl.t;
  licenses : (string, (Ai_use.Rsl.content list option * float) Lwt.t) Hashtbl.t;
  audit : bool; (* also the deep level, for golden sets and audits *)
  version : string; (* pipeline version this replica classifies with (Engine.version) *)
  archive : Archive.t; (* raw pages, WARC *)
}

let agent = "ContextBot"
let min_delay = 1.0

let origin url =
  let u = Uri.of_string url in
  Printf.sprintf "%s://%s%s" (Option.value (Uri.scheme u) ~default:"https") (Option.value (Uri.host u) ~default:"")
    (match Uri.port u with Some p -> ":" ^ string_of_int p | None -> "")

let is_web url = String.starts_with ~prefix:"http://" url || String.starts_with ~prefix:"https://" url

let day = 86_400

(* RFC 9309 §2.3.1 and §2.4: a missing robots.txt (4xx) allows everything
   (cached as an empty file); an unreachable one (5xx, network error)
   disallows everything, cached for 5 minutes so it is retried soon; a fetched
   one is cached for 24 h. One fetch serves every replica. *)
let robots_body url =
  let+ r = Web.fetch (origin url ^ "/robots.txt") in
  match r with
  | Ok { status = 200; body; _ } -> (body, day)
  | Ok { status; _ } when status < 500 -> ("", day)
  | _ -> ("User-agent: *\nDisallow: /", 300)

let host_info st url =
  let o = origin url in
  let fresh () =
    let h =
      let key = "robots:" ^ o in
      let* cached = Lab.cached st.kv key in
      let+ body, ttl =
        match cached with
        | Some body -> Lwt.return (Option.value body ~default:"", day)
        | None ->
            let* body, ttl = robots_body url in
            let+ () = Lab.cache st.kv key ~ttl (Some body) in
            (body, ttl)
      in
      { robots = Robots.parse ~agent body; expires = Unix.gettimeofday () +. float ttl; next_at = 0. }
    in
    Hashtbl.replace st.hosts o h;
    h
  in
  match Hashtbl.find_opt st.hosts o with
  | Some h -> (
      match Lwt.state h with
      | Lwt.Return { expires; _ } when expires < Unix.gettimeofday () -> fresh ()
      | Lwt.Fail _ -> fresh ()
      | _ -> h)
  | None -> fresh ()

let delay h = Float.max min_delay (Option.value h.robots.delay ~default:0.)

(* Discovery fetches: one per host per max(1 s, Crawl-delay) on this replica. *)
let polite h =
  let now = Unix.gettimeofday () in
  let at = Float.max now h.next_at in
  h.next_at <- at +. delay h;
  Lwt_unix.sleep (at -. now)

(* Sitemaps, home pages and RSL licenses too: robots.txt covers every URL. *)
let fetch_politely ?headers st url =
  let* h = host_info st url in
  if not (Robots.allowed h.robots url) then Lwt.return (Error "disallowed by robots.txt")
  else
    let* () = polite h in
    Web.fetch ?headers url

let enqueue st ?(force = false) ?(hints = []) ?requests url =
  if not (is_web url) then Lwt.return_false
  else Lab.enqueue st.kv ?requests ~key:(Store.normalize url) ~url ~origin:(origin url) ~hints ~force ()

(* T3 for video: the provider's oEmbed title and author. A player's oEmbed
   endpoint, its url parameter percent-encoded:
     //www.youtube.com/embed/abc?rel=0  -> youtube.com/oembed, url www.youtube.com/watch?v=abc
     https://player.vimeo.com/video/42  -> vimeo.com/api/oembed.json, url vimeo.com/42 *)
let oembed_endpoint src =
  let src = if String.starts_with ~prefix:"//" src then "https:" ^ src else src in
  let enc = Uri.pct_encode ~component:`Query_value in
  let id_after marker =
    Option.map
      (fun i ->
        let s = String.sub src (i + String.length marker) (String.length src - i - String.length marker) in
        List.hd (String.split_on_char '?' (List.hd (String.split_on_char '/' s))))
      (Text.find src ~from:0 marker)
  in
  let youtube u = Some ("https://www.youtube.com/oembed?format=json&url=" ^ enc u) in
  match (id_after "/embed/", id_after "player.vimeo.com/video/") with
  | Some id, _ when Text.contains src "youtube" -> youtube ("https://www.youtube.com/watch?v=" ^ id)
  | _, Some id -> Some ("https://vimeo.com/api/oembed.json?url=" ^ enc ("https://vimeo.com/" ^ id))
  | _ when Text.contains src "youtube.com/watch" || Text.contains src "youtu.be/" -> youtube src
  | _ -> None

let oembed_text body =
  match Yojson.Safe.from_string body with
  | `Assoc kv ->
      let s k = match List.assoc_opt k kv with Some (`String v) -> v | _ -> "" in
      Some (String.trim (s "title" ^ " " ^ s "author_name"))
  | _ -> None
  | exception Yojson.Json_error _ -> None

let describe_media (d : Doc.t) =
  Lwt_list.filter_map_p
    (fun (m : Doc.media) ->
      match oembed_endpoint m.src with
      | None -> Lwt.return_none
      | Some url -> (
          let+ r = Web.fetch ~max_bytes:100_000 url in
          match r with
          | Ok { status = 200; body; _ } -> Option.map (fun text -> (m.src, text)) (oembed_text body)
          | _ -> None))
    (Tier.undescribed [ Doc.Video ] d)

(* T3 for pictures: each image without usable alt text fetched (robots.txt
   and politeness as for pages; WebP, PNG or JPEG asked for, as the decoders
   read nothing else), then decoded and embedded on the pool with one ggml
   thread. An image that fails at any step is simply not seen. *)
let see_images st (d : Doc.t) =
  match st.engine.Engine.vision with
  | None -> Lwt.return []
  | Some v ->
      let embed src =
        let* r = fetch_politely ~headers:[ "Accept: image/webp,image/png,image/jpeg;q=0.9" ] st src in
        match r with
        | Ok { status = 200; body; _ } ->
            let* e =
              Web.detach st.pool (fun b -> Siglip.embed v.model b ~max_patches:v.max_patches ~min_side:v.min_side ~threads:1) body
            in
            let+ () =
              Lab.cache st.kv (Lab.image_key ~max_patches:v.max_patches src) ~ttl:(30 * day)
                (Option.map Lab.encode_floats (Result.to_option e))
            in
            Result.to_option e
        | _ -> Lwt.return_none
      in
      Lwt_list.filter_map_p
        (fun (m : Doc.media) ->
          let src = Uri.to_string (Uri.resolve "" (Uri.of_string d.url) (Uri.of_string m.src)) in
          if not (is_web src) then Lwt.return_none
          else
            Lwt.catch
              (fun () ->
                let* cached = Lab.cached st.kv (Lab.image_key ~max_patches:v.max_patches src) in
                let+ e = match cached with Some e -> Lwt.return (Option.map Lab.decode_floats e) | None -> embed src in
                Option.map (fun e -> (m.src, e)) e)
              (fun _ -> Lwt.return_none))
        (Tier.undescribed [ Doc.Image ] d)

(* What a page earns, from its bid requests per day (its frontier score), at
   assumed rates: 2% of bid requests become impressions, sold at a $25 eCPM.
   Set them to your own. *)
let impressions_per_request = 0.02
let ecpm = 25.

(* rich spends what the page earns (Cascade.value_budget), at least
   standard's budget and at most rich's: about 4 requests a day afford T4. *)
let presets st ~requests =
  let value = Cascade.value_budget ~daily_impressions:(requests *. impressions_per_request) ~cpm:ecpm () in
  let budget = Float.min Cascade.rich.budget (Float.max Cascade.standard.budget value) in
  [ ("zero_fetch", Cascade.zero_fetch); ("standard", Cascade.standard); ("rich", { Cascade.rich with budget }) ]
  @ if st.audit then [ ("deep", Cascade.deep) ] else []

(* Images cost the most CPU of any tier, so a first pass without them, like
   T4's dry run, decides: are there images to see, and is some level still
   in doubt after the text tiers, with room for one? *)
let needs_images st presets ~describe d =
  st.engine.Engine.vision <> None
  && Tier.undescribed [ Doc.Image ] d <> []
  && List.exists2
       (fun (_, (p : Cascade.policy)) (l : Profile.level) ->
         l.result.stop <> Cascade.Settled && l.result.spent +. Tier.image_cost <= p.budget)
       presets
       (Engine.levels ~presets st.engine ~describe d)

(* Phases 1 and 2 of T4 (see [classify]). Any failed call drops T4 for this
   page rather than letting an empty answer zero the labels. *)
let ask_llm st (l : llm) ~presets ~describe ~see doc =
  let* prompts = Web.detach st.pool (fun d -> Engine.llm_prompts ~see ~presets ~cost:l.cost st.engine ~describe d) doc in
  let* answers = Lwt_list.map_p (fun p -> Lwt.map (fun r -> (p, r)) (Openrouter.complete l.client p)) prompts in
  let+ () =
    Lwt_list.iter_s
      (fun (_, r) ->
        match r with
        | Ok (a : Openrouter.answer) -> Lab.llm_call st.kv ~cost:a.cost ~ok:true
        | Error _ -> Lab.llm_call st.kv ~cost:0. ~ok:false)
      answers
  in
  if List.exists (fun (_, r) -> Result.is_error r) answers then None
  else
    let complete p =
      match List.assoc_opt p answers with Some (Ok (a : Openrouter.answer)) -> a.content | _ -> ""
    in
    Some { Engine.complete; cost = l.cost; name = l.client.model.id }

(* An RSL license, shared through Valkey for its max-age (RSL §3.2.1,
   default 30 days). One that cannot be fetched is cached as missing for an
   hour: meanwhile the page counts as unlicensed (§4.3). *)
let rsl_license st url =
  let fresh () =
    let doc =
      let key = "license:" ^ url in
      let* cached = Lab.cached st.kv key in
      let+ body, ttl =
        match cached with
        | Some body -> Lwt.return (body, 3600)
        | None ->
            let* r = if is_web url then fetch_politely st url else Lwt.return (Error "not http(s)") in
            let body, ttl =
              match r with
              | Ok { status = 200; body; _ } ->
                  (Some body, 86_400 * Option.value (Ai_use.Rsl.max_age_days body) ~default:30)
              | _ -> (None, 3600)
            in
            let+ () = Lab.cache st.kv key ~ttl body in
            (body, ttl)
      in
      (Option.bind body Ai_use.Rsl.parse, Unix.gettimeofday () +. float ttl)
    in
    Hashtbl.replace st.licenses url doc;
    doc
  in
  let doc =
    match Hashtbl.find_opt st.licenses url with
    | Some d -> ( match Lwt.state d with Lwt.Return (_, expires) when expires < Unix.gettimeofday () -> fresh () | Lwt.Fail _ -> fresh () | _ -> d)
    | None -> fresh ()
  in
  Lwt.map fst doc

(* Does the publisher let this page's text go into a generative model? *)
let t4_gate st (h : host) url (r : Web.response) =
  let header name = List.filter_map (fun (k, v) -> if k = name then Some v else None) r.headers in
  let aipref where s = (Ai_use.preference "ai-use" s, "aipref ai-use, " ^ where) in
  let prefs =
    List.map (fun (s, line) -> aipref (Printf.sprintf "robots.txt line %d" line) s) (Robots.content_usage h.robots url)
    @ List.map (aipref "Content-Usage header") (header "content-usage")
    @ List.map (fun s -> (Ai_use.signal "ai-input" s, "Content-Signal ai-input, robots.txt")) h.robots.signals
  in
  let resolve href = Uri.to_string (Uri.resolve "" (Uri.of_string url) (Uri.of_string href)) in
  let license_urls =
    List.sort_uniq compare
      (h.robots.licenses
      @ List.concat_map Ai_use.link_licenses (header "link")
      @ List.map resolve (Ai_use.html_licenses r.body))
  in
  let+ docs = Lwt_list.map_p (fun u -> Lwt.map (fun d -> (u, d)) (rsl_license st u)) license_urls in
  let path = Uri.path (Uri.of_string url) in
  Ai_use.t4 ~prefs ~licenses:docs ~url ~path:(if path = "" then "/" else path)

(* Every level of one fetched page. CPU work runs on the pool (Web.detach),
   network work on Lwt; T4 takes three phases so no pool worker waits on
   the network (ask_llm runs only with --llm and a gate that allows T4):

     describe_media          Lwt    oEmbed title and author of each video
     needs_images            pool   text tiers alone: is a level in doubt with
                                    budget left for an image?
     see_images              Lwt    images fetched politely, embedded on the
                                    pool, cached in Valkey by URL
     t4_gate                 Lwt    aipref, Content Signals, RSL licenses
     ask_llm  1 llm_prompts  pool   dry run: the distinct prompts of the levels
                                    whose budget affords T4
              2 complete     Lwt    one OpenRouter call per prompt, in parallel
     ad slots                Lwt    learned from this page, or lent by its template
     3 Engine.profile        pool   every level again, T4 reading the answers *)
let classify st (h : host) url ~requests doc (r : Web.response) =
  let presets = presets st ~requests in
  let* described = describe_media doc in
  let describe (m : Doc.media) = List.assoc_opt m.src described in
  let* images = Web.detach st.pool (needs_images st presets ~describe) doc in
  let* seen = if images then see_images st doc else Lwt.return [] in
  let see (m : Doc.media) = List.assoc_opt m.src seen in
  let* gate = t4_gate st h url r in
  let* llm =
    match (st.llm, gate) with
    | Some l, Ai_use.Allowed _ -> ask_llm st l ~presets ~describe ~see doc
    | _ -> Lwt.return_none
  in
  let t4_gate = Ai_use.verdict_text gate in
  (* The template's ad slots: learned from this page when its HTML has them,
     lent to it from the template's other pages when not. *)
  let c = Lazy.force doc.Doc.content and template = Store.template url in
  let* ad_slots =
    if c.ad_slots <> [] then
      let+ () = Lab.learn_slots st.kv ~version:st.version ~template ~page:(Store.normalize url) (List.map (fun (id, i) -> (id, Doc.main_before c.segments i)) c.ad_slots) in
      []
    else
      let+ learned = Lab.learned_slots st.kv ~version:st.version ~template in
      List.map (fun (id, k) -> { Profile.id; index = Doc.after_main c.segments k; learned = true }) learned
  in
  Web.detach st.pool
    (fun d ->
      Engine.profile ?llm ~see ~presets ~t4_gate ~ad_slots st.engine ~describe
        ~fetched_at:(Unix.gettimeofday ()) d)
    doc

(* The origin was claimed from Lab's schedule; it is released (with the
   politeness delay) as soon as the fetch is over, before classification.
   A page seen before is fetched with its validators, and reclassified only
   if it changed (Refresh); either way its next fetch is scheduled.

     Lab.claim (worker)   origin, URL, hints, bid requests per day
     Lab.fresh            the last crawl's refresh state, if any
     host_info            robots.txt: this replica's, else Valkey's, else fetched
       ├─ disallowed ─> Error
     Web.fetch            If-None-Match / If-Modified-Since, same pipeline only
     Lab.release          origin claimable again in max(1 s, Crawl-delay)
       ├─ other status, not HTML ─> Error
       ├─ 304 ────────────────────────────────────────────────┐
     Doc.of_html (pool)   and the SimHash of the main text    │
       ├─ same pipeline, SimHash within 3 bits ───────────────┤
       │                                                      ▼
       │                                        unchanged: serving keys
       │                                        kept 30 more days (not a
       │                                        hub's), Lab.schedule
     classify             every level (above)
     Lab.save_profile     profile, serving key (none for a hub), sections
     Archive.append       the WARC record and its index entry
     Lab.schedule         next fetch, for a page with bid traffic
     Lab.finish (worker)  inflight cleared, counters, recent outcomes *)
let crawl_page st ~origin ~requests url hints =
  let key = Store.normalize url in
  let* old, known = Lab.fresh st.kv key in
  let requests = if requests > 0. then requests else known in
  (* A 304 can only say "unchanged": not worth asking when the pipeline
     changed and the page must be classified again anyway. *)
  let validators =
    match old with
    | Some o when o.version <> st.version -> []
    | None -> []
    | Some o ->
        (if o.etag = "" then [] else [ "If-None-Match: " ^ o.etag ])
        @ if o.last_modified = "" then [] else [ "If-Modified-Since: " ^ o.last_modified ]
  in
  let* fetched =
    Lwt.catch
      (fun () ->
        let* h = host_info st url in
        Lwt.finalize
          (fun () ->
            let rule = Robots.decision h.robots url in
            if not rule.allowed then Lwt.return (Error (Printf.sprintf "disallowed by robots.txt line %d" rule.line))
            else Lwt.map (fun r -> Ok (h, r)) (Web.fetch ~headers:validators url))
          (fun () -> Lab.release st.kv ~origin ~delay:(delay h)))
      (fun e ->
        let+ () = Lab.release st.kv ~origin ~delay:min_delay in
        Error (Printexc.to_string e))
  in
  let header (r : Web.response) name default = Option.value (List.assoc_opt name r.headers) ~default in
  let unchanged (o : Refresh.state) (r : Web.response) why =
    let s =
      { o with etag = header r "etag" o.etag; last_modified = header r "last-modified" o.last_modified;
               unchanged = o.unchanged + 1; moved = 0 }
    in
    let* () = if s.hub then Lwt.return_unit else Lab.touch st.kv url in
    let+ () = Lab.schedule st.kv ~key ~requests s in
    Ok ("unchanged: " ^ why)
  in
  match fetched with
  | Error e -> Lwt.return (Error e)
  | Ok (h, r) -> (
    match (r, old) with
    | Error e, _ -> Lwt.return (Error e)
    | Ok ({ status = 304; _ } as r), Some o -> unchanged o r "HTTP 304"
    | Ok { status; _ }, _ when status <> 200 -> Lwt.return (Error (Printf.sprintf "HTTP %d" status))
    | Ok { content_type; _ }, _ when not (Text.contains (String.lowercase_ascii content_type) "html") ->
        Lwt.return (Error ("not HTML: " ^ content_type))
    | Ok r, _ -> (
        let* doc = Web.detach st.pool (fun d -> ignore (Lazy.force d.Doc.content); d) (Doc.of_html ~hints ~url r.body) in
        let simhash = Refresh.simhash (Doc.main_text doc) in
        match old with
        | Some o when (not (Refresh.moved o.simhash simhash)) && o.version = st.version ->
            unchanged { o with simhash } r (Printf.sprintf "SimHash moved %d bits" (Refresh.distance o.simhash simhash))
        | _ ->
            let* p = classify st h url ~requests doc r in
            let c = Lazy.force doc.content in
            let moved = match old with Some o when Refresh.moved o.simhash simhash -> o.moved + 1 | _ -> 0 in
            let now = Unix.gettimeofday () in
            let s =
              { Refresh.url; etag = header r "etag" ""; last_modified = header r "last-modified" ""; simhash;
                version = st.version;
                published =
                  (match (Refresh.time_of c.published, old) with
                  | Some t, _ -> t
                  | None, Some o -> o.published
                  | None, None -> now);
                unchanged = (match old with Some o when moved = 0 -> o.unchanged + 1 | _ -> 0);
                moved;
                hub = Refresh.is_hub ~url ~live:c.live ~dated:(c.published <> "") ~moved }
            in
            let* () = Lab.save_profile ~serve:(not s.hub) st.kv p in
            let* () = Archive.append st.archive st.kv ~key ~url ~fetched_at:p.fetched_at r in
            let+ () = Lab.schedule st.kv ~key ~requests s in
            let stops =
              List.map (fun (l : Profile.level) -> l.preset ^ " " ^ Cascade.stop_name l.result.stop) p.levels
            in
            Ok
              (Printf.sprintf "%d segments; %s; T4 %s%s" (List.length p.segments) (String.concat ", " stops) p.t4_gate
                 (if s.hub then "; hub, served by its section" else ""))))

let rec worker st =
  let* job = Lwt.catch (fun () -> Lab.claim st.kv) (fun _ -> Lwt.return_none) in
  match job with
  | None ->
      let* () = Lwt_unix.sleep 0.5 in
      worker st
  | Some (origin, url, hints, requests) ->
      let* r =
        Lwt.catch (fun () -> crawl_page st ~origin ~requests url hints) (fun e -> Lwt.return (Error (Printexc.to_string e)))
      in
      let outcome, ok = match r with Ok m -> ("ok: " ^ m ^ " [" ^ st.replica ^ "]", true) | Error e -> ("failed: " ^ e, false) in
      let* () = Lwt.catch (fun () -> Lab.finish st.kv ~replica:st.replica ~url ~outcome ~ok) (fun _ -> Lwt.return_unit) in
      worker st

(* Pages due for a refresh go back to the frontier with their traffic; each
   is popped by one replica. *)
let rec refresh_loop st =
  let* () =
    Lwt.catch
      (fun () ->
        let* due = Lab.due st.kv ~limit:500 in
        Lwt_list.iter_s (fun (url, requests) -> Lwt.map ignore (enqueue st ~force:true ~requests url)) due)
      (fun _ -> Lwt.return_unit)
  in
  let* () = Lwt_unix.sleep 60. in
  refresh_loop st

(* Liveness for /status, and requeueing of claims whose crawler died. *)
let rec housekeeping st =
  let* () =
    Lwt.catch
      (fun () ->
        let* () = Lab.heartbeat st.kv ~replica:st.replica in
        let+ _ = Lab.reap st.kv in
        ())
      (fun _ -> Lwt.return_unit)
  in
  let* () = Lwt_unix.sleep 10. in
  housekeeping st

(* shortcut: plain XML only, .gz sitemaps are skipped; five children of an
   index, news sitemaps then the newest, two levels deep. Enough to sample a
   site and find its fresh pages, not to cover it. *)
let rec sitemap_pages st ~depth url =
  if depth > 2 || String.ends_with ~suffix:".gz" url then Lwt.return []
  else
    let* r = fetch_politely st url in
    match r with
    | Ok { status = 200; body; _ } ->
        let sm = Doc.parse_sitemap ~fetch:(fun _ -> Doc.empty) body in
        let pages =
          List.map (fun ((d : Doc.t), lastmod) -> (d.url, d.hints, Option.value lastmod ~default:"")) sm.pages
        in
        let news u = Text.contains (String.lowercase_ascii u) "news" in
        let children =
          List.rev (List.sort compare sm.children)
          |> List.stable_sort (fun a b -> compare (news b) (news a))
          |> List.filteri (fun i _ -> i < 5)
        in
        let+ nested = Lwt_list.map_s (sitemap_pages st ~depth:(depth + 1)) children in
        pages @ List.concat nested
    | _ -> Lwt.return []

let asset = Re.Perl.compile_pat {|\.(jpg|jpeg|png|gif|svg|webp|pdf|zip|mp4|mp3|css|js)$|}

(* shortcut: no sitemap means "same-host links with a long path" from the home
   page, a crude article detector. *)
let article_links base html =
  let b = Uri.of_string base in
  List.filter_map
    (function
      | Html.Open ("a", attrs) -> (
          match List.assoc_opt "href" attrs with
          | Some href ->
              let u = Uri.with_fragment (Uri.resolve "" b (Uri.of_string href)) None in
              let path = Uri.path u in
              if Uri.host u = Uri.host b && String.length path > 12 && not (Re.execp asset path) then
                Some (Uri.to_string u)
              else None
          | None -> None)
      | _ -> None)
    (Html.parse_html html)
  |> List.sort_uniq compare

(* The site's own pages its sitemaps list, newest first. *)
let sitemap_entries st ~site =
  let base = origin site in
  let* h = host_info st base in
  let sitemaps = if h.robots.sitemaps = [] then [ base ^ "/sitemap.xml" ] else h.robots.sitemaps in
  let+ found = Lwt_list.map_s (sitemap_pages st ~depth:0) sitemaps in
  let same_host u = Uri.host (Uri.of_string u) = Uri.host (Uri.of_string base) in
  List.concat found
  |> List.filter (fun (u, _, _) -> same_host u)
  |> List.sort (fun (_, _, a) (_, _, b) -> compare b a)

let discover st ~site ~max_pages =
  let* found = sitemap_entries st ~site in
  let* found =
    if found <> [] then Lwt.return found
    else
      let+ r = fetch_politely st site in
      match r with
      | Ok { status = 200; body; _ } -> List.map (fun u -> (u, [], "")) (article_links site body)
      | _ -> []
  in
  let picked = List.filteri (fun i _ -> i < max_pages) found in
  let+ queued = Lwt_list.filter_s (fun (u, hints, _) -> enqueue st ~hints u) picked in
  List.length queued

let discover_async st ~site ~max_pages =
  Lwt.async (fun () ->
      Lwt.catch
        (fun () ->
          let* n = discover st ~site ~max_pages in
          Lab.record_event st.kv ~url:site ~outcome:(Printf.sprintf "site: %d new pages queued" n))
        (fun e -> Lab.record_event st.kv ~url:site ~outcome:("site discovery failed: " ^ Printexc.to_string e)))

(* Fresh pages: what the sites' sitemaps dated in the last 48 hours (a news
   sitemap holds exactly those), rescanned every 10 minutes. A site's pages
   rank by how many it published, so the busiest publishers go first. *)
let fresh_pages st ~site =
  let+ entries = sitemap_entries st ~site in
  let since = Unix.gettimeofday () -. (2. *. float day) in
  List.filter (fun (_, _, date) -> match Doc.sitemap_time date with Some t -> t >= since | None -> false) entries

let rec watch_news st sites =
  let* () =
    Lwt_list.iter_p
      (fun site ->
        Lwt.catch
          (fun () ->
            let* pages = fresh_pages st ~site in
            let requests = float (List.length pages) in
            let* queued = Lwt_list.filter_s (fun (u, hints, _) -> enqueue st ~hints ~requests u) pages in
            Lab.record_event st.kv ~url:site
              ~outcome:(Printf.sprintf "news: %d fresh pages, %d new queued" (List.length pages) (List.length queued)))
          (fun e -> Lab.record_event st.kv ~url:site ~outcome:("news scan failed: " ^ Printexc.to_string e)))
      sites
  in
  let* () = Lwt_unix.sleep 600. in
  watch_news st sites

(* Crawl requests from the bidder's profile misses (sdks/go CrawlRequests):
   Pub/Sub pull over REST, one page URL per message. PUBSUB_EMULATOR_HOST
   selects the emulator (no auth); otherwise Google's API with the GCE/GKE
   metadata server's token. shortcut: no token outside Google Cloud; add a
   service-account key flow if the lab runs elsewhere. *)
let pubsub_endpoint () =
  match Sys.getenv_opt "PUBSUB_EMULATOR_HOST" with
  | Some host -> Lwt.return ("http://" ^ host, [])
  | None -> (
      let+ r =
        Web.fetch ~headers:[ "Metadata-Flavor: Google" ]
          "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
      in
      match r with
      | Ok { status = 200; body; _ } ->
          let token = Yojson.Safe.Util.(to_string (member "access_token" (Yojson.Safe.from_string body))) in
          ("https://pubsub.googleapis.com", [ "Authorization: Bearer " ^ token ])
      | _ -> failwith "no Pub/Sub credentials: set PUBSUB_EMULATOR_HOST or run on Google Cloud")

(* Without returnImmediately an empty pull hangs past the fetch timeout;
   the caller sleeps a second instead. Undecodable messages are acknowledged
   too: redelivering them cannot help. *)
let pull_crawl_requests st subscription =
  let* base, auth = pubsub_endpoint () in
  let call verb body =
    let* r = Web.fetch ~headers:("Content-Type: application/json" :: auth) ~body (Printf.sprintf "%s/v1/%s:%s" base subscription verb) in
    match r with
    | Ok { status = 200; body; _ } -> Lwt.return (Yojson.Safe.from_string body)
    | Ok { status; body; _ } -> Lwt.fail_with (Printf.sprintf "Pub/Sub %s: HTTP %d %s" verb status (Text.clip body))
    | Error e -> Lwt.fail_with (Printf.sprintf "Pub/Sub %s: %s" verb e)
  in
  let open Yojson.Safe.Util in
  let* pulled = call "pull" {|{"maxMessages":100,"returnImmediately":true}|} in
  let messages = match member "receivedMessages" pulled with `List l -> l | _ -> [] in
  let urls = List.filter_map (fun m -> Result.to_option (Base64.decode (to_string (member "data" (member "message" m))))) messages in
  let* queued = Lwt_list.filter_s (fun u -> enqueue st u) urls in
  let ack_ids = List.map (fun m -> member "ackId" m) messages in
  let+ () = if ack_ids = [] then Lwt.return_unit else Lwt.map ignore (call "acknowledge" (Yojson.Safe.to_string (`Assoc [ ("ackIds", `List ack_ids) ]))) in
  (List.length messages, List.length queued)

let rec consume_crawl_requests st subscription =
  let* () =
    Lwt.catch
      (fun () ->
        let* received, queued = pull_crawl_requests st subscription in
        if received = 0 then Lwt_unix.sleep 1.
        else Lab.record_event st.kv ~url:subscription ~outcome:(Printf.sprintf "crawl requests: %d received, %d new queued" received queued))
      (fun e ->
        let* () = Lab.record_event st.kv ~url:subscription ~outcome:("crawl requests failed: " ^ Printexc.to_string e) in
        Lwt_unix.sleep 10.)
  in
  consume_crawl_requests st subscription

let inspect st url =
  let* stored = Lab.profile st.kv (Store.normalize url) in
  match stored with
  | None -> Web.error `Not_found "not crawled yet"
  | Some s ->
      let p = Profile.of_json (Yojson.Safe.from_string s) in
      let explain (l : Profile.level) = (l.preset, `String (Cascade.explain st.engine.onto l.result)) in
      Web.json (`Assoc [ ("profile", Profile.to_json p); ("explain", `Assoc (List.map explain p.levels)) ])

let crawl_order st j =
  let open Yojson.Safe.Util in
  let force = Option.value (to_bool_option (member "force" j)) ~default:false in
  let urls =
    (match member "url" j with `String u -> [ u ] | _ -> [])
    @ match member "urls" j with `List l -> filter_string l | _ -> []
  in
  let requests = to_number_option (member "requests" j) in
  let* queued = Lwt_list.filter_s (fun u -> enqueue st ~force ?requests u) urls in
  (match member "site" j with
  | `String site when is_web site ->
      discover_async st ~site ~max_pages:(Option.value (to_int_option (member "max_pages" j)) ~default:30)
  | _ -> ());
  Web.json (`Assoc [ ("queued", `List (List.map (fun u -> `String u) queued)) ])

(* "url<TAB>count" lines from the bid logs, by page key: variants of one page
   (tracking parameters, www.) add up. Key -> (first URL seen, total). A line
   without a count counts 1: "https://a.example/x" = "https://a.example/x\t1".
     https://www.example.com/page<TAB>3
     https://example.com/page?utm_source=newsletter&utm_medium=email<TAB>2
       -> example.com/page -> (https://www.example.com/page, 5.) *)
let traffic_by_page body =
  let pages = Hashtbl.create 4096 in
  let add line =
    match String.split_on_char '\t' line with
    | url :: ([] | [ _ ] as count) when is_web url -> (
        match match count with [] -> Some 1. | c :: _ -> float_of_string_opt (String.trim c) with
        | Some n ->
            let key = Store.normalize url in
            let first, total = Option.value (Hashtbl.find_opt pages key) ~default:(url, 0.) in
            Hashtbl.replace pages key (first, total +. n)
        | None -> ())
    | _ -> ()
  in
  let+ body = Cohttp_lwt.Body.to_string body in
  List.iter add (String.split_on_char '\n' body);
  pages

let traffic_order st body =
  let* pages = traffic_by_page body in
  let* () = Lab.note_traffic st.kv (Hashtbl.fold (fun key (_, n) l -> (key, n) :: l) pages []) in
  let* queued =
    Lwt_list.filter_s (fun (url, requests) -> enqueue st ~requests url) (Hashtbl.fold (fun _ v l -> v :: l) pages [])
  in
  Web.json (`Assoc [ ("pages", `Int (Hashtbl.length pages)); ("queued", `Int (List.length queued)) ])

(* How much of that traffic falls on pages with a stored profile. *)
let coverage st body =
  let* pages = traffic_by_page body in
  let pages = Hashtbl.fold (fun key (_, n) l -> (key, n) :: l) pages [] in
  let+ stored = Lab.stored st.kv (List.map fst pages) in
  let covered = List.filteri (fun i _ -> stored.(i)) pages in
  let sum l = List.fold_left (fun t (_, n) -> t +. n) 0. l in
  Web.json
    (`Assoc
       [ ("pages", `Int (List.length pages)); ("covered_pages", `Int (List.length covered)); ("count", `Float (sum pages));
         ("covered_count", `Float (sum covered)) ])

(* A page's latest raw record, if this replica holds its file. *)
let record st url =
  let* entry = Lab.warc_entry st.kv (Store.normalize url) in
  match entry with
  | None -> Web.error `Not_found "not archived"
  | Some (replica, file, offset, length) -> (
      match Archive.read st.archive ~file ~offset ~length with
      | None -> Web.error `Not_found ("record on replica " ^ replica)
      | Some r ->
          let headers =
            Cohttp.Header.of_list
              [ ("content-type", if r.content_type = "" then "text/html" else r.content_type); ("x-warc-date", r.date);
                ("x-warc-uri", r.uri) ]
          in
          Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers ~body:r.body ())

(* The pipeline over this replica's archive instead of the web: each page's
   latest record classified again (after a new lexicon, calibration or
   model), its refresh state taking the new pipeline version. Images and T4
   still go out as for a fetch; the page itself is not fetched. *)
let replay st =
  let started = Unix.gettimeofday () in
  let* records = Web.detach st.pool (fun () -> Archive.latest st.archive) () in
  let read = Unix.gettimeofday () -. started in
  let* n =
    Lwt_list.fold_left_s
      (fun n (rec_ : Warc.record) ->
        Lwt.catch
          (fun () ->
            let key = Store.normalize rec_.uri in
            let* old, requests = Lab.fresh st.kv key in
            let* h = host_info st rec_.uri in
            let r = { Web.status = rec_.status; content_type = rec_.content_type; body = rec_.body; headers = Warc.header_list rec_ } in
            let* doc = Web.detach st.pool (fun d -> ignore (Lazy.force d.Doc.content); d) (Doc.of_html ~url:rec_.uri rec_.body) in
            let* p = classify st h rec_.uri ~requests doc r in
            let hub = match old with Some o -> o.hub | None -> false in
            let* () = Lab.save_profile ~serve:(not hub) st.kv p in
            let+ () = match old with Some o -> Lab.schedule st.kv ~key ~requests { o with version = st.version } | None -> Lwt.return_unit in
            n + 1)
          (fun _ -> Lwt.return n))
      0 records
  in
  Lab.record_event st.kv ~url:"replay"
    ~outcome:
      (Printf.sprintf "replayed %d archived pages in %.0f s (archive read in %.1f s) [%s]" n
         (Unix.gettimeofday () -. started) read st.replica)

let handler st req body =
  match (Cohttp.Request.meth req, Web.path req) with
  | `GET, "/status" ->
      let* s = Lab.status st.kv ~model:(Option.map (fun l -> l.client.Openrouter.model.id) st.llm) in
      Web.json s
  | `GET, "/pages" ->
      let* l = Lab.summaries st.kv in
      Web.json (`List l)
  | `GET, "/inspect" -> (
      match Web.param req "url" with Some url -> inspect st url | None -> Web.error `Bad_request "url required")
  | `POST, "/crawl" ->
      let* j = Web.body_json body in
      crawl_order st j
  | `POST, "/traffic" -> traffic_order st body
  | `POST, "/coverage" -> Lwt.bind (coverage st body) Fun.id
  | `GET, "/record" -> (
      match Web.param req "url" with Some url -> record st url | None -> Web.error `Bad_request "url required")
  | `POST, "/replay" ->
      Lwt.async (fun () -> replay st);
      Web.json (`Assoc [ ("replaying", `String st.replica) ])
  | `POST, "/sections" ->
      let* added, stored = Lab.backfill_sections st.kv in
      Web.json (`Assoc [ ("added", `Int added); ("stored", `Int stored) ])
  | _ -> Web.error `Not_found "no such route"

(* T4's expected cost per call. Prompts run about 900 tokens, answers 100-250
   with reasoning off (t4eval). Billed cost runs about 2.7x the catalogue
   price of those tokens: providers that keep no prompts (data_collection:
   deny) cost more than the cheapest one listed. *)
let t4_prompt_tokens = 950
let t4_answer_tokens = 250
let t4_billed_over_catalogue = 2.7

let () =
  let port = ref 8081 and data = ref "data" and valkey = ref "valkey://localhost:6379" and workers = ref 8 in
  let model = ref "" and env_file = ref ".env" and sites = ref [] and urls = ref [] and image_patches = ref 256 in
  let news = ref [] and subscription = ref "" and audit = ref false and warc = ref "store/warc" and warc_cap = ref 8 in
  Arg.parse
    [ ("--port", Arg.Set_int port, "PORT admin API port (8081)");
      ("--data", Arg.Set_string data, "DIR taxonomy, lexicon, embedding model (data)");
      ("--valkey", Arg.Set_string valkey, "URI valkey://host:port or sentinel://host:port/name (valkey://localhost:6379)");
      ("--workers", Arg.Set_int workers, "N concurrent fetches (8)");
      ("--site", Arg.String (fun s -> sites := s :: !sites), "URL discover a site through its sitemaps");
      ("--news", Arg.String (fun s -> news := s :: !news), "URL queue the site's pages of the last 48 h, rescanned every 10 min");
      ("--pubsub", Arg.Set_string subscription, "projects/P/subscriptions/S crawl requests from the bidder's profile misses");
      ("--llm", Arg.Set_string model, "MODEL enables T4 with this OpenRouter model id");
      ("--env", Arg.Set_string env_file, "FILE holding OPENROUTER_API_KEY=... (.env)");
      ("--image-patches", Arg.Set_int image_patches, "N SigLIP 2 patch budget per image, 0 for no image tier (256)");
      ("--audit", Arg.Set audit, " also store the deep level (every tier, nothing settles): golden sets and audits");
      ("--warc", Arg.Set_string warc, "DIR raw pages as WARC files, this replica's (store/warc)");
      ("--warc-cap", Arg.Set_int warc_cap, "GIB oldest WARC files deleted beyond this (8)") ]
    (fun u -> urls := u :: !urls)
    "crawler [options] [url ...]";
  let engine = Engine.load ~vision:(!image_patches > 0) ~max_patches:!image_patches !data in
  let llm =
    if !model = "" then None
    else
      let key = Openrouter.key ~env_file:!env_file in
      let m = Lwt_main.run (Openrouter.find_model !model) in
      let cost =
        t4_billed_over_catalogue *. Openrouter.expected_cost m ~prompt_tokens:t4_prompt_tokens ~answer_tokens:t4_answer_tokens
      in
      Printf.printf "T4: %s, about $%.6f per call\n%!" m.id cost;
      Some { client = { key; model = m }; cost }
  in
  (* In Kubernetes HOSTNAME is the pod name; elsewhere host:pid tells local replicas apart. *)
  let replica =
    match Sys.getenv_opt "KUBERNETES_SERVICE_HOST", Sys.getenv_opt "HOSTNAME" with
    | Some _, Some pod -> pod
    | _ -> Printf.sprintf "%s:%d" (Unix.gethostname ()) (Unix.getpid ())
  in
  let st =
    { engine; llm; pool = Web.setup_pool (); kv = Valkey.create !valkey; replica; hosts = Hashtbl.create 64;
      licenses = Hashtbl.create 16; audit = !audit;
      version = Engine.version ?t4:(Option.map (fun l -> l.client.Openrouter.model.id) llm) engine;
      archive = Archive.create ~dir:!warc ~cap:(!warc_cap lsl 30) ~replica () }
  in
  Lwt_main.run
    (let* stored = Valkey.int st.kv [ "ZCARD"; Lab.k "profiles" ] in
     Printf.printf "replica %s, %d profiles in %s, pipeline version %s\n%!" replica stored !valkey st.version;
     let* _ = Lwt_list.map_s (fun u -> enqueue st u) (List.rev !urls) in
     List.iter (fun site -> discover_async st ~site ~max_pages:30) !sites;
     if !news <> [] then Lwt.async (fun () -> watch_news st (List.rev !news));
     if !subscription <> "" then Lwt.async (fun () -> consume_crawl_requests st !subscription);
     Lwt.async (fun () -> housekeeping st);
     Lwt.async (fun () -> refresh_loop st);
     for _ = 1 to !workers do
       Lwt.async (fun () -> worker st)
     done;
     Web.serve ~port:!port (handler st))
