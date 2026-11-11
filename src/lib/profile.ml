(* What the crawler stores per URL and the online server reads back: one
   cascade result per depth preset (so the same page can be compared at every
   level), labelled segments with an estimated position on screen, the ad
   containers and each story's labels. [serving] is the bidder's smaller
   view of it. *)

type segment = {
  tag : string;
  text : string;
  main : bool;
  top : float; (* viewports from the top of the page *)
  height : float; (* viewports *)
  labels : (Ontology.id * float) list;
  simhash : int64; (* of the block's words (Refresh.simhash); 0 under 20 characters *)
  article : int; (* the story it belongs to (Doc.segment), 0 for none *)
}

type level = { preset : string; result : Cascade.result }

type t = {
  url : string;
  key : string;
  site : string;
  title : string;
  fetched_at : float;
  keywords : string list;
  levels : level list;
  segments : segment list;
  t4_gate : string; (* whether page text may go to T4, and why (Ai_use) *)
  version : string; (* pipeline version (Engine.version), "" when stored without one *)
  ad_slots : ad_slot list; (* where the template puts its ads *)
  articles : (int * (Ontology.id * float) list) list; (* each story's own labels, by Doc.segment.article *)
}

(* An ad container by its element id (the end of a GPID), before segment
   [index]; [learned] when the page's HTML lacked it and the template's
   usual position stands in (lazily injected slots). *)
and ad_slot = { id : string; index : int; learned : bool }

let viewport_px = 700.

(* shortcut: heights estimated from text length on a 390px-wide phone, not
   rendered. The Prebid module (sdks/prebid) sends measured offsets per
   request and the lab's Page view measures them; the served profile could
   carry them once enough requests have logged them
   (study/context_boundary.md §5). *)
let height_px tag text =
  let lines per = Float.ceil (float (max 1 (String.length text)) /. per) in
  match tag with
  | "h1" -> (lines 20. *. 36.) +. 20.
  | "h2" | "h3" -> (lines 28. *. 28.) +. 16.
  | "img" -> 240.
  | "iframe" | "video" -> 220.
  | _ -> (lines 42. *. 24.) +. 16.

let layout (segments : Doc.segment list) labels =
  let y = ref 0. in
  List.map2
    (fun (s : Doc.segment) labels ->
      let height = height_px s.tag s.text /. viewport_px in
      let top = !y in
      y := !y +. height;
      let simhash = if String.length s.text >= 20 then Refresh.simhash s.text else 0L in
      { tag = s.tag; text = s.text; main = s.main; top; height; labels; simhash; article = s.article })
    segments labels

(* Geometry measured where the page was rendered (the lab's frame, a Prebid
   module): (segment index, top, height) in viewports replaces the estimate. *)
let measured t geometry =
  let at = Hashtbl.create (List.length geometry) in
  List.iter (fun (i, top, height) -> Hashtbl.replace at i (top, height)) geometry;
  { t with
    segments =
      List.mapi
        (fun i s -> match Hashtbl.find_opt at i with Some (top, height) -> { s with top; height } | None -> s)
        t.segments }

let site_of url = List.hd (String.split_on_char '/' (Store.normalize url))

let level t preset = List.find_opt (fun l -> l.preset = preset) t.levels

module Pb = Protos.Profile.Contextual.V1

let first n l = List.filteri (fun i _ -> i < n) l

(* What the bidder reads (src/protos/contextual/v1/profile.proto): the "rich"
   level's labels and the keywords, protobuf-encoded. "rich" is the deepest
   production depth; "deep" is for audits (nothing freezes, so without T4
   the dense tier overrides the lexicon's verdicts). *)
let serving_preset = "rich"

let by_score l = List.stable_sort (fun (_, a) (_, b) -> compare b a) l

(* The labels the bidder gets: highest first, at most 20. *)
let serving_labels t =
  match level t serving_preset with
  | None -> []
  | Some l -> first 20 (by_score (List.map (fun (l : Label.t) -> (l.id, l.score)) l.result.labels))

(* The labelled blocks the bidder matches a slot's neighbours against. *)
let max_blocks = 64

let blocks t =
  List.filter (fun s -> s.simhash <> 0L && s.labels <> []) t.segments
  |> first max_blocks
  |> List.map (fun s -> (s.simhash, s.main, first 8 (by_score s.labels), s.top +. (s.height /. 2.)))

(* Where each ad container sits: the bottom of the block before it. *)
let ad_tops t =
  let segs = Array.of_list t.segments in
  List.map
    (fun a -> (a.id, if a.index <= 0 then 0. else let s = segs.(min (Array.length segs - 1) (a.index - 1)) in s.top +. s.height))
    (List.filter (fun a -> a.index <= Array.length segs) t.ad_slots)

(* A slot's surroundings from the GPID alone ("/1234/home#div-gpt-ad-top"):
   the 12 blocks nearest its ad container, within 3 viewports, as a Prebid
   module would send them: (SimHash, offset from the container). None when
   the page has no such container. With the container at 1.0 and blocks
   h1, h2, h3 centred at 0.5, 1.8 and 5.0: Some [ (h1, -0.5); (h2, 0.8) ].
   sdks/go SlotOfGPID does the same from the served profile. *)
let gpid_slot ~tops ~blocks gpid =
  let id = match String.rindex_opt gpid '#' with Some i -> String.sub gpid (i + 1) (String.length gpid - i - 1) | None -> gpid in
  match List.assoc_opt id tops with
  | None -> None
  | Some y ->
      List.filter_map (fun (h, _, _, top) -> let d = top -. y in if Float.abs d <= 3. then Some (h, d) else None) blocks
      |> List.stable_sort (fun (_, a) (_, b) -> compare (Float.abs a) (Float.abs b))
      |> first 12 |> Option.some

(* The serving profile, at contextual:<sha256> of the normalised URL
   (Url_key.serving_key); src/protos/contextual/v1/profile.proto:

     PageProfile
     ├─ labels      <= 20  (id, score), highest first, ancestors included
     ├─ keywords    <= 20
     ├─ fetched_at         Unix seconds
     ├─ preset             "rich"
     ├─ version            Engine.version
     ├─ blocks      <= 64  labelled segments of 20+ characters, in page order
     │    └─ simhash (fixed64), main, top (its middle, viewports),
     │       labels <= 8
     └─ ad_slots           one per ad container
          └─ id (the end of a GPID), top (the bottom of the block
             before it, viewports) *)
let encode ?(blocks = []) ?(ad_slots = []) ~labels ~keywords ~fetched_at ~version () =
  Pb.PageProfile.make
    ~labels:(List.map (fun (id, score) -> Pb.Label.make ~id ~score ()) labels)
    ~keywords:(first 20 keywords) ~fetched_at:(int_of_float fetched_at) ~preset:serving_preset ~version
    ~blocks:
      (List.map
         (fun (simhash, main, labels, top) ->
           Pb.Block.make ~simhash ~main ~top ~labels:(List.map (fun (id, score) -> Pb.Label.make ~id ~score ()) labels) ())
         blocks)
    ~ad_slots:(List.map (fun (id, top) -> Pb.AdSlot.make ~id ~top ()) ad_slots)
    ()
  |> Pb.PageProfile.to_proto |> Ocaml_protoc_plugin.Writer.contents

let serving t =
  match level t serving_preset with
  | None -> None
  | Some _ ->
      Some
        (encode ~blocks:(blocks t) ~ad_slots:(ad_tops t) ~labels:(serving_labels t) ~keywords:t.keywords
           ~fetched_at:t.fetched_at ~version:t.version ())

(* A section's or a site's serving profile (Store.sections) back as a
   profile: the same labels at every [presets] level, no segments, so the
   lab treats an uncrawled page as the bidder would. *)
let of_serving ~presets ~key body =
  let pb = Pb.PageProfile.from_proto_exn (Ocaml_protoc_plugin.Reader.create body) in
  let labels =
    List.map
      (fun (l : Pb.Label.t) ->
        let why = "mean over the pages crawled there" in
        { Label.id = l.id; score = l.score; evidence = [ { Label.tier = "section"; zone = "section"; quote = key; why; weight = l.score } ] })
      pb.labels
  in
  let result = { Cascade.labels; spent = 0.; ran = []; stop = Cascade.Settled } in
  { url = key; key; site = List.hd (String.split_on_char '/' key); title = key; fetched_at = float pb.fetched_at;
    keywords = pb.keywords; levels = List.map (fun preset -> { preset; result }) presets; segments = [];
    t4_gate = "not evaluated"; version = pb.version; ad_slots = []; articles = [] }

(* A section's or a site's labels from the sums of its pages' serving
   scores: the mean over [pages] (a page without the label counts 0),
   highest first, at most 20. Each page lists a label's ancestors with at
   least its score, so the means do too.
   mean_labels ~pages:4 [ ("483", 2.); ("533", 1.2); ("v9i3On", 0.) ]
   = [ ("483", 0.5); ("533", 0.3) ] *)
let mean_labels ~pages sums =
  first 20 (by_score (List.filter_map (fun (id, s) -> if s > 0. then Some (id, s /. float pages) else None) sums))

let stop_of_name = function
  | "settled" -> Cascade.Settled
  | "out of budget" -> Cascade.Out_of_budget
  | _ -> Cascade.Exhausted

let pairs_json l = `List (List.map (fun (id, s) -> `Assoc [ ("id", `String id); ("score", `Float s) ]) l)

let evidence_json (e : Label.evidence) =
  `Assoc
    [ ("tier", `String e.tier); ("zone", `String e.zone); ("quote", `String e.quote); ("why", `String e.why);
      ("weight", `Float e.weight) ]

let label_json (l : Label.t) =
  `Assoc [ ("id", `String l.id); ("score", `Float l.score); ("evidence", `List (List.map evidence_json l.evidence)) ]

