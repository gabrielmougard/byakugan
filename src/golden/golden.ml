(* Golden-set report against the judgements the Placement Lab exports
   (GET /api/adjudication.tsv):
   - per preset, hierarchical F1 of the served labels (score >= 0.5), the
     top false positives and why each level stopped, from the stored profiles;
   - T4's shortlist recall@12, ECE per tier, Platt refits for T2 (page and
     sentence cosine) and T3 (SigLIP 2 logit), a temperature for T4 and the
     accept/reject thresholds, from raw signals recomputed offline.
   The stored profiles cannot give those: finalize drops every label <= 0.3.
   Pages and images are fetched once into --cache (src/store is gitignored:
   their text is not ours to publish). No LLM call: T4's confidences are the
   stored deep level's, 0 for a shortlisted label it left out or put <= 0.3.

   golden --valkey valkey://localhost:6390 --judgements adjudication.tsv > report.md *)

open Contextual
open Serve
open Lwt.Syntax

type page = {
  gold : Ontology.id list;
  lang : string; (* two-letter, "" undeclared; "en" is potion-base-32M for T2, else potion-multilingual-128M *)
  profile : Profile.t;
  t1 : (Ontology.id * float) list; (* lexical score *)
  t2 : (Ontology.id * float * float) list; (* page cosine, best sentence cosine *)
  t3 : (Ontology.id * float) list; (* best SigLIP 2 logit over the page's images; [] without images *)
  shortlist : Ontology.id list;
  pre_t4 : Label.t list; (* deep preset without T4, nothing dropped *)
  offline : (string * Cascade.result) list; (* every preset, T0-T3, the current calibration *)
  grid : ((float * float) * Cascade.result) list; (* rich under other (accept, reject) *)
  tune : ((float * float * float) * (bool * Ontology.id list)) list;
      (* rich under (T1 saturation, accept, reject): settled?, served labels *)
}

let accepts = [ 0.5; 0.6; 0.7; 0.8 ]
let rejects = [ 0.1; 0.2; 0.3 ]
let saturations = [ 2.; 4.; 6.; 8.; 12.; 16.; 23.4 ]
let tune_accepts = [ 0.5; 0.6; 0.7; 0.8; 0.9 ]
let tune_rejects = [ 0.05; 0.1; 0.2; 0.3; 0.4 ]

(* T0-T3 ignore the labels before them, so one run of each serves every
   (accept, reject) of the grid. *)
let memo (t : Tier.t) =
  let out = ref None in
  { t with run = (fun d prior -> match !out with Some l -> l | None -> let l = t.run d prior in out := Some l; l) }

let judgements file =
  In_channel.with_open_bin file In_channel.input_lines
  |> List.filter_map (fun l ->
         match String.split_on_char '\t' l with
         | url :: gold :: _ when url <> "url" -> Some (url, List.filter (( <> ) "") (String.split_on_char ',' gold))
         | _ -> None)

let stored_profiles kv =
  let* index = Lab.profile_index kv in
  let+ bodies = Lwt_list.map_s (Lab.profiles kv) (Lab.chunks 100 (List.map fst index)) in
  List.filter_map (Option.map (fun b -> Profile.of_json (Yojson.Safe.from_string b))) (List.concat bodies)

(* One fetch per second per host, robots.txt obeyed, as in t4eval. *)
let cached ~cache url =
  let file = Filename.concat cache Digestif.SHA256.(to_hex (digest_string url)) in
  if Sys.file_exists file then Lwt.return_some (In_channel.with_open_bin file In_channel.input_all)
  else
    let* ok = Web.allowed url in
    if not ok then Lwt.return_none
    else
      let* r = Web.fetch ~headers:[ "Accept: text/html,image/webp,image/png,image/jpeg;q=0.9" ] url in
      let+ () = Lwt_unix.sleep 1. in
      match r with
      | Ok { status = 200; body; _ } ->
          Out_channel.with_open_bin file (fun oc -> output_string oc body);
          Some body
      | _ -> None

let host url = Option.value (Uri.host (Uri.of_string url)) ~default:""

let images d =
  List.map
    (fun (m : Doc.media) -> (m, Uri.to_string (Uri.resolve "" (Uri.of_string d.Doc.url) (Uri.of_string m.src))))
    (Tier.undescribed [ Doc.Image ] d)

let fetch_all ~cache urls =
  Lwt_list.map_p
    (fun h ->
      Lwt_list.filter_map_s
        (fun url ->
          let* html = cached ~cache url in
          match html with
          | None -> Lwt.return_none
          | Some html ->
              let d = Doc.of_html ~url html in
              let+ pictures = Lwt_list.filter_map_s (fun (m, src) -> Lwt.map (Option.map (fun b -> (m, b))) (cached ~cache src)) (images d) in
              Some (url, d, pictures))
        (List.filter (fun u -> host u = h) urls))
    (List.sort_uniq compare (List.map host urls))
  |> Lwt.map List.concat

let served_ids (r : Cascade.result) = List.filter_map (fun (x : Label.t) -> if x.score >= 0.5 then Some x.id else None) r.labels

let dense_raw (e : Engine.t) d =
  let sim = Engine.space e (Lazy.force d.Doc.content).lang in
  match Tier.dense_cosines sim d with
  | [||], _ -> []
  | _, cos ->
      Array.to_list
        (Array.mapi
           (fun j id ->
             let best = ref neg_infinity in
             for i = 1 to Array.length cos - 1 do best := Float.max !best cos.(i).(j) done;
             (id, cos.(0).(j), !best))
           sim.ids)

let best_logits (e : Engine.t) v embeddings =
  let best = Hashtbl.create 1024 in
  List.iter
    (fun emb ->
      List.iter
        (fun (id, l) -> if l > Option.value (Hashtbl.find_opt best id) ~default:neg_infinity then Hashtbl.replace best id l)
        (Engine.image_logits e v emb))
    embeddings;
  List.of_seq (Hashtbl.to_seq best)

let signals (e : Engine.t) ~gold ~profile (_, d, pictures) =
  let v = Option.get e.vision in
  let embedded =
    List.filter_map
      (fun ((m : Doc.media), bytes) ->
        Result.to_option (Siglip.embed v.model bytes ~max_patches:v.max_patches ~min_side:v.min_side ~threads:4)
        |> Option.map (fun emb -> (m.src, emb)))
      pictures
  in
  let see (m : Doc.media) = List.assoc_opt m.src embedded in
  let describe _ = None in
  let prompts = Engine.llm_prompts ~see ~cost:0. e ~describe d in
  let tiers = Engine.tiers ~see e ~describe in
  let pre = Cascade.run e.onto { Cascade.deep with reject = 0. } tiers d in
  let rich accept reject = Cascade.run e.onto { Cascade.rich with accept; reject } tiers d in
  { gold;
    lang = Ontology.language (Lazy.force d.Doc.content).lang;
    profile;
    t1 = List.map (fun (l : Label.t) -> (l.id, l.score)) ((Tier.lexical e.onto).run d []);
    t2 = dense_raw e d;
    t3 = best_logits e v (List.map snd embedded);
    shortlist = (match List.rev prompts with p :: _ -> Tier.prompt_candidates p | [] -> []);
    pre_t4 = pre.labels;
    offline = List.map (fun (l : Profile.level) -> (l.preset, l.result)) (Engine.levels ~see e ~describe d);
    grid = List.concat_map (fun a -> List.map (fun r -> ((a, r), rich a r)) rejects) accepts;
    tune =
      List.concat_map
        (fun s ->
          let tiers = List.map memo (Engine.tiers ~see ~saturation:(fun _ -> s) e ~describe) in
          List.concat_map
            (fun a ->
              List.map
                (fun r ->
                  let res = Cascade.run e.onto { Cascade.rich with accept = a; reject = r } tiers d in
                  ((s, a, r), (res.stop = Cascade.Settled, served_ids res)))
                tune_rejects)
            tune_accepts)
        saturations }

(* Report *)

let truth onto p = let g = Golden.closure onto p.gold in fun id -> List.mem id g
let pct x = Printf.sprintf "%.1f%%" (100. *. x)
let f3 = Printf.sprintf "%.3f"
let level p preset = Profile.level p.profile preset

let served p preset =
  match level p preset with
  | Some l -> List.filter_map (fun (x : Label.t) -> if x.score >= 0.5 then Some x.id else None) l.result.labels
  | None -> []

let presets onto pages =
  print_endline "## Served labels per preset (score >= 0.5)\n";
  print_endline "| preset | hP | hR | hF1 | settled | out of budget | no more tiers | top false positives |";
  print_endline "|---|---|---|---|---|---|---|---|";
  List.iter
    (fun (preset, _) ->
      let p, r, f = Golden.prf (List.map (fun pg -> Golden.overlap onto ~gold:pg.gold ~predicted:(served pg preset)) pages) in
      let stops = List.filter_map (fun pg -> Option.map (fun (l : Profile.level) -> Cascade.stop_name l.result.stop) (level pg preset)) pages in
      let share s = pct (Golden.ratio (List.length (List.filter (( = ) s) stops)) (List.length stops)) in
      let wrong = Hashtbl.create 64 in
      List.iter
        (fun pg ->
          let right = truth onto pg in
          List.iter (fun id -> if not (right id) then Hashtbl.replace wrong id (1 + Option.value (Hashtbl.find_opt wrong id) ~default:0)) (served pg preset))
        pages;
      let top =
        List.sort (fun (_, a) (_, b) -> compare b a) (List.of_seq (Hashtbl.to_seq wrong))
        |> Engine.top 4
        |> List.map (fun (id, n) -> Printf.sprintf "%s (%d)" (Ontology.path onto id) n)
      in
      Printf.printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n" preset (f3 p) (f3 r) (f3 f) (share "settled") (share "out of budget")
        (share "no more tiers") (String.concat "; " top))
    Engine.presets

let f3n x = if Float.is_nan x then "-" else f3 x

(* What the levels serve with the current calibration, without T4: a page
   that does not settle is one T4 would see at rich and deep (its cost fits
   both budgets). *)
let today onto pages =
  print_endline "\n## Served labels per preset with today's calibration, T0-T3 only\n";
  print_endline "Recomputed offline from the re-fetched pages; the table above is what the stored profiles serve.\n";
  print_endline "| preset | hP | hR | hF1 | settled | out of budget | no more tiers |";
  print_endline "|---|---|---|---|---|---|---|";
  List.iter
    (fun (preset, _) ->
      let results = List.map (fun p -> (p, List.assoc preset p.offline)) pages in
      let p, r, f = Golden.prf (List.map (fun (pg, res) -> Golden.overlap onto ~gold:pg.gold ~predicted:(served_ids res)) results) in
      let share s = pct (Golden.ratio (List.length (List.filter (fun (_, (res : Cascade.result)) -> res.stop = s) results)) (List.length results)) in
      Printf.printf "| %s | %s | %s | %s | %s | %s | %s |\n" preset (f3n p) (f3n r) (f3n f) (share Cascade.Settled)
        (share Cascade.Out_of_budget) (share Cascade.Exhausted))
    Engine.presets

let grid onto pages =
  print_endline "\n## Accept and reject at rich\n";
  print_endline "Per (accept, reject): the pages T4 would see (not settled), and the hP / hF1 of what settled pages serve without it.\n";
  Printf.printf "| accept \\ reject | %s |\n" (String.concat " | " (List.map (Printf.sprintf "%.1f") rejects));
  Printf.printf "|---|%s\n" (String.concat "" (List.map (fun _ -> "---|") rejects));
  List.iter
    (fun a ->
      let cell r =
        let results = List.map (fun p -> (p, List.assoc (a, r) p.grid)) pages in
        let settled = List.filter (fun (_, (res : Cascade.result)) -> res.stop = Cascade.Settled) results in
        let hp, _, hf = Golden.prf (List.map (fun (pg, res) -> Golden.overlap onto ~gold:pg.gold ~predicted:(served_ids res)) settled) in
        Printf.sprintf "T4 %s, hP %s, hF1 %s" (pct (1. -. Golden.ratio (List.length settled) (List.length results))) (f3n hp) (f3n hf)
      in
      Printf.printf "| %.1f | %s |\n" a (String.concat " | " (List.map cell rejects)))
    accepts

let shortlist_recall pages =
  let recall within =
    let found, total =
      List.fold_left (fun (f, t) p -> (f + List.length (List.filter (within p) p.gold), t + List.length p.gold)) (0, 0) pages
    in
    Printf.sprintf "%s (%d of %d)" (f3 (Golden.ratio found total)) found total
  in
  let ranked p = List.map (fun (l : Label.t) -> l.id) (List.sort (fun (a : Label.t) b -> compare b.score a.score) p.pre_t4) in
  let top k p g = List.mem g (Engine.top k (ranked p)) in
  Printf.printf "\n## T4 shortlist\n\nrecall@12: %s judged labels; target >= 0.95\n\n" (recall (fun p g -> List.mem g p.shortlist));
  print_endline "Gold labels among T0-T3's k best labels (deep, before T4): what a longer shortlist would buy.\n";
  print_endline "| k | 12 | 16 | 24 | 48 | 96 |";
  print_endline "|---|---|---|---|---|---|";
  Printf.printf "| recall | %s | %s | %s | %s | %s |\n" (recall (top 12)) (recall (top 16)) (recall (top 24)) (recall (top 48))
    (recall (top 96))

let pairs onto pages f = List.concat_map (fun p -> let right = truth onto p in List.map (fun (id, x) -> (x, right id)) (f p)) pages

let t4_confidences p =
  match level p "deep" with
  | Some l -> List.map (fun id -> (id, List.fold_left (fun acc (x : Label.t) -> if x.id = id then x.score else acc) 0. l.result.labels)) p.shortlist
  | None -> []

let calibration onto pages =
  let above = List.filter (fun (s, _) -> s >= 0.3) in
  let ece l = match above l with [] -> "- (0)" | a -> Printf.sprintf "%s (%d)" (f3 (Golden.ece a)) (List.length a) in
  let sentence_cos = pairs onto pages (fun p -> List.map (fun (id, _, c) -> (id, c)) p.t2) in
  let image = pairs onto pages (fun p -> p.t3) in
  let t4 = pairs onto pages t4_confidences in
  let platt name (a0, b0) raw =
    let a, b = Golden.fit_platt raw in
    let now = List.map (fun (x, y) -> (Tier.platt ~a:a0 ~b:b0 x, y)) raw in
    let fitted = List.map (fun (x, y) -> (Tier.platt ~a ~b x, y)) raw in
    Printf.printf "| %s | a %.2f, b %.2f | %s | a %.2f, b %.2f | %s |\n" name a0 b0 (ece now) a b (ece fitted)
  in
  print_endline "\n## Calibration\n\nECE (labels) over the scores a tier hands the cascade (>= 0.3); fits over every (page, category) pair.\n";
  print_endline "| tier | now | ECE now | refit | ECE refit |";
  print_endline "|---|---|---|---|---|";
  let t1 = pairs onto pages (fun p -> p.t1) in
  (* Back to the raw term weight, to fit a saturation or a Platt on it. *)
  let raw = List.map (fun (s, y) -> (-.Tier.saturation *. log (Float.max 1e-9 (1. -. s)), y)) t1 in
  let a, b = Golden.fit_platt raw and sat = Golden.fit_saturation raw in
  Printf.printf "| T1 lexicon | 1 - exp(-raw / %g) | %s | Platt on raw: a %.2f, b %.2f | %s |\n" Tier.saturation (ece t1) a b
    (ece (List.map (fun (x, y) -> (Tier.platt ~a ~b x, y)) raw));
  Printf.printf "| T1 lexicon | | | 1 - exp(-raw / %.1f) | %s |\n" sat
    (ece (List.map (fun (x, y) -> (1. -. exp (-.x /. sat), y)) raw));
  let cosines f p = if f p.lang then List.map (fun (id, c, _) -> (id, c)) p.t2 else [] in
  platt "T2 page cosine, English (potion-base-32M)" (Engine.page_platt "en") (pairs onto pages (cosines (( = ) "en")));
  platt "T2 page cosine, other languages (potion-multilingual-128M)" (Engine.page_platt "")
    (pairs onto pages (cosines (( <> ) "en")));
  List.iter
    (fun l ->
      let n = List.length (List.filter (fun p -> p.lang = l) pages) in
      platt (Printf.sprintf "T2 page cosine, %s only (%d pages)" (if l = "" then "undeclared" else l) n) (Engine.page_platt l)
        (pairs onto pages (cosines (( = ) l))))
    (List.sort_uniq compare (List.filter_map (fun p -> if p.lang = "en" then None else Some p.lang) pages));
  platt "T2 sentence cosine (segments)" Engine.text_platt sentence_cos;
  if image <> [] then begin
    platt "T3 SigLIP 2 logit" Engine.image_platt image;
    let sensitive = pairs onto pages (fun p -> List.filter (fun (id, _) -> Engine.is_sensitive onto id) p.t3) in
    if sensitive <> [] then platt "T3 SigLIP 2 logit, Sensitive Topics only" Engine.image_platt sensitive
  end;
  let t = Golden.fit_temperature t4 in
  Printf.printf "| T4 confidence (shortlist) | T 1 | %s | T %.2f | %s |\n" (ece t4) t
    (ece (List.map (fun (c, y) -> (Golden.scale_temperature t c, y)) t4))

(* Per language, (T1 saturation, accept, reject) at rich with T4 in the
   loop: a page that settles serves its T0-T3 labels, one that does not
   serves what T4 made of it, the stored deep level's labels (crawled with
   T4; the page's own T0-T3 labels where T4 did not run). T4's 30% of pages
   (the cost model's share) is a total, allocated across languages to the
   best overall hF1: Dinkelbach's method on F1 = 2H / (P + G), each step a
   knapsack over the languages' choices with T4 pages as the weight. *)
let with_t4 p =
  match level p "deep" with
  | Some l when List.mem "t4-llm" l.result.ran -> Some (served p "deep")
  | _ -> None

let tune_cap = 0.3
let tune_groups = [ "en"; "it"; "fr"; "" ] (* "": every other language, German included *)
let group p = if List.mem p.lang tune_groups then p.lang else ""

(* (hits, predicted, gold, pages T4 sees) of a group under one choice. *)
let outcome onto pages key =
  List.fold_left
    (fun (h, pr, g, t4) p ->
      let settled, ids = List.assoc key p.tune in
      let ids = if settled then ids else Option.value (with_t4 p) ~default:ids in
      let o = Golden.overlap onto ~gold:p.gold ~predicted:ids in
      (h + o.hit, pr + o.predicted, g + o.gold, if settled then t4 else t4 + 1))
    (0, 0, 0, 0) pages

let allocate onto by_group ~budget =
  let options = List.map (fun (name, pages) -> (name, List.map (fun (k, _) -> (k, outcome onto pages k)) (List.hd pages).tune)) by_group in
  let gold = List.fold_left (fun n (_, opts) -> match opts with (_, (_, _, g, _)) :: _ -> n + g | [] -> n) 0 options in
  (* Best sum of 2h - lambda * p with at most [budget] T4 pages. *)
  let knapsack lambda =
    let none = (neg_infinity, []) in
    let best = Array.make (budget + 1) (0., []) in
    List.iter
      (fun (name, opts) ->
        let prev = Array.copy best in
        Array.fill best 0 (budget + 1) none;
        Array.iteri
          (fun used (v, picks) ->
            if v > neg_infinity then
              List.iter
                (fun (k, ((h, pr, _, t4) as o)) ->
                  let u = used + t4 in
                  let v = v +. (2. *. float h) -. (lambda *. float pr) in
                  if u <= budget && v > fst best.(u) then best.(u) <- (v, (name, k, o) :: picks))
                opts)
          prev)
      options;
    snd (Array.fold_left (fun a b -> if fst b > fst a then b else a) none best)
  in
  let f1 picks =
    let h, pr = List.fold_left (fun (h, pr) (_, _, (h', pr', _, _)) -> (h + h', pr + pr')) (0, 0) picks in
    2. *. float h /. float (pr + gold)
  in
  let rec go lambda k =
    let picks = knapsack lambda in
    let l = f1 picks in
    if k = 0 || Float.abs (l -. lambda) < 1e-9 then List.rev picks else go l (k - 1)
  in
  go 0. 50

let tuning onto pages =
  print_endline "\n## T1 and thresholds per language, T4 in the loop\n";
  print_endline
    "rich with each (T1 saturation, accept, reject): settled pages serve their T0-T3 labels, the others what T4 served on the stored deep level. Fit: the best overall hF1 with T4 on at most 30% of all pages, allocated across languages.\n";
  let by_group = List.filter_map (fun g -> match List.filter (fun p -> group p = g) pages with [] -> None | ps -> Some (g, ps)) tune_groups in
  let near x l = List.fold_left (fun b y -> if Float.abs (y -. x) < Float.abs (b -. x) then y else b) (List.hd l) l in
  let now g =
    let t = Engine.tuning g in
    (near t.saturation saturations, near t.accept tune_accepts, near t.reject tune_rejects)
  in
  let picks = allocate onto by_group ~budget:(int_of_float (tune_cap *. float (List.length pages))) in
  let prf (h, pr, g, _) = let p = Golden.ratio h pr and r = Golden.ratio h g in (p, r, 2. *. p *. r /. (p +. r)) in
  print_endline "| language | pages | now: saturation, accept, reject | hF1 | T4 | fitted | hP | hR | hF1 | T4 |";
  print_endline "|---|---|---|---|---|---|---|---|---|---|";
  let sum = List.fold_left (fun (a, b, c, d) (a', b', c', d') -> (a + a', b + b', c + c', d + d')) (0, 0, 0, 0) in
  let rows =
    List.map
      (fun (g, ps) ->
        let o_now = outcome onto ps (now g) in
        let _, k, o = List.find (fun (n, _, _) -> n = g) picks in
        let s0, a0, r0 = now g and s, a, r = k in
        let _, _, f0 = prf o_now and hp, hr, hf = prf o in
        let share (_, _, _, t4) = pct (Golden.ratio t4 (List.length ps)) in
        Printf.printf "| %s | %d | %g, %.2f, %.2f | %s | %s | %g, %.2f, %.2f | %s | %s | %s | %s |\n"
          (if g = "" then "others" else g) (List.length ps) s0 a0 r0 (f3n f0) (share o_now) s a r (f3n hp) (f3n hr) (f3n hf) (share o);
        (o_now, o))
      by_group
  in
  let all_now = sum (List.map fst rows) and all = sum (List.map snd rows) in
  let share (_, _, _, t4) = pct (Golden.ratio t4 (List.length pages)) in
  let _, _, f0 = prf all_now and hp, hr, hf = prf all in
  Printf.printf "| all | %d | | %s | %s | | %s | %s | %s | %s |\n" (List.length pages) (f3n f0) (share all_now) (f3n hp) (f3n hr) (f3n hf) (share all)

(* Pages that would not settle on T0-T3's deep scores. *)
let deferral ~accept ~reject pages =
  Golden.ratio (List.length (List.filter (fun p -> not (Cascade.settled { Cascade.deep with accept; reject } p.pre_t4)) pages)) (List.length pages)

let thresholds onto pages =
  let scores = pairs onto pages (fun p -> List.map (fun (l : Label.t) -> (l.id, l.score)) p.pre_t4) in
  let accept = Option.value (Golden.accept_threshold scores) ~default:1.01 and reject = Golden.reject_threshold scores in
  print_endline "\n## Thresholds (T0-T3 scores, deep preset, before T4)\n";
  print_endline "accept: lowest score from which 90% of labels are right; reject: at most 5% of right labels under it.\n";
  print_endline "| | accept | reject | pages T4 would see |";
  print_endline "|---|---|---|---|";
  Printf.printf "| shared until 2026-11-10 | 0.80 | 0.30 | %s |\n" (pct (deferral ~accept:0.8 ~reject:0.3 pages));
  Printf.printf "| fitted | %s | %s | %s |\n" (f3 accept) (f3 reject) (pct (deferral ~accept ~reject pages));
  let right = List.filter snd scores in
  let share f l = Golden.ratio (List.length (List.filter f l)) (List.length l) in
  print_endline "\nWhat a cut costs: right labels a reject threshold drops, and the precision of what an accept threshold freezes.\n";
  print_endline "| cut | 0.05 | 0.10 | 0.20 | 0.30 | 0.50 | 0.70 | 0.80 | 0.90 |";
  print_endline "|---|---|---|---|---|---|---|---|---|";
  let cuts = [ 0.05; 0.1; 0.2; 0.3; 0.5; 0.7; 0.8; 0.9 ] in
  Printf.printf "| right labels under it | %s |\n" (String.concat " | " (List.map (fun c -> pct (share (fun (s, _) -> s < c) right)) cuts));
  Printf.printf "| precision at or above it | %s |\n"
    (String.concat " | " (List.map (fun c -> pct (share snd (List.filter (fun (s, _) -> s >= c) scores))) cuts));
  print_endline "\nPer language: the same fits on each language's pages, and what the shared 0.80 / 0.30 did there (see the next section for today's).\n";
  print_endline "| language | pages | accept | reject | pages T4 would see at 0.80 / 0.30 | precision >= 0.80 | right labels < 0.30 |";
  print_endline "|---|---|---|---|---|---|---|";
  List.iter
    (fun l ->
      let pages = List.filter (fun p -> p.lang = l) pages in
      let scores = pairs onto pages (fun p -> List.map (fun (l : Label.t) -> (l.id, l.score)) p.pre_t4) in
      let accept = Option.value (Golden.accept_threshold scores) ~default:1.01 and reject = Golden.reject_threshold scores in
      Printf.printf "| %s | %d | %s | %s | %s | %s | %s |\n" (if l = "" then "undeclared" else l) (List.length pages) (f3 accept)
        (f3 reject) (pct (deferral ~accept:0.8 ~reject:0.3 pages))
        (pct (share snd (List.filter (fun (s, _) -> s >= 0.8) scores)))
        (pct (share (fun (s, _) -> s < 0.3) (List.filter snd scores))))
    (List.sort_uniq compare (List.map (fun p -> p.lang) pages))

let () =
  let data = ref "data" and valkey = ref "valkey://localhost:6379" and file = ref "" and cache = ref "store/golden" in
  Arg.parse
    [ ("--data", Arg.Set_string data, "DIR (data)");
      ("--valkey", Arg.Set_string valkey, "URI where the crawled profiles are");
      ("--judgements", Arg.Set_string file, "FILE the lab's /api/adjudication.tsv");
      ("--cache", Arg.Set_string cache, "DIR fetched pages and images (store/golden)") ]
    ignore "golden [options] > report.md";
  if !file = "" then failwith "--judgements is required";
  if not (Sys.file_exists !cache) then Sys.mkdir !cache 0o755;
  let e = Engine.load !data in
  Lwt_main.run
    (let* profiles = stored_profiles (Valkey.create !valkey) in
     let judged = List.filter (fun (url, _) -> List.exists (fun (p : Profile.t) -> p.url = url) profiles) (judgements !file) in
     let* fetched = fetch_all ~cache:!cache (List.map fst judged) in
     let pages =
       List.map
         (fun ((url, _, _) as f) ->
           signals e ~gold:(List.assoc url judged) ~profile:(List.find (fun (p : Profile.t) -> p.url = url) profiles) f)
         fetched
     in
     Printf.printf "# Golden set\n\n%d judged pages with a stored profile, %d re-fetched, %d judged labels. Offline tables: pipeline version %s.\n\n"
       (List.length judged) (List.length pages) (List.fold_left (fun n p -> n + List.length p.gold) 0 pages) e.version;
     presets e.onto pages;
     today e.onto pages;
     grid e.onto pages;
     shortlist_recall pages;
     calibration e.onto pages;
     thresholds e.onto pages;
     tuning e.onto pages;
     Lwt.return_unit)
