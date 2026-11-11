(* The full IAB Content Taxonomy 3.1, two Model2Vec models, SigLIP 2 for
   images and the cascade, wired for the crawler and the online server. Every
   function here is pure and safe to run on any domain. *)

(* SigLIP 2's vision tower, the taxonomy's text prototypes, the NaFlex
   patch budget (256, the model's default; fewer is faster and coarser) and
   the smallest side worth embedding: under 150 pixels it is a logo, an
   app-store badge or an avatar. *)
type vision = { model : Siglip.t; protos : Siglip.prototypes; max_patches : int; min_side : int }

type t = {
  onto : Ontology.t;
  english : Tier.similarity; (* potion-base-32M *)
  multilingual : (string * Tier.similarity) list;
      (* potion-multilingual-128M, prototypes per lexicon language; "" = every term *)
  vision : vision option; (* None where no image is embedded (online server, tools) *)
  version : string; (* pipeline version without T4, see [load] *)
}

(* T4: [complete] maps a prompt to the model's raw answer; [cost] is the
   expected $ per call the budget sees. *)
type llm = { complete : string -> string; cost : float; name : string }

type map = { map : 'a 'b. ('a -> 'b) -> 'a array -> 'b array }

let sequential = { map = Array.map }

let presets =
  [ ("zero_fetch", Cascade.zero_fetch); ("standard", Cascade.standard); ("rich", Cascade.rich); ("deep", Cascade.deep) ]

(* A block's or a sentence's cosine against an IAB prototype, as a
   probability. One sentence on topic scores about 0.45-0.55 and a generic
   one up to 0.27; a whole page is a mean over 40 sentences, so its on-topic
   cosine drops to about 0.30 and pages get their own pairs ([page_platts]).
   potion-base-32M and potion-multilingual-128M give the same segment
   cosines within 0.01 (median and p90) on English pages, so this pair is
   shared. Fitted on the 383-page golden set. Alone it never lifts a label
   above 0.3 (that would take a cosine above 1.06): the lexicon carries
   segments. *)
let text_platt = (5.21, -6.39)

(* T2's page cosine as a probability, per two-letter language: "en" is
   potion-base-32M, "" every other page (potion-multilingual-128M, whose page
   cosines run lower). A pair per model: one pair for both gave English
   pages an ECE of 0.332, against 0.188 with their own. Fitted on the golden
   set with prototypes per language: Italian (112 pages) and French (76) on
   their own, German (27) and the rest on the shared non-English fit. One
   pair for every non-English page, (7.72, -6.13), left 8 of their labels
   above 0.3; these leave 95. *)
let page_platts = [ ("en", (15.74, -6.83)); ("it", (9.48, -6.37)); ("fr", (10.63, -6.89)); ("", (9.88, -6.68)) ]

let page_platt lang =
  match List.assoc_opt (Ontology.language lang) page_platts with Some p -> p | None -> List.assoc "" page_platts

let calibrate_text = Tier.platt ~a:(fst text_platt) ~b:(snd text_platt)

(* Per two-letter language, "" for the rest: T1's saturation and the accept
   and reject thresholds of every preset but deep, which never settles.
   Fitted on the golden set (src/golden, "T1 and thresholds per language"):
   the best overall hF1 with T4 on at most 30% of pages, the cost model's
   share, allocated across languages, T4's outcome taken from the stored
   deep level. hF1 0.501 with T4 on 29.8% of pages, against 0.544 on 49.1%
   with (4, 0.8, 0.3) everywhere. Italian keeps T4 on 42% of its pages:
   its T0-T3 labels gain least from wider thresholds. German (27 pages) is
   in "". *)
type tuning = { saturation : float; accept : float; reject : float }

let tunings =
  [ ("en", { saturation = 8.; accept = 0.5; reject = 0.4 });
    ("it", { saturation = 2.; accept = 0.8; reject = 0.4 });
    ("fr", { saturation = 12.; accept = 0.5; reject = 0.4 });
    ("", { saturation = 12.; accept = 0.7; reject = 0.4 }) ]
let tuning lang = match List.assoc_opt (Ontology.language lang) tunings with Some t -> t | None -> List.assoc "" tunings
let saturation lang = (tuning lang).saturation

let calibrate_page lang =
  let a, b = page_platt lang in
  Tier.platt ~a ~b

let is_sensitive onto id = Ontology.is_under onto id ~root:Matcher.sensitive_topics
let genres = "SPSHQ5" (* IAB Content Taxonomy 3.1: Genres *)

(* T1 lexicon bootstrapped from the taxonomy itself ("Food & Drink" gives
   "food" and "drink"), plus the hand-written lexicon.tsv. Sensitive Topics are
   left to the hand lexicon: their names ("Society", "Spam") make bad terms. *)
let name_lexicon onto =
  let sep = Re.Perl.compile_pat {|\s*(?:&|,|/|\band\b|\bor\b)\s*|} in
  let generic = [ "other"; "general"; "services"; "industry"; "industries"; "content" ] in
  Ontology.ids onto
  |> List.filter (fun id -> not (is_sensitive onto id))
  |> List.concat_map (fun id ->
         Re.split sep (Ontology.name onto id)
         |> List.map String.trim
         |> List.filter (fun p -> String.length p >= 3 && not (List.mem (String.lowercase_ascii p) generic))
         |> List.map (fun p -> id ^ "\t" ^ p))
  |> String.concat "\n"

(* A model's prototypes (path + the lexicon's terms in [lang]) embedded once;
   then every batch of texts is one embedding call and one ggml matrix
   multiply. *)
