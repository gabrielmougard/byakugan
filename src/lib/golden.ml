(* Golden-set statistics: a judge's labels per page are the truth, scores
   come from a tier or a level. *)

let closure onto ids = List.sort_uniq compare (List.concat_map (Ontology.ancestors onto) ids)

type overlap = { hit : int; predicted : int; gold : int }

(* Hierarchical precision and recall (Kiritchenko et al. 2005): both sets
   closed under ancestors, so Soccer for Football still earns Sports. *)
let overlap onto ~gold ~predicted =
  let g = closure onto gold and p = closure onto predicted in
  { hit = List.length (List.filter (fun x -> List.mem x g) p); predicted = List.length p; gold = List.length g }

let ratio a b = if b = 0 then Float.nan else float a /. float b

(* Micro-averaged precision, recall and F1. *)
let prf overlaps =
  let sum f = List.fold_left (fun acc o -> acc + f o) 0 overlaps in
  let hit = sum (fun o -> o.hit) in
  let p = ratio hit (sum (fun o -> o.predicted)) and r = ratio hit (sum (fun o -> o.gold)) in
  (p, r, if p +. r = 0. then 0. else 2. *. p *. r /. (p +. r))

(* Expected calibration error over (score, truth) pairs, 10 equal bins. *)
let ece pairs =
  let n = float (List.length pairs) in
  let bins = Array.make 10 (0., 0., 0.) in
  List.iter
    (fun (s, y) ->
      let b = max 0 (min 9 (int_of_float (s *. 10.))) in
      let m, conf, hits = bins.(b) in
      bins.(b) <- (m +. 1., conf +. s, if y then hits +. 1. else hits))
    pairs;
  Array.fold_left (fun acc (m, conf, hits) -> if m = 0. then acc else acc +. (Float.abs (hits -. conf) /. n)) 0. bins

let log_loss f pairs =
  List.fold_left
    (fun acc (x, t) ->
      let p = Float.min (1. -. 1e-12) (Float.max 1e-12 (f x)) in
      acc -. ((t *. log p) +. ((1. -. t) *. log (1. -. p))))
    0. pairs

(* Platt (1999): y ~ sigmoid(a x + b), fitted by Newton's method with step
   halving, on his smoothed targets so separable data stays finite. *)
let fit_platt pairs =
  let pos = float (List.length (List.filter snd pairs)) in
  let neg = float (List.length pairs) -. pos in
  let hi = (pos +. 1.) /. (pos +. 2.) and lo = 1. /. (neg +. 2.) in
  let pairs = List.map (fun (x, y) -> (x, if y then hi else lo)) pairs in
  let loss a b = log_loss (Tier.platt ~a ~b) pairs in
  let rec step a b k =
    let ga, gb, haa, hab, hbb =
      List.fold_left
        (fun (ga, gb, haa, hab, hbb) (x, t) ->
          let p = Tier.platt ~a ~b x in
          let d = p -. t and w = Float.max 1e-12 (p *. (1. -. p)) in
          (ga +. (d *. x), gb +. d, haa +. (w *. x *. x), hab +. (w *. x), hbb +. w))
        (0., 0., 1e-9, 0., 1e-9) pairs
    in
    let det = (haa *. hbb) -. (hab *. hab) in
    let da = ((hbb *. ga) -. (hab *. gb)) /. det and db = ((haa *. gb) -. (hab *. ga)) /. det in
    let before = loss a b in
    let rec halve t = if t < 1e-6 || loss (a -. (t *. da)) (b -. (t *. db)) <= before then t else halve (t /. 2.) in
    let t = halve 1. in
    let a' = a -. (t *. da) and b' = b -. (t *. db) in
    if k = 0 || Float.abs (a' -. a) +. Float.abs (b' -. b) < 1e-7 then (a', b') else step a' b' (k - 1)
  in
  step 0. (log ((pos +. 1.) /. (neg +. 1.))) 100

let logit p =
  let p = Float.min 0.99 (Float.max 0.01 p) in
  log (p /. (1. -. p))

(* Golden-section search for the minimum of a unimodal [f] on [lo, hi]. *)
let minimize f lo hi =
  let g = (sqrt 5. -. 1.) /. 2. in
  let rec search lo hi k =
    if k = 0 then (lo +. hi) /. 2.
    else
      let a = hi -. (g *. (hi -. lo)) and b = lo +. (g *. (hi -. lo)) in
      if f a < f b then search lo b (k - 1) else search a hi (k - 1)
  in
  search lo hi 60

let targets pairs = List.map (fun (x, y) -> (x, if y then 1. else 0.)) pairs

(* Temperature scaling (Guo et al. 2017) of stated confidences:
   sigmoid(logit c / T), T on the log loss. *)
let fit_temperature pairs =
  let pairs = List.map (fun (c, y) -> (logit c, y)) (targets pairs) in
  minimize (fun t -> log_loss (fun z -> 1. /. (1. +. exp (-.z /. t))) pairs) 0.05 20.

(* T1's saturation s in 1 - exp(-raw / s), on the log loss over raw term weights. *)
let fit_saturation pairs =
  let pairs = targets pairs in
  minimize (fun s -> log_loss (fun x -> 1. -. exp (-.x /. s)) pairs) 0.5 100.

let scale_temperature t c = 1. /. (1. +. exp (-.logit c /. t))

(* accept: the lowest score from which at least [precision] of the labels
   are right; reject: the highest score under which at most [miss] of the
   right labels sit.
   accept_threshold [ (0.9, true); (0.8, true); (0.7, false); (0.6, true) ]
   = Some 0.8; reject_threshold ~miss:0.25 over right labels at 0.1, 0.5,
   0.6 and 0.9 = 0.1. *)
let accept_threshold ?(precision = 0.9) pairs =
  let sorted = List.sort (fun (a, _) (b, _) -> compare b a) pairs in
  let _, _, best =
    List.fold_left
      (fun (n, hits, best) (s, y) ->
        let n = n + 1 and hits = if y then hits + 1 else hits in
        (n, hits, if float hits /. float n >= precision then Some s else best))
      (0, 0, None) sorted
  in
  best

let reject_threshold ?(miss = 0.05) pairs =
  let positives = List.sort compare (List.filter_map (fun (s, y) -> if y then Some s else None) pairs) in
  match int_of_float (miss *. float (List.length positives)) with
  | 0 -> 0.
  | allowed -> List.nth positives (allowed - 1)
