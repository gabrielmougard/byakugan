(* The Placement Lab's shared state in Valkey, so that any number of crawler
   and online replicas cooperate. Keys (prefix "ctx:"):

     seen                set     normalised URL keys ever queued
     frontier:<origin>   zset    URLs waiting for that origin, score = minus bid
                                 requests per day (0 when not in the bid logs)
     hosts               zset    origins with work, score = earliest next fetch (ms)
     hints               hash    URL -> sitemap hints (JSON), while queued
     inflight            hash    URL -> "<origin>\t<claim time ms>\t<frontier score>"
     stats               hash    queued, ok, failed, llm_calls, llm_errors, llm_spent
     recent              list    last 100 outcomes (JSON)
     replicas            zset    crawler id -> last heartbeat (s)
     crawled_by          hash    crawler id -> pages crawled
     profile:<key>       string  Profile JSON, zstd-compressed
     profiles            zset    key -> fetched_at
     summary             hash    key -> page summary (JSON), with its serving labels
     section:<prefix>    hash    "#pages" -> pages, label -> sum of their serving scores
     fresh               hash    key -> refresh state (Refresh.state JSON)
     refresh             zset    key -> when to fetch the page again (ms); pages with traffic only
     requests            hash    key -> bid requests per day, the latest known
     warc, warcfile:<f>  hash, set  where each page's raw record is (Archive)
     slotmap:<version>:<template>  hash  "<ad id> <key>" -> main blocks before it, 30 days
     robots:<origin>     string  robots.txt body, 24 h (RFC 9309 §2.4)
     license:<url>       string  RSL document, for its max-age
     image:<patches>:<sha256(src)>  string  SigLIP 2 embedding, float32 LE, 30 days
     adjudication        hash    URL -> golden-set judgement (JSON), from the lab

   Beside them, without the prefix, the key the bidder reads:

     contextual:<sha256>  string  protobuf PageProfile, 30 days (Url_key.serving_key)
     contextual:section:<sha256(prefix)>  string  the same for a top section or a
                          site, the mean of its pages, from 5 pages on (Store.section_key)

   Politeness is global: an origin is claimed by one worker at a time and
   becomes claimable again only at its next allowed time, whichever replica
   fetched it last. Among the origins due, the busiest next page goes first.
   Every multi-key step is one Lua script, so it is atomic. One URL's cycle:

     enqueue   a new URL (or a forced one) joins frontier:<origin>;
               hosts[origin] = now if the origin is absent
     claim     of the due origins (hosts <= now, 64 at most), the busiest head:
               ZPOPMIN its frontier, hosts[origin] = now + lease (120 s),
               inflight[URL] = origin, claim time, score
     release   once fetched, before classification: hosts[origin] = now + delay
               (the crawler's max(1 s, Crawl-delay))
     finish    once stored or failed: inflight[URL] removed, counters, recent
     reap      any replica, every 10 s: a claim older than the lease goes back
               to its frontier, and the origin is due again *)

open Lwt.Syntax

let p = "ctx:"
let k s = p ^ s
let none = "\000none" (* cached "nothing there" (a robots.txt 404, a missing license) *)

(* A URL already seen is not queued again, but if it is still waiting, a
   higher priority (lower score) moves it up. *)
let enqueue_script =
  {|-- KEYS: seen, hosts, frontier:<origin>, hints, stats
-- ARGV: url key, url, origin, now ms, force (1/0), hints JSON, frontier score
if redis.call('SADD', KEYS[1], ARGV[1]) == 0 and ARGV[5] ~= '1' then
  redis.call('ZADD', KEYS[3], 'XX', 'LT', ARGV[7], ARGV[2])
  return 0
end
if redis.call('ZADD', KEYS[3], 'LT', ARGV[7], ARGV[2]) == 1 then redis.call('HINCRBY', KEYS[5], 'queued', 1) end
if ARGV[6] ~= '' then redis.call('HSET', KEYS[4], ARGV[2], ARGV[6]) end
redis.call('ZADD', KEYS[2], 'NX', ARGV[4], ARGV[3])
return 1|}

(* Of the due origins, the one whose next URL has the most traffic (ties:
   the earliest due), and that URL; the origin is leased until [release].
   Origins whose queue ran dry are dropped once their politeness window has
   passed, so a newly queued URL cannot cut it short.
   shortcut: looks at 64 due origins per claim; keep a zset of due origins
   scored by their head if the lab ever has thousands of origins waiting. *)
let claim_script =
  {|-- KEYS: hosts, hints, inflight, stats    ARGV: now ms, lease ms, key prefix
local best, best_score
for _, origin in ipairs(redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', ARGV[1], 'LIMIT', 0, 64)) do
  local head = redis.call('ZRANGE', ARGV[3] .. 'frontier:' .. origin, 0, 0, 'WITHSCORES')
  if #head == 0 then
    redis.call('ZREM', KEYS[1], origin)
  elseif not best or tonumber(head[2]) < best_score then
    best, best_score = origin, tonumber(head[2])
  end
end
if not best then return false end
local item = redis.call('ZPOPMIN', ARGV[3] .. 'frontier:' .. best)
redis.call('ZADD', KEYS[1], ARGV[1] + ARGV[2], best)
redis.call('HINCRBY', KEYS[4], 'queued', -1)
redis.call('HSET', KEYS[3], item[1], best .. '\t' .. ARGV[1] .. '\t' .. item[2])
local hints = redis.call('HGET', KEYS[2], item[1]) or ''
redis.call('HDEL', KEYS[2], item[1])
return {best, item[1], hints, item[2]}|}

(* Claims older than the lease belong to a crawler that died: queue them again. *)
let reap_script =
  {|-- KEYS: inflight, hosts, stats    ARGV: now ms, lease ms, key prefix
local n = 0
local all = redis.call('HGETALL', KEYS[1])
for i = 1, #all, 2 do
  local origin, at, score = string.match(all[i + 1], '^(.*)\t(%d+)\t(.*)$')
  if origin and tonumber(at) + tonumber(ARGV[2]) < tonumber(ARGV[1]) then
    redis.call('HDEL', KEYS[1], all[i])
    if redis.call('ZADD', ARGV[3] .. 'frontier:' .. origin, 'NX', score, all[i]) == 1 then
      redis.call('HINCRBY', KEYS[3], 'queued', 1)
    end
    redis.call('ZADD', KEYS[2], 'NX', ARGV[1], origin)
    n = n + 1
  end
end
return n|}

let now_ms () = Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.)
let eval kv script keys args = Valkey.command kv ([ "EVAL"; script; string_of_int (List.length keys) ] @ keys @ args)

(* [requests]: bid requests per day for the page; busier pages go first. *)
let enqueue kv ?(requests = 0.) ~key ~url ~origin ~hints ~force () =
  let hints = match hints with [] -> "" | h -> Yojson.Safe.to_string (`List (List.map (fun s -> `String s) h)) in
  let+ r =
    eval kv enqueue_script
      [ k "seen"; k "hosts"; k ("frontier:" ^ origin); k "hints"; k "stats" ]
      [ key; url; origin; now_ms (); (if force then "1" else "0"); hints; (if requests > 0. then Printf.sprintf "-%.0f" requests else "0") ]
  in
  r = Valkey.Int 1