let similarity ?lang onto model =
  let ids = Array.of_list (Ontology.ids onto) in
  let protos =
    Model2vec.embed_batch model
      (Array.map (fun id -> String.concat " " (Ontology.path onto id :: Ontology.terms ?lang onto id)) ids)
  in
  let cosines texts =
    let m = Model2vec.dots ~protos (Model2vec.embed_batch model texts) in
    Array.init (Bigarray.Array2.dim1 m) (fun i -> Array.init (Bigarray.Array2.dim2 m) (fun j -> m.{i, j}))
  in
  { Tier.ids; cosines }

(* English pages get potion-base-32M, the strongest English model; any other
   language, or none declared, potion-multilingual-128M (101 languages), with
   prototypes in the page's language when the lexicon has terms in it, so an
   Italian page is compared with Italian words. *)
let space e lang =
  match Ontology.language lang with
  | "en" -> e.english
  | l -> ( match List.assoc_opt l e.multilingual with Some s -> s | None -> List.assoc "" e.multilingual)

(* SigLIP's own sigmoid probability that a prompt fits the image runs low for
   category names: 0.1 to 0.4 for the clearest hits on publishers' images,
   0.02 to 0.07 for the wrong ones (crowds as Fan Conventions, portraits as
   Celebrity Deaths), 0.01 on a soccer match for Soccer
   (study/siglip2_images.md). Fitted on the golden set: ECE 0.401 -> 0.091.
   IAB Genres (TV, film and music genres) are left out: a photo of people
   reads as Talk Show or Reality TV whatever the page is about. *)
let image_platt = (0.41, -0.30)
let calibrate_image = Tier.platt ~a:(fst image_platt) ~b:(snd image_platt)

(* The pipeline version: what a profile depends on besides the page,
   hashed, so memoisation and audits tell profiles apart. It covers the
   taxonomy, lexicon and model files byte for byte, every calibration
   constant, the per-language tunings, the presets, the image settings, and
   T4's model ([version]). Code is not in it: bump [code] with a change
   that moves labels. *)
let code = "2026-11-11.3"

let file_digest path =
  In_channel.with_open_bin path (fun ic ->
      let buf = Bytes.create 65536 in
      let rec go ctx = match In_channel.input ic buf 0 65536 with 0 -> ctx | n -> go (Digestif.SHA256.feed_bytes ctx ~len:n buf) in
      Digestif.SHA256.(to_hex (get (go empty))))

