type t = {
  name : string;
  cost : Doc.t -> float; (* expected USD for this page *)
  mode : Label.mode;
  applies : Doc.t -> bool;
  run : Doc.t -> Label.t list -> Label.t list; (* prior labels in, fresh labels out *)
}

(* The default; Engine tunes it per language with the thresholds. *)
let saturation = 4.

(* Score = 1 - exp(-raw / saturation): at 4, one body mention (raw 1) stays
   weak (0.22), a title plus section hit (raw 5.5) is already 0.75. *)
let lexical_labels ?lang ?(saturation = saturation) ~tier onto zones =
  let acc = Hashtbl.create 16 in
  List.iter
    (fun (zone, zone_weight, units) ->
      List.iter
        (fun unit ->
          List.iter
            (fun (id, term, w) ->
              let weight = zone_weight *. w in
              let raw, ev = Option.value (Hashtbl.find_opt acc id) ~default:(0., []) in
              let e = { Label.tier; zone; quote = Text.clip unit; why = Printf.sprintf "term %S" term; weight } in
              Hashtbl.replace acc id (raw +. weight, e :: ev))
            (Ontology.hits ?lang onto unit))
        units)
    zones;
  Hashtbl.fold
    (fun id (raw, ev) out ->
      { Label.id; score = 1. -. exp (-.raw /. saturation); evidence = List.rev ev } :: out)
    acc []

let platt ~a ~b x = 1. /. (1. +. exp (-.((a *. x) +. b)))

(* T0: URL tokens and pre-fetch hints. Costs nothing and never fetches, so it
   can also run inside the bid path for a URL nobody crawled yet; the page's
   language is unknown then, so every term counts. Its saturation is the
   page's language's once the page is parsed. *)
let url_and_hints ?(saturation = fun _ -> saturation) onto =
  { name = "t0-url+hints";
    cost = (fun _ -> 0.);
    mode = Label.Accumulate;
    applies = (fun _ -> true);
    run =
      (fun d _ ->
        let lang = if Lazy.is_val d.Doc.content then (Lazy.force d.content).lang else "" in
        lexical_labels ~saturation:(saturation lang) ~tier:"t0" onto (Doc.pre_fetch_zones d)) }

(* T1: fetch, extract, lexicon over every content zone. [saturation] per
   page language. *)
let lexical ?(cost = 1e-6) ?(saturation = fun _ -> saturation) onto =
  { name = "t1-lexical";
    cost = (fun _ -> cost);
    mode = Label.Accumulate;
    applies = (fun _ -> true);
    run =
      (fun d _ ->
        let c = Lazy.force d.Doc.content in
        lexical_labels ~lang:c.lang ~saturation:(saturation c.lang) ~tier:"t1" onto (Doc.content_zones c)) }

(* T2's view of an embedding model: the cosine of each text (rows) with each
   taxonomy node's prototype (columns, in [ids] order). The engine computes
   it in one batch (Model2vec: ggml); tests use [similarity_of_embed]. *)
type similarity = { ids : Ontology.id array; cosines : string array -> float array array }

(* Prototypes (name + lexicon terms) built eagerly: a lazy forced from two
   domains at once raises. *)
let similarity_of_embed ~embed onto =
  let ids = Array.of_list (Ontology.ids onto) in
  let protos = Array.map (fun id -> embed (String.concat " " (Ontology.name onto id :: Ontology.terms onto id))) ids in
  { ids; cosines = (fun texts -> Array.map (fun t -> Array.map (Vec.cosine (embed t)) protos) texts) }

(* T2: zero-shot against node prototypes, the page and its first 40 units in
   one batch; [similarity] may depend on the page (its language).
   [calibrate d] maps cosine to a probability fitted on a golden set, per
   model, so it too depends on the page. *)
let dense_cosines (sim : similarity) d =
  let units = Array.of_list (List.filteri (fun i _ -> i < 40) (Doc.text_units (Lazy.force d.Doc.content))) in
  (units, sim.cosines (Array.append [| String.concat " " (Array.to_list units) |] units))