let lease_ms = 120_000

let claim kv =
  let+ r = eval kv claim_script [ k "hosts"; k "hints"; k "inflight"; k "stats" ] [ now_ms (); string_of_int lease_ms; p ] in
  match r with
  | Valkey.Arr [ Str origin; Str url; Str hints; Str score ] ->
      let hints =
        if hints = "" then []
        else match Yojson.Safe.from_string hints with `List l -> List.filter_map (function `String s -> Some s | _ -> None) l | _ -> []
      in
      (* The frontier score is minus the page's bid requests per day. *)
      Some (origin, url, hints, Float.max 0. (-.Option.value (float_of_string_opt score) ~default:0.))
  | _ -> None

(* After the fetch: the origin may be claimed again [delay] seconds from now. *)
let release kv ~origin ~delay =
  Valkey.run kv [ "ZADD"; k "hosts"; Printf.sprintf "%.0f" ((Unix.gettimeofday () +. delay) *. 1000.); origin ]

let reap kv = eval kv reap_script [ k "inflight"; k "hosts"; k "stats" ] [ now_ms (); string_of_int lease_ms; p ]

let record_event kv ~url ~outcome =
  let event = Yojson.Safe.to_string (`Assoc [ ("url", `String url); ("outcome", `String outcome); ("at", `Float (Unix.gettimeofday ())) ]) in
  let* () = Valkey.run kv [ "LPUSH"; k "recent"; event ] in
  Valkey.run kv [ "LTRIM"; k "recent"; "0"; "99" ]