let short_hash s = String.sub Digestif.SHA256.(to_hex (digest_string s)) 0 16

let params ~vision =
  let pair (a, b) = Printf.sprintf "%h,%h" a b in
  let policy (n, (p : Cascade.policy)) = Printf.sprintf "%s:%h,%h,%h" n p.budget p.accept p.reject in
  String.concat "\n"
    ([ "code " ^ code; "text_platt " ^ pair text_platt; "image_platt " ^ pair image_platt; "image_cost " ^ Printf.sprintf "%h" Tier.image_cost ]
    @ List.map (fun (l, p) -> Printf.sprintf "page_platt %s %s" l (pair p)) page_platts
    @ List.map (fun (l, t) -> Printf.sprintf "tuning %s %h,%h,%h" l t.saturation t.accept t.reject) tunings
    @ List.map policy presets
    @ match vision with Some v -> [ Printf.sprintf "vision %d %d" v.max_patches v.min_side ] | None -> [ "vision none" ])

(* With T4's model id when it runs. *)
let version ?t4 e = match t4 with None -> e.version | Some model -> short_hash (e.version ^ "\n" ^ model)

let load ?(vision = true) ?(max_patches = 256) data =
  let read f = In_channel.with_open_bin (Filename.concat data f) In_channel.input_all in
  let taxonomy = read "content_taxonomy_3.1.tsv" in
  let bare = Ontology.of_tsv ~taxonomy ~lexicon:"" in
  let onto = Ontology.of_tsv ~taxonomy ~lexicon:(name_lexicon bare ^ "\n" ^ read "lexicon.tsv") in
  let model name = Model2vec.load (Filename.concat data (name ^ ".gguf")) in
  let multilingual = model "potion-multilingual-128M" in
  let vision =
    if not vision then None
    else
      Some
        { model = Siglip.load (Filename.concat data "siglip2-base-patch16-naflex.gguf");
          protos = Siglip.prototypes (Filename.concat data "siglip2_prototypes.gguf");
          max_patches;
          min_side = 150 }
  in
  let files =
    [ "content_taxonomy_3.1.tsv"; "lexicon.tsv"; "potion-base-32M.gguf"; "potion-multilingual-128M.gguf" ]
    @ if vision = None then [] else [ "siglip2-base-patch16-naflex.gguf"; "siglip2_prototypes.gguf" ]
  in
  let digests = List.map (fun f -> f ^ " " ^ file_digest (Filename.concat data f)) files in
  { onto;
    version = short_hash (String.concat "\n" (digests @ [ params ~vision ]));
    english = similarity ~lang:"en" onto (model "potion-base-32M");
    multilingual =
      List.map
        (fun l -> (l, similarity ~lang:l onto multilingual))
        ("" :: List.filter (( <> ) "en") (Ontology.languages onto));
    vision }


let image_logits e v embedding =
  let scale, bias = Siglip.logit v.model in
  let s = exp scale in
  Array.to_list (Array.mapi (fun j proto -> (v.protos.ids.(j), (s *. Siglip.dot proto embedding) +. bias)) v.protos.vectors)
  |> List.filter (fun (id, _) -> not (Ontology.is_under e.onto id ~root:genres))

let image_labels e v embedding =
  List.filter_map
    (fun (id, logit) ->
      let score = calibrate_image logit in
      (* 0.15 is a raw SigLIP p of about 0.03; 0.3 would drop the clear EV
         hit in test_siglip.ml. *)
      if score >= 0.15 then Some (id, score, Printf.sprintf "SigLIP 2 p %.3f" (1. /. (1. +. exp (-.logit)))) else None)
    (image_logits e v embedding)

let tiers ?llm ?(see = fun _ -> None) ?(saturation = saturation) e ~describe =
  [ Tier.url_and_hints ~saturation e.onto;
    Tier.lexical ~saturation e.onto;
    Tier.dense
      ~similarity:(fun d -> space e (Lazy.force d.Doc.content).lang)
      ~calibrate:(fun d -> calibrate_page (Lazy.force d.Doc.content).lang)
      ();
    Tier.media ~zone:"oembed" ~saturation ~kinds:[ Doc.Video ] ~describe e.onto ]
  @ Option.fold ~none:[] ~some:(fun v -> [ Tier.images ~see ~zero_shot:(image_labels e v) () ]) e.vision
  @ Option.fold ~none:[]
      ~some:(fun l -> [ Tier.llm ~cost:l.cost ~zone:("llm " ^ l.name) ~complete:l.complete e.onto ])
      llm

let levels ?llm ?see ?(presets = presets) e ~describe (d : Doc.t) =
  let tiers = tiers ?llm ?see e ~describe in
  let t = tuning (Lazy.force d.content).lang in
  List.map
    (fun (preset, (policy : Cascade.policy)) ->
      let policy = if preset = "deep" then policy else { policy with accept = t.accept; reject = t.reject } in
      { Profile.preset; result = Cascade.run e.onto policy tiers d })
    presets

(* The prompts T4 would receive, found by a dry run that answers nothing: T4
   is the last tier, so its prompt only depends on the tiers before it. The
   caller sends them over the network (Lwt), then reruns with the answers. *)
let llm_prompts ?see ?presets ~cost e ~describe d =
  let asked = ref [] in
  let complete p =
    if not (List.mem p !asked) then asked := p :: !asked;
    ""
  in
  ignore (levels ~llm:{ complete; cost; name = "dry run" } ?see ?presets e ~describe d);
  List.rev !asked

let noisy_or a b = 1. -. ((1. -. a) *. (1. -. b))

(* Cheap per-block labels (T1 + T2 on each block of text, T2 in one batch):
   what slot-level context and adjacency checks read. *)
let texts_labels e ~lang ~zone ~weight texts =
  let sim = space e lang in
  let cos = sim.cosines texts in
  Array.mapi
    (fun i text ->
      let lexical =
        Label.compact (Tier.lexical_labels ~lang ~saturation:(saturation lang) ~tier:"t1" e.onto [ (zone, weight, [ text ]) ])
      in
      let kept = ref [] in
      Array.iteri
        (fun j id ->
          let s = noisy_or (calibrate_text cos.(i).(j)) (Option.value (List.assoc_opt id lexical) ~default:0.) in
          if s > 0.3 then kept := (id, s) :: !kept)
        sim.ids;
      List.stable_sort (fun (_, a) (_, b) -> compare b a) (List.rev !kept))
    texts

let top k l = List.filteri (fun i _ -> i < k) l

(* A block's labels with every ancestor at least as high, so that a
   category is on a block when its own id is, as on a page. *)
let close e labels =
  let best = Hashtbl.create 16 in
  List.iter
    (fun (id, s) ->
      List.iter
        (fun a -> if s > Option.value (Hashtbl.find_opt best a) ~default:0. then Hashtbl.replace best a s)
        (Ontology.ancestors e.onto id))
    labels;
  List.stable_sort (fun (_, a) (_, b) -> compare b a) (List.of_seq (Hashtbl.to_seq best))

(* Topic: the 3 best labels. Suitability: every sensitive label, never cut.
   Both with their ancestors. Blocks under 20 characters get none. *)
let segment_labels e (c : Doc.content) =
  let segs = Array.of_list c.segments in
  let long = List.filter (fun i -> String.length segs.(i).text >= 20) (List.init (Array.length segs) Fun.id) in
  let labels = texts_labels e ~lang:c.lang ~zone:"block" ~weight:1.0 (Array.of_list (List.map (fun i -> segs.(i).text) long)) in
  let out = Array.make (Array.length segs) [] in
  List.iteri
    (fun k i ->
      let sensitive, topical = List.partition (fun (id, _) -> is_sensitive e.onto id) labels.(k) in
      out.(i) <- close e (top 3 topical @ sensitive))
    long;
  Array.to_list out

let page_keywords (d : Doc.t) = List.map Matcher.keyword (d.hints @ (Lazy.force d.content).keywords)

(* A story: an <article> with at least this much main text; shorter ones are
   teasers and "related" cards. *)
let story_chars = 400

(* Each story's labels, from its main text (T1 and T2, as blocks are). *)
let article_labels e (c : Doc.content) =
  let texts = Hashtbl.create 8 in
  List.iter
    (fun (s : Doc.segment) ->
      if s.article > 0 && s.main then
        Hashtbl.replace texts s.article (Option.value (Hashtbl.find_opt texts s.article) ~default:"" ^ " " ^ s.text))
    c.segments;
  let stories = List.filter (fun (_, t) -> String.length t >= story_chars) (List.of_seq (Hashtbl.to_seq texts)) in
  match stories with
  | [] | [ _ ] -> [] (* one story is the page *)
  | _ ->
      let labels = texts_labels e ~lang:c.lang ~zone:"article" ~weight:1.0 (Array.of_list (List.map snd stories)) in
      List.sort compare (List.mapi (fun i (a, _) -> (a, close e labels.(i))) stories)

let profile ?llm ?see ?presets ?(t4_gate = "not evaluated") ?(ad_slots = []) e ~describe ~fetched_at (d : Doc.t) =
  let c = Lazy.force d.content in
  let levels = levels ?llm ?see ?presets e ~describe d in
  let labels = segment_labels e c in
  let found = List.map (fun (id, index) -> { Profile.id; index; learned = false }) c.ad_slots in
  { Profile.url = d.url;
    key = Store.normalize d.url;
    site = Profile.site_of d.url;
    title = c.title;
    fetched_at;
    keywords = page_keywords d;
    levels;
    segments = Profile.layout c.segments labels;
    t4_gate;
    version = version ?t4:(Option.map (fun (l : llm) -> l.name) llm) e;
    ad_slots = (if found <> [] then found else ad_slots);
    articles = article_labels e c }

let stopwords =
  [ "with"; "that"; "this"; "from"; "your"; "their"; "they"; "have"; "into"; "about"; "more"; "most"; "very"; "will";
    "just"; "like"; "love"; "loves"; "people"; "who"; "for"; "and"; "the" ]

(* A creative described in words: same labels as pages. Prompts are typed
   in English. *)
let creative_of_prompt e ~avoid_sensitive prompt =
  let labels =
    (texts_labels e ~lang:"en" ~zone:"prompt" ~weight:3.0 [| prompt |]).(0)
    |> List.filter (fun (id, _) -> not (is_sensitive e.onto id))
    |> top 5
  in
  let keywords =
    Array.to_list (Text.tokens prompt)
    |> List.filter (fun w -> String.length w >= 4 && not (List.mem w stopwords))
    |> List.sort_uniq compare
  in
  { Matcher.id = "prompt"; product = ""; labels; keywords; targets = []; blocks = []; avoid_sensitive }

type slot = {
  ad : string; (* the ad container's id when the page has one there, else "" *)
  after : int; (* segment index the slot follows; -1 = page level *)
  y : float; (* viewports from the top *)
  reach : float; (* P(reader scrolls this far) *)
  fit : float; (* P(contextual fit | seen) *)
  verdict : Matcher.verdict;
  flagged : int list; (* co-visible segments carrying a sensitive label *)
}

(* shortcut: priors, not fits. Reach: exp(-y/6) scroll decay; replace with
   measured scroll-depth curves per site. Fit: logistic on the matcher score;
   replace with the engagement regression of study/matching.md §5. *)
let reach y = exp (-.y /. 6.)

let fit_of = function
  | Matcher.Blocked _ -> 0.
  | Matcher.Eligible { score; _ } -> 1. /. (1. +. exp (-12. *. (score -. 0.25)))

let no_affinity = Hashtbl.create 1

let page_view (p : Profile.t) ~level =
  match Profile.level p level with
  | Some l -> { Matcher.labels = Label.compact l.result.labels; keywords = p.keywords }
  | None -> { Matcher.labels = []; keywords = p.keywords }

let slot_after_tags = [ "p"; "blockquote"; "figcaption"; "img"; "iframe"; "video" ]

(* The page a slot sits in: its story's labels when the URL holds several
   stories (live blogs, infinite scroll), else the page's. *)
let story_view (p : Profile.t) page (s : Profile.segment option) =
  match s with
  | Some s when s.article > 0 -> (
      match List.assoc_opt s.article p.articles with
      | Some labels when labels <> [] -> { page with Matcher.labels }
      | _ -> page)
  | _ -> page

(* The slots an ad of [format] could take on [p], each scored for [c]:
   - fullscreen, or a page with neither an ad container nor a main block to
     follow: one page-level slot (y = 0, after = -1);
   - else the template's ad containers when the page has them, one slot
     each, at the bottom of the block before it;
   - else one after every main p, blockquote, figcaption, img, iframe or
     video.
   Each slot reads the blocks around it through Slot.context and takes its
   story's labels as its page when the URL holds several stories of 400+
   characters (story_view, article_labels).

       segment                              slot: ad, after, page labels
       <div id="div-gpt-ad-top">       ──▶  div-gpt-ad-top, -1, the page's
     0 h1  Derby report       story 1
     1 p   The striker ...    story 1
       <div id="ad-mpu-1">             ──▶  ad-mpu-1, 1, story 1's
     2 p   The keeper ...     story 1
     3 p   Slow-cooked ...    story 2

   Without the two containers the slots follow segments 1, 2 and 3 (an h1
   is no anchor), the last one with story 2's labels. *)
let slots e ~format ~level (p : Profile.t) (c : Matcher.creative) =
  let page = page_view p ~level in
  let segs = if level = "zero_fetch" then [||] else Array.of_list p.segments in
  let seg i = if i >= 0 && i < Array.length segs then Some segs.(i) else None in
  let blocks_at y =
    Array.to_list
      (Array.map
         (fun (s : Profile.segment) ->
           { Slot.offset = s.top +. (s.height /. 2.) -. y; main = s.main; labels = s.labels })
         segs)
  in
  let flagged_at y =
    List.filter_map Fun.id
      (Array.to_list
         (Array.mapi
            (fun i (s : Profile.segment) ->
              let near = Float.abs (s.top +. (s.height /. 2.) -. y) <= Slot.co_visible in
              if near && List.exists (fun (id, sc) -> sc >= Matcher.present && is_sensitive e.onto id) s.labels
              then Some i
              else None)
            segs))
  in
  let at ?(ad = "") y after =
    let page = story_view p page (seg after) in
    let verdict = Matcher.score e.onto ~affinity:no_affinity (Slot.context e.onto ~format page (blocks_at y)) c in
    { ad; after; y; reach = reach y; fit = fit_of verdict; verdict; flagged = flagged_at y }
  in
  let bottom i = match seg i with Some s -> s.top +. s.height | None -> 0. in
  (* Nested containers (a wrapper and its div-gpt-ad) and mobile variants
     share a position: one slot per position, named after the innermost, the
     last in document order. *)
  let ads =
    List.filter (fun (a : Profile.ad_slot) -> a.index <= Array.length segs) p.ad_slots
    |> List.fold_left (fun acc (a : Profile.ad_slot) -> (a.index, a) :: List.remove_assoc a.index acc) []
    |> List.rev_map snd
  in
  let candidates =
    List.filter_map Fun.id
      (Array.to_list
         (Array.mapi
            (fun i (s : Profile.segment) -> if s.main && List.mem s.tag slot_after_tags then Some i else None)
            segs))
  in
  if format = "fullscreen" || (candidates = [] && ads = []) then [ at 0. (-1) ]
  else if ads <> [] then List.map (fun (a : Profile.ad_slot) -> at ~ad:a.id (bottom (a.index - 1)) (a.index - 1)) ads
  else List.map (fun i -> at (bottom i) i) candidates

let best_slot e ~format ~level p c =
  match slots e ~format ~level p c with
  | first :: rest -> List.fold_left (fun best s -> if s.fit > best.fit then s else best) first rest
  | [] -> invalid_arg "Engine.best_slot: slots is never empty"
