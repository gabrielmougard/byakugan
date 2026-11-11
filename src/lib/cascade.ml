(* The cascade: tiers in the order given (Engine.tiers puts them in cost
   order), each paid for only while the page is in doubt.

     T0 url+hints ─▶ T1 lexical ─▶ T2 dense ─▶ T3 media ─▶ T3 images ─▶ T4 llm
     $0              $1e-6         $5e-6       $1e-4/item  $1e-4/item   per call

   Before each tier:
     settled?                      ──▶ stop: Settled
     no tier left?                 ──▶ stop: Exhausted
     tier does not apply?          ──▶ skip it, free
     spent + its cost > budget?    ──▶ stop: Out_of_budget (no later tier tried)
     else run it, Label.update, next tier

   A page is settled once some label is >= accept and none sits between
   reject and accept: every remaining doubt is what the next, costlier tier
   is paid for.

     0 ─────────── reject ──────────────────── accept ─────────── 1
       dropped by          doubtful: keeps the        frozen: later
       Label.finalize      cascade going              tiers leave it *)
type policy = { budget : float; accept : float; reject : float }
type stop = Settled | Out_of_budget | Exhausted
type result = { labels : Label.t list; spent : float; ran : string list; stop : stop }

(* accept and reject here are defaults: Engine.levels sets them per page
   language (Engine.tunings), all but deep's. rich's budget is the most a
   page gets; the crawler spends what the page earns (value_budget). *)
let zero_fetch = { budget = 0.; accept = 0.8; reject = 0.3 }
let standard = { zero_fetch with budget = 1e-5 }
let rich = { zero_fetch with budget = 5e-4 }

(* accept > 1: nothing freezes, nothing settles, every affordable tier re-checks.
   For golden sets and audits. *)
let deep = { budget = 1e-2; accept = 1.01; reject = 0.3 }

(* Depth follows money: spend at most [share] of what the page should earn
   over [days]. A long-tail URL gets T0-T1, a hot article can afford T4.
   value_budget ~daily_impressions:1000. ~cpm:2. () = 0.14;
   value_budget ~daily_impressions:5. ~cpm:2. () = 0.0007. *)
let value_budget ?(share = 0.01) ?(days = 7.) ~daily_impressions ~cpm () =
  share *. daily_impressions *. days *. cpm /. 1000.

let settled p labels =
  List.exists (fun (l : Label.t) -> l.score >= p.accept) labels
  && not (List.exists (fun (l : Label.t) -> l.score > p.reject && l.score < p.accept) labels)

let run onto p tiers doc =
  let finish labels spent ran stop =
    { labels = Label.finalize onto ~reject:p.reject labels; spent; ran = List.rev ran; stop }
  in
  let rec go labels spent ran = function
    | _ when settled p labels -> finish labels spent ran Settled
    | [] -> finish labels spent ran Exhausted
    | (t : Tier.t) :: rest when not (t.applies doc) -> go labels spent ran rest
    | (t : Tier.t) :: rest ->
        let cost = t.cost doc in
        if spent +. cost > p.budget then finish labels spent ran Out_of_budget
        else
          let labels = Label.update ~accept:p.accept t.mode labels (t.run doc labels) in
          go labels (spent +. cost) (t.name :: ran) rest
  in
  go [] 0. [] tiers

let stop_name = function
  | Settled -> "settled"
  | Out_of_budget -> "out of budget"
  | Exhausted -> "no more tiers"

let explain onto r =
  String.concat "\n"
    (Printf.sprintf "tiers: %s | spent $%.6f | stop: %s" (String.concat " -> " r.ran) r.spent (stop_name r.stop)
    :: List.map (Label.explain onto) r.labels)
