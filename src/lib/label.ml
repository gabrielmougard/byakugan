type evidence = {
  tier : string;
  zone : string; (* where it was seen: title, body, url, model-text, semantic, llm... *)
  quote : string; (* verbatim page text, except model-text (a model's own output) *)
  why : string;
  weight : float;
}

type t = { id : Ontology.id; score : float; evidence : evidence list }

(* Accumulate: independent evidence (another zone, another modality turned to
   text). Noisy-OR, which equals adding raw lexical scores under 1 - exp(-raw/k):
   0.5 then 0.5 gives 0.75.
   Override: a better-calibrated model's verdict replaces the score.
   Either way a label already >= accept is frozen: cheaper tiers decided it. *)
type mode = Accumulate | Override

let update ~accept mode prior fresh =
  let table = Hashtbl.create 64 in
  List.iter (fun l -> Hashtbl.replace table l.id l) prior;
  List.iter
    (fun f ->
      match Hashtbl.find_opt table f.id with
      | Some p when p.score >= accept -> ()
      | Some p ->
          let score =
            match mode with
            | Accumulate -> 1. -. ((1. -. p.score) *. (1. -. f.score))
            | Override -> f.score
          in
          Hashtbl.replace table f.id { f with score; evidence = p.evidence @ f.evidence }
      | None -> Hashtbl.replace table f.id f)
    fresh;
  List.of_seq (Hashtbl.to_seq_values table)

(* A page about Soccer is about Sports: ancestors get their best child's score,
   so online targeting never walks the tree. *)
let with_ancestors onto labels =
  let table = Hashtbl.create 64 in
  List.iter (fun l -> Hashtbl.replace table l.id l) labels;
  List.iter
    (fun l ->
      let via =
        { tier = "hierarchy"; zone = "ontology"; quote = Ontology.name onto l.id; why = "child label"; weight = l.score }
      in
      let up = match Ontology.ancestors onto l.id with _ :: up -> up | [] -> [] in
      List.iter
        (fun a ->
          match Hashtbl.find_opt table a with
          | Some p when p.score >= l.score -> ()
          | Some p -> Hashtbl.replace table a { p with score = l.score; evidence = p.evidence @ [ via ] }
          | None -> Hashtbl.replace table a { id = a; score = l.score; evidence = [ via ] })
        up)
    labels;
  List.of_seq (Hashtbl.to_seq_values table)

(* Highest score first; on a tie, ancestors before descendants. An ancestor
   scores at least as high as its children, so any prefix of this order
   keeps every label's ancestors: the Go SDK (sdks/go) relies on it to check
   a category by its id alone in the 20 labels the bidder reads. *)
let finalize onto ~reject labels =
  let depth id = List.length (Ontology.ancestors onto id) in
  List.filter (fun l -> l.score > reject) labels
  |> with_ancestors onto
  |> List.sort (fun a b -> compare (b.score, depth a.id, a.id) (a.score, depth b.id, b.id))

let compact labels = List.map (fun l -> (l.id, l.score)) labels

(* The latest evidence is the decisive one: costlier tiers come last. *)
let explain onto l =
  let line e = Printf.sprintf "      [%s/%s] %s: %S" e.tier e.zone e.why e.quote in
  let n = List.length l.evidence in
  let earlier = if n > 4 then [ Printf.sprintf "      (+%d earlier)" (n - 4) ] else [] in
  String.concat "\n"
    ((Printf.sprintf "  %.2f  %s" l.score (Ontology.path onto l.id) :: earlier)
    @ List.map line (List.filteri (fun i _ -> i >= n - 4) l.evidence))