let finish kv ~replica ~url ~outcome ~ok =
  let* () = Valkey.run kv [ "HDEL"; k "inflight"; url ] in
  let* () = Valkey.run kv [ "HINCRBY"; k "stats"; (if ok then "ok" else "failed"); "1" ] in
  let* () = if ok then Valkey.run kv [ "HINCRBY"; k "crawled_by"; replica; "1" ] else Lwt.return_unit in
  record_event kv ~url ~outcome

let heartbeat kv ~replica = Valkey.run kv [ "ZADD"; k "replicas"; Printf.sprintf "%.0f" (Unix.gettimeofday ()); replica ]

let llm_call kv ~cost ~ok =
  let* () = Valkey.run kv [ "HINCRBY"; k "stats"; (if ok then "llm_calls" else "llm_errors"); "1" ] in
  Valkey.run kv [ "HINCRBYFLOAT"; k "stats"; "llm_spent"; Printf.sprintf "%.9f" cost ]

let serving_ttl = string_of_int (30 * 86400)

let save_serving kv (pr : Contextual.Profile.t) =
  match (Contextual.Url_key.serving_key pr.url, Contextual.Profile.serving pr) with
  | Ok key, Some body -> Valkey.run kv [ "SET"; key; body; "EX"; serving_ttl ]
  | _ -> Lwt.return_unit

(* Section and site profiles (Store.sections), kept page by page: each save
   adds the page's serving scores to its prefixes' running sums, minus what
   it added when last crawled, in one atomic script per page.
   shortcut: a page counts until it is recrawled, however old; a time window
   or a decay if sections drift from what they publish now. *)
let section_script =
  {|-- KEYS: section:<prefix>...   ARGV: pages to add (1 new page, 0 recrawl), then label, score delta pairs
local out = {}
for i, key in ipairs(KEYS) do
  redis.call('HINCRBY', key, '#pages', ARGV[1])
  for j = 2, #ARGV, 2 do
    if math.abs(tonumber(redis.call('HINCRBYFLOAT', key, ARGV[j], ARGV[j + 1]))) < 1e-6 then
      redis.call('HDEL', key, ARGV[j])
    end
  end
  out[i] = redis.call('HGETALL', key)
end
return out|}

let min_section_pages = 5