let level_json l =
  let r = l.result in
  `Assoc
    [ ("preset", `String l.preset); ("ran", `List (List.map (fun s -> `String s) r.ran)); ("spent", `Float r.spent);
      ("stop", `String (Cascade.stop_name r.stop)); ("labels", `List (List.map label_json r.labels)) ]

let segment_json s =
  `Assoc
    [ ("tag", `String s.tag); ("text", `String s.text); ("main", `Bool s.main); ("top", `Float s.top);
      ("height", `Float s.height); ("labels", pairs_json s.labels);
      ("simhash", `String (Printf.sprintf "%016Lx" s.simhash)); ("article", `Int s.article) ]

let to_json t =
  `Assoc
    [ ("url", `String t.url); ("key", `String t.key); ("site", `String t.site); ("title", `String t.title);
      ("fetched_at", `Float t.fetched_at); ("keywords", `List (List.map (fun k -> `String k) t.keywords));
      ("levels", `List (List.map level_json t.levels)); ("segments", `List (List.map segment_json t.segments));
      ("t4_gate", `String t.t4_gate); ("version", `String t.version);
      ( "ad_slots",
        `List
          (List.map
             (fun a -> `Assoc [ ("id", `String a.id); ("index", `Int a.index); ("learned", `Bool a.learned) ])
             t.ad_slots) );
      ("articles", `List (List.map (fun (a, l) -> `Assoc [ ("article", `Int a); ("labels", pairs_json l) ]) t.articles)) ]

module J = Yojson.Safe.Util

let num j = J.to_number j
let strings j = List.map J.to_string (J.to_list j)
let pairs j = List.map (fun p -> (J.to_string (J.member "id" p), num (J.member "score" p))) (J.to_list j)

let evidence_of j =
  { Label.tier = J.to_string (J.member "tier" j);
    zone = J.to_string (J.member "zone" j);
    quote = J.to_string (J.member "quote" j);
    why = J.to_string (J.member "why" j);
    weight = num (J.member "weight" j) }

let label_of j =
  { Label.id = J.to_string (J.member "id" j);
    score = num (J.member "score" j);
    evidence = List.map evidence_of (J.to_list (J.member "evidence" j)) }

let level_of j =
  { preset = J.to_string (J.member "preset" j);
    result =
      { Cascade.labels = List.map label_of (J.to_list (J.member "labels" j));
        spent = num (J.member "spent" j);
        ran = strings (J.member "ran" j);
        stop = stop_of_name (J.to_string (J.member "stop" j)) } }

let segment_of j =
  { tag = J.to_string (J.member "tag" j);
    text = J.to_string (J.member "text" j);
    main = J.to_bool (J.member "main" j);
    top = num (J.member "top" j);
    height = num (J.member "height" j);
    labels = pairs (J.member "labels" j);
    simhash =
      Option.value
        (Option.bind (J.to_string_option (J.member "simhash" j)) (fun h -> Int64.of_string_opt ("0x" ^ h)))
        ~default:0L;
    article = Option.value (J.to_int_option (J.member "article" j)) ~default:0 }

let of_json j =
  { url = J.to_string (J.member "url" j);
    key = J.to_string (J.member "key" j);
    site = J.to_string (J.member "site" j);
    title = J.to_string (J.member "title" j);
    fetched_at = num (J.member "fetched_at" j);
    keywords = strings (J.member "keywords" j);
    levels = List.map level_of (J.to_list (J.member "levels" j));
    segments = List.map segment_of (J.to_list (J.member "segments" j));
    t4_gate = Option.value (J.to_string_option (J.member "t4_gate" j)) ~default:"not evaluated";
    version = Option.value (J.to_string_option (J.member "version" j)) ~default:"";
    ad_slots =
      (match J.member "ad_slots" j with
      | `List l ->
          List.map
            (fun a ->
              { id = J.to_string (J.member "id" a); index = J.to_int (J.member "index" a);
                learned = J.to_bool (J.member "learned" a) })
            l
      | _ -> []);
    articles =
      (match J.member "articles" j with
      | `List l -> List.map (fun a -> (J.to_int (J.member "article" a), pairs (J.member "labels" a))) l
      | _ -> []) }