let dense ?(cost = 5e-6) ~similarity ~calibrate () =
  let run d _ =
    let sim = similarity d and calibrate = calibrate d in
    let units, cos = dense_cosines sim d in
    Array.to_list
      (Array.mapi
         (fun j id ->
           let page = cos.(0).(j) in
           let score = calibrate page in
           let evidence =
             if score < 0.3 then []
             else
               let best = ref 1 in
               for i = 2 to Array.length cos - 1 do
                 if cos.(i).(j) > cos.(!best).(j) then best := i
               done;
               [ { Label.tier = "t2";
                   zone = "semantic";
                   quote = Text.clip units.(!best - 1);
                   why = Printf.sprintf "page cos %.2f, nearest sentence cos %.2f" page cos.(!best).(j);
                   weight = score } ]
           in
           { Label.id; score; evidence })
         sim.ids)
  in
  { name = "t2-dense";
    cost = (fun _ -> cost);
    mode = Label.Override;
    applies = (fun d -> Doc.text_units (Lazy.force d.Doc.content) <> []);
    run }

(* Pixels cost money: only media no free text describes yet (about half of
   all <img> alts are empty or <= 10 chars), at most 3 per page. *)
let undescribed kinds (d : Doc.t) =
  (Lazy.force d.content).Doc.media
  |> List.filter (fun (m : Doc.media) -> List.mem m.kind kinds && String.length m.text < 20)
  |> List.filteri (fun i _ -> i < 3)

(* T3 for video: a description (the provider's oEmbed title, from
   [describe]) scored by the same lexicon, so a media decision explains
   itself like a text one. *)
let media ?(cost_per_item = 1e-4) ?(zone = "model-text") ?(saturation = fun _ -> saturation) ~kinds ~describe onto =
  { name = "t3-media";
    cost = (fun d -> cost_per_item *. float (List.length (undescribed kinds d)));
    mode = Label.Accumulate;
    applies = (fun d -> undescribed kinds d <> []);
    run =
      (fun d _ ->
        let lang = (Lazy.force d.Doc.content).lang in
        lexical_labels ~lang ~saturation:(saturation lang) ~tier:"t3" onto
          [ (zone, 2.0, List.filter_map describe (undescribed kinds d)) ]) }

(* T3 for pictures: zero-shot on images without usable alt text. [see] gives
   an image's embedding, computed by the crawler before the cascade (None if
   it could not be fetched, decoded, or is too small); [zero_shot] turns it
   into (node, score, why). A node seen in several images keeps its best. *)
let image_cost = 1e-4

let images ?(cost_per_item = image_cost) ~see ~zero_shot () =
  let seen d = List.filter_map (fun (m : Doc.media) -> Option.map (fun e -> (m, e)) (see m)) (undescribed [ Doc.Image ] d) in
  let run d _ =
    let best = Hashtbl.create 16 in
    List.iter
      (fun ((m : Doc.media), e) ->
        List.iter
          (fun (id, score, why) ->
            match Hashtbl.find_opt best id with
            | Some (s, _) when s >= score -> ()
            | _ -> Hashtbl.replace best id (score, { Label.tier = "t3"; zone = "image"; quote = m.src; why; weight = score }))
          (zero_shot e))
      (seen d);
    Hashtbl.fold (fun id (score, ev) acc -> { Label.id; score; evidence = [ ev ] } :: acc) best []
  in
  { name = "t3-images";
    cost = (fun d -> cost_per_item *. float (List.length (seen d)));
    mode = Label.Accumulate;
    applies = (fun d -> seen d <> []);
    run }