(* [old]: the labels the page added last time, None if it never added any. *)
let add_to_sections kv (pr : Contextual.Profile.t) ~old =
  match Contextual.Store.sections pr.url with
  | [] -> Lwt.return_unit
  | prefixes -> (
      let labels = Contextual.Profile.serving_labels pr and before = Option.value old ~default:[] in
      let ids = List.sort_uniq compare (List.map fst labels @ List.map fst before) in
      let score l id = Option.value (List.assoc_opt id l) ~default:0. in
      let deltas = List.concat_map (fun id -> [ id; Printf.sprintf "%.9g" (score labels id -. score before id) ]) ids in
      let* r =
        eval kv section_script (List.map (fun p -> k ("section:" ^ p)) prefixes) ((if old = None then "1" else "0") :: deltas)
      in
      match r with
      | Valkey.Arr hashes when List.length hashes = List.length prefixes ->
          Lwt_list.iter_s
            (fun (prefix, hash) ->
              let rec pairs = function
                | Valkey.Str f :: Valkey.Str v :: rest -> (f, float_of_string v) :: pairs rest
                | _ -> []
              in
              let fields = match hash with Valkey.Arr l -> pairs l | _ -> [] in
              let pages = int_of_float (Option.value (List.assoc_opt "#pages" fields) ~default:0.) in
              if pages < min_section_pages then Lwt.return_unit
              else
                let labels = Contextual.Profile.mean_labels ~pages (List.remove_assoc "#pages" fields) in
                let body = Contextual.Profile.encode ~labels ~keywords:[] ~fetched_at:(Unix.gettimeofday ()) ~version:pr.version () in
                Valkey.run kv [ "SET"; Contextual.Store.section_key prefix; body; "EX"; serving_ttl ])
            (List.combine prefixes hashes)
      | Valkey.Err e -> Lwt.fail_with e
      | _ -> Lwt.fail_with "section script: unexpected reply")

let pairs_json l = `List (List.map (fun (id, s) -> `List [ `String id; `Float s ]) l)