(* A 700-way zero-shot choice is where LLMs fail (34% accuracy on IAB, Kamen
   2025), so the model only picks among the cheaper tiers' shortlist. *)
let candidates onto prior =
  let ranked = List.sort (fun (a : Label.t) b -> compare b.score a.score) prior in
  match List.filteri (fun i _ -> i < 12) ranked with
  | [] -> Ontology.roots onto
  | top -> List.map (fun (l : Label.t) -> l.id) top

(* The shortlist back out of a [prompt]:
   prompt_candidates (prompt onto d ids) = ids. *)
let prompt_candidates prompt =
  let lines = String.split_on_char '\n' prompt in
  let rec after = function "Candidates:" :: rest -> rest | _ :: rest -> after rest | [] -> [] in
  let rec until_page = function "Page:" :: _ | [] -> [] | l :: rest -> l :: until_page rest in
  List.filter_map
    (fun l -> match Text.find l ~from:0 " = " with Some i -> Some (String.sub l 0 i) | None -> None)
    (until_page (after lines))

let prompt onto d ids =
  String.concat "\n"
    ([ "Label this web page for contextual advertising.";
       {|Reply with JSON only: {"labels":[{"id":"<candidate id>","confidence":<0-1>,"quote":"<sentence copied verbatim from the page>"}]}|};
       "Use only candidate ids. Omit candidates that do not apply.";
       "Candidates:" ]
    @ List.map (fun id -> id ^ " = " ^ Ontology.path onto id) ids
    @ [ "Page:"; Doc.condensed d ])

let parse_answer text =
  let label (j : Yojson.Safe.t) =
    match j with
    | `Assoc kv -> (
        match (List.assoc_opt "id" kv, List.assoc_opt "confidence" kv, List.assoc_opt "quote" kv) with
        | Some (`String id), Some (`Float c), Some (`String q) -> Some (id, c, q)
        | Some (`String id), Some (`Int c), Some (`String q) -> Some (id, float c, q)
        | _ -> None)
    | _ -> None
  in
  match Yojson.Safe.from_string text with
  | `Assoc kv -> (
      match List.assoc_opt "labels" kv with Some (`List l) -> List.filter_map label l | _ -> [])
  | _ -> []
  | exception Yojson.Json_error _ -> []

(* Rationales are claims (Turpin et al. 2023); a quote is checkable. An id
   outside the shortlist is dropped, a shortlisted one the model left out
   scores 0, an unverifiable quote halves confidence: on the page
   Text.normalize "the cat sat", the answer ("533", 0.8, "dog barked")
   scores 0.4. *)
let judge ?(zone = "llm") ~page answers id =
  let evidence quote why weight = [ { Label.tier = "t4"; zone; quote; why; weight } ] in
  match List.find_opt (fun (i, _, _) -> i = id) answers with
  | None -> { Label.id; score = 0.; evidence = evidence "" "not selected among candidates" 0. }
  | Some (_, confidence, quote) ->
      let confidence = if Float.is_nan confidence then 0. else Float.min 1. (Float.max 0. confidence) in
      let verified = String.trim quote <> "" && Text.contains page (Text.normalize quote) in
      let score = if verified then confidence else confidence /. 2. in
      let why = if verified then "quote verified on page" else "quote NOT on page, confidence halved" in
      { Label.id; score; evidence = evidence (Text.clip quote) why score }

(* T4 "System 2": [complete] is a provider call (batch API, cached static
   prefix). The model sees the condensed page and a shortlist, never the HTML.
   It is the final arbiter: a label that did not make the shortlist drops to
   0, unless a cheaper tier already froze it above [accept]. *)
let llm ?(cost = 1e-3) ?(zone = "llm") ~complete onto =
  let run d prior =
    let ids = candidates onto prior in
    let answers = parse_answer (complete (prompt onto d ids)) in
    let page = Text.normalize (Doc.all_text d) in
    let outside =
      List.filter_map
        (fun (l : Label.t) ->
          if List.mem l.id ids then None
          else Some { l with Label.score = 0.; evidence = [ { Label.tier = "t4"; zone; quote = ""; why = "not in the shortlist"; weight = 0. } ] })
        prior
    in
    List.map (judge ~zone ~page answers) ids @ outside
  in
  { name = "t4-llm"; cost = (fun _ -> cost); mode = Label.Override; applies = (fun _ -> true); run }