let labels_of_summary j =
  match Yojson.Safe.Util.member "labels" j with
  | `List l -> Some (List.filter_map (function `List [ `String id; s ] -> Option.map (fun s -> (id, s)) (Yojson.Safe.Util.to_number_option s) | _ -> None) l)
  | _ -> None

let summary (p : Contextual.Profile.t) =
  `Assoc
    [ ("url", `String p.url); ("key", `String p.key); ("site", `String p.site); ("title", `String p.title);
      ("fetched_at", `Float p.fetched_at); ("segments", `Int (List.length p.segments));
      ("labels", pairs_json (Contextual.Profile.serving_labels p)) ]

(* [serve]: false for a hub (Refresh), whose page key is dropped so that
   the bidder backs off to its section or site. *)
let save_profile ?(serve = true) kv (pr : Contextual.Profile.t) =
  let* old = Valkey.string_opt kv [ "HGET"; k "summary"; pr.key ] in
  let json = Yojson.Safe.to_string (Contextual.Profile.to_json pr) in
  let* () = Valkey.run kv [ "SET"; k ("profile:" ^ pr.key); Contextual.Zstd.compress json ] in
  let* () =
    if serve then save_serving kv pr
    else match Contextual.Url_key.serving_key pr.url with Ok key -> Valkey.run kv [ "DEL"; key ] | Error _ -> Lwt.return_unit
  in
  let* () = add_to_sections kv pr ~old:(Option.bind old (fun s -> labels_of_summary (Yojson.Safe.from_string s))) in
  let* () = Valkey.run kv [ "HSET"; k "summary"; pr.key; Yojson.Safe.to_string (summary pr) ] in
  Valkey.run kv [ "ZADD"; k "profiles"; Printf.sprintf "%.6f" pr.fetched_at; pr.key ]

let profile kv key =
  let+ v = Valkey.string_opt kv [ "GET"; k ("profile:" ^ key) ] in
  Option.map Contextual.Zstd.decompress_if_framed v

(* (key, fetched_at) for every stored profile. *)
let profile_index kv =
  let+ l = Valkey.strings kv [ "ZRANGE"; k "profiles"; "0"; "-1"; "WITHSCORES" ] in
  let rec pairs = function Some key :: Some at :: rest -> (key, float_of_string at) :: pairs rest | _ -> [] in
  pairs l

let profiles kv keys =
  match keys with
  | [] -> Lwt.return []
  | _ ->
      let+ l = Valkey.strings kv ("MGET" :: List.map (fun key -> k ("profile:" ^ key)) keys) in
      List.map (Option.map Contextual.Zstd.decompress_if_framed) l

let rec chunks n = function [] -> [] | l -> List.filteri (fun i _ -> i < n) l :: chunks n (List.filteri (fun i _ -> i >= n) l)

(* Refresh (Contextual.Refresh): a page's state, its bid requests per day,
   and when to fetch it again. *)
let fresh kv key =
  let* state = Valkey.string_opt kv [ "HGET"; k "fresh"; key ] in
  let+ requests = Valkey.string_opt kv [ "HGET"; k "requests"; key ] in
  ( Option.map (fun s -> Contextual.Refresh.of_json (Yojson.Safe.from_string s)) state,
    Option.value (Option.bind requests float_of_string_opt) ~default:0. )

let schedule kv ~key ~requests (s : Contextual.Refresh.state) =
  let now = Unix.gettimeofday () in
  let* () = Valkey.run kv [ "HSET"; k "fresh"; key; Yojson.Safe.to_string (Contextual.Refresh.to_json s) ] in
  let* () = if requests > 0. then Valkey.run kv [ "HSET"; k "requests"; key; Printf.sprintf "%g" requests ] else Lwt.return_unit in
  if requests > 0. then
    Valkey.run kv [ "ZADD"; k "refresh"; Printf.sprintf "%.0f" ((now +. Contextual.Refresh.interval ~now s) *. 1000.); key ]
  else Valkey.run kv [ "ZREM"; k "refresh"; key ]

(* An unchanged page keeps its serving keys, and its section's and site's,
   another 30 days. *)
let touch kv url =
  let keys =
    (match Contextual.Url_key.serving_key url with Ok key -> [ key ] | Error _ -> [])
    @ List.map Contextual.Store.section_key (Contextual.Store.sections url)
  in
  Lwt_list.iter_s (fun key -> Valkey.run kv [ "EXPIRE"; key; serving_ttl ]) keys

let due_script =
  {|-- KEYS: refresh   ARGV: now ms, limit
local keys = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', ARGV[1], 'LIMIT', 0, ARGV[2])
if #keys > 0 then redis.call('ZREM', KEYS[1], unpack(keys)) end
return keys|}

(* Pages due for a refresh, each handed to one replica: (url, requests). A
   page stored before refresh existed has no state yet: its summary has the URL. *)
let due kv ~limit =
  let* r = eval kv due_script [ k "refresh" ] [ now_ms (); string_of_int limit ] in
  let keys = match r with Valkey.Arr l -> List.filter_map (function Valkey.Str s -> Some s | _ -> None) l | _ -> [] in
  Lwt_list.filter_map_s
    (fun key ->
      let* state, requests = fresh kv key in
      match state with
      | Some s -> Lwt.return_some (s.url, requests)
      | None ->
          let+ summary = Valkey.string_opt kv [ "HGET"; k "summary"; key ] in
          Option.bind summary (fun s ->
              Option.map (fun url -> (url, requests)) Yojson.Safe.Util.(to_string_option (member "url" (Yojson.Safe.from_string s)))))
    keys

let traffic_script =
  {|-- KEYS: requests, profiles, refresh   ARGV: now ms, then key, requests pairs
for i = 2, #ARGV, 2 do
  redis.call('HSET', KEYS[1], ARGV[i], ARGV[i + 1])
  if redis.call('ZSCORE', KEYS[2], ARGV[i]) and not redis.call('ZSCORE', KEYS[3], ARGV[i]) then
    redis.call('ZADD', KEYS[3], ARGV[1], ARGV[i])
  end
end
return 0|}

(* Bid-log traffic per page key: kept for the value budget, and a stored page
   not on the refresh schedule yet (crawled before it existed) is due now. *)
let note_traffic kv pairs =
  Lwt_list.iter_s
    (fun chunk ->
      let+ _ =
        eval kv traffic_script [ k "requests"; k "profiles"; k "refresh" ]
          (now_ms () :: List.concat_map (fun (key, r) -> [ key; Printf.sprintf "%g" r ]) chunk)
      in
      ())
    (chunks 500 pairs)

(* Where a page's latest raw record is (Archive): replica, file, offset, length. *)
let warc_entry kv key =
  let+ v = Valkey.string_opt kv [ "HGET"; k "warc"; key ] in
  Option.bind v (fun s ->
      let module J = Yojson.Safe.Util in
      let j = Yojson.Safe.from_string s in
      match (J.member "replica" j, J.member "file" j, J.member "offset" j, J.member "length" j) with
      | `String r, `String f, `Int o, `Int l -> Some (r, f, o, l)
      | _ -> None)

(* Ad slot positions per template (Store.template) and pipeline version:
   slotmap:<version>:<template> is a hash, "<element id> <page key>" -> main
   blocks before the slot. One field per page and slot, so a page fetched
   or replayed again counts once; at most 400 fields, enough for a mean;
   gone 30 days after the last write, or when the extraction changes. A
   page whose HTML lacks its slots (injected by script) gets the template's
   usual ones: those seen on at least 2 pages, at their mean position.

     slotmap:f04f9d22:news.example/sport#3
       "ad-top news.example/sport/football/a" -> 0
       "ad-top news.example/sport/football/b" -> 1
       "ad-mid news.example/sport/football/b" -> 5
     learned_slots = [("ad-top", 1)]   (2 pages, mean 0.5 rounded up) *)
let slotmap ~version template = k (Printf.sprintf "slotmap:%s:%s" version template)

let learn_slots kv ~version ~template ~page slots =
  if template = "" || slots = [] then Lwt.return_unit
  else
    let key = slotmap ~version template in
    let* n = Valkey.int kv [ "HLEN"; key ] in
    if n >= 400 then Lwt.return_unit
    else
      let* () =
        Valkey.run kv ("HSET" :: key :: List.concat_map (fun (id, before) -> [ id ^ " " ^ page; string_of_int before ]) slots)
      in
      Valkey.run kv [ "EXPIRE"; key; serving_ttl ]

let learned_slots kv ~version ~template =
  if template = "" then Lwt.return []
  else
    let+ l = Valkey.strings kv [ "HGETALL"; slotmap ~version template ] in
    let rec pairs = function Some a :: Some b :: rest -> (a, b) :: pairs rest | _ -> [] in
    let tally = Hashtbl.create 8 in
    List.iter
      (fun (field, v) ->
        match String.index_opt field ' ' with
        | Some i ->
            let id = String.sub field 0 i in
            let n, sum = Option.value (Hashtbl.find_opt tally id) ~default:(0, 0) in
            Hashtbl.replace tally id (n + 1, sum + int_of_string v)
        | None -> ())
      (pairs l);
    Hashtbl.fold (fun id (n, sum) acc -> if n >= 2 then (id, (sum + (n / 2)) / n) :: acc else acc) tally []
    |> List.sort (fun (a, x) (b, y) -> compare (x, a) (y, b))

(* Pages stored before sections existed: their summary has no labels. Each
   is added once and its summary rewritten, so a second run adds nothing;
   two runs at once would count pages twice. *)
let backfill_sections kv =
  let* index = profile_index kv in
  let keys = List.map fst index in
  let* added =
    Lwt_list.map_s
      (fun chunk ->
        let* summaries = Valkey.strings kv ("HMGET" :: k "summary" :: chunk) in
        let todo =
          List.filter_map
            (fun (key, s) ->
              match s with
              | Some s when labels_of_summary (Yojson.Safe.from_string s) <> None -> None
              | _ -> Some key)
            (List.combine chunk summaries)
        in
        let* bodies = profiles kv todo in
        let+ n =
          Lwt_list.fold_left_s
            (fun n body ->
              match body with
              | None -> Lwt.return n
              | Some b ->
                  let pr = Contextual.Profile.of_json (Yojson.Safe.from_string b) in
                  let* () = add_to_sections kv pr ~old:None in
                  let+ () = Valkey.run kv [ "HSET"; k "summary"; pr.key; Yojson.Safe.to_string (summary pr) ] in
                  n + 1)
            0 bodies
        in
        n)
      (chunks 100 keys)
  in
  Lwt.return (List.fold_left ( + ) 0 added, List.length keys)

(* Which of [keys] have a stored profile, in order. *)
let stored kv keys =
  let+ found =
    Lwt_list.map_s (fun chunk -> Valkey.strings kv ("ZMSCORE" :: k "profiles" :: chunk)) (chunks 1000 keys)
  in
  Array.of_list (List.map Option.is_some (List.concat found))

let summaries kv =
  let+ l = Valkey.strings kv [ "HVALS"; k "summary" ] in
  List.filter_map (Option.map Yojson.Safe.from_string) l

let field_int fields name = match List.assoc_opt name fields with Some v -> int_of_string_opt v |> Option.value ~default:0 | None -> 0
let field_float fields name = match List.assoc_opt name fields with Some v -> float_of_string_opt v |> Option.value ~default:0. | None -> 0.

let hash kv key =
  let+ l = Valkey.strings kv [ "HGETALL"; k key ] in
  let rec pairs = function Some a :: Some b :: rest -> (a, b) :: pairs rest | _ -> [] in
  pairs l

let status kv ~model =
  let* stats = hash kv "stats" in
  let* in_flight = Valkey.int kv [ "HLEN"; k "inflight" ] in
  let* stored = Valkey.int kv [ "ZCARD"; k "profiles" ] in
  let* recent = Valkey.strings kv [ "LRANGE"; k "recent"; "0"; "99" ] in
  let* crawled = hash kv "crawled_by" in
  let+ alive =
    Valkey.strings kv [ "ZRANGEBYSCORE"; k "replicas"; Printf.sprintf "%.0f" (Unix.gettimeofday () -. 30.); "+inf" ]
  in
  let replica id = `Assoc [ ("id", `String id); ("crawled", `Int (field_int crawled id)) ] in
  `Assoc
    [ ("queued", `Int (field_int stats "queued")); ("in_flight", `Int in_flight); ("ok", `Int (field_int stats "ok"));
      ("failed", `Int (field_int stats "failed")); ("stored", `Int stored);
      ("recent", `List (List.filter_map (Option.map Yojson.Safe.from_string) recent));
      ("replicas", `List (List.map replica (List.filter_map Fun.id alive)));
      ( "llm",
        match model with
        | Some m ->
            `Assoc
              [ ("model", `String m); ("calls", `Int (field_int stats "llm_calls"));
                ("errors", `Int (field_int stats "llm_errors")); ("spent_usd", `Float (field_float stats "llm_spent")) ]
        | None -> `Null ) ]

(* Image embeddings by image URL and patch budget, as little-endian float32
   (the C runtime computes in f32, so a cached embedding is the one it would
   recompute): 3 KB each, 30 days. An image that will never embed (too
   small, undecodable) is cached as missing. Worth caching: a hero image is
   on its article, its section and the home page. *)
let image_key ~max_patches src = Printf.sprintf "image:%d:%s" max_patches Digestif.SHA256.(to_hex (digest_string src))

let encode_floats a =
  let b = Bytes.create (4 * Array.length a) in
  Array.iteri (fun i x -> Bytes.set_int32_le b (4 * i) (Int32.bits_of_float x)) a;
  Bytes.unsafe_to_string b

let decode_floats s = Array.init (String.length s / 4) (fun i -> Int32.float_of_bits (String.get_int32_le s (4 * i)))

(* A cached document: Some (Some body), Some None for a cached absence, None
   when the cache has nothing. *)
let cached kv key =
  let+ v = Valkey.string_opt kv [ "GET"; k key ] in
  Option.map (fun v -> if v = none then None else Some v) v

let cache kv key ~ttl body =
  Valkey.run kv [ "SET"; k key; Option.value body ~default:none; "EX"; string_of_int (max 1 ttl) ]
