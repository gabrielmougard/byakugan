type creative = {
  id : string;
  product : string; (* IAB Ad Product Taxonomy 2.0 id: what the ad sells *)
  labels : (Ontology.id * float) list; (* creative + landing page, same cascade, same ontology *)
  keywords : string list;
  targets : Ontology.id list; (* any-of, descendants included *)
  blocks : Ontology.id list; (* none-of, descendants included *)
  avoid_sensitive : bool; (* brand suitability: IAB CT 3.1 "Sensitive Topics" *)
}

type page = { labels : (Ontology.id * float) list; keywords : string list }
type verdict = Blocked of string | Eligible of { score : float; reasons : string list }

let sensitive_topics = "v9i3On"
let present = 0.5
let keyword k = String.trim (Text.normalize k)

let page_of (r : Cascade.result) (d : Doc.t) =
  let fetched = if Lazy.is_val d.content then (Lazy.force d.content).keywords else [] in
  { labels = Label.compact r.labels; keywords = List.map keyword (d.hints @ fetched) }

let deepest_under onto (p : page) root =
  let depth (id, _) = List.length (Ontology.ancestors onto id) in
  List.filter (fun (id, s) -> s >= present && Ontology.is_under onto id ~root) p.labels
  |> List.fold_left (fun best l -> match best with Some b when depth b >= depth l -> best | _ -> Some l) None

(* Hard rules first, each with a reason a trader can read. *)
let refusal onto (p : page) (c : creative) =
  match List.find_map (fun b -> Option.map (fun hit -> (b, hit)) (deepest_under onto p b)) c.blocks with
  | Some (b, (id, s)) ->
      Some (Printf.sprintf "advertiser blocks %s; page is %s (%.2f)" (Ontology.name onto b) (Ontology.path onto id) s)
  | None -> (
      match if c.avoid_sensitive then deepest_under onto p sensitive_topics else None with
      | Some (id, s) -> Some (Printf.sprintf "brand suitability: page is %s (%.2f)" (Ontology.path onto id) s)
      | None ->
          if c.targets <> [] && not (List.exists (fun t -> deepest_under onto p t <> None) c.targets) then
            Some "no targeted category on page"
          else None)

(* Best page-label x creative-label pair, discounted by taxonomy distance
   (Broder et al. 2007 back off through the lowest common ancestor the same way). *)
let topical onto (p : page) (c : creative) =
  List.fold_left
    (fun best (pid, ps) ->
      List.fold_left
        (fun ((v, _) as best) (cid, cs) ->
          let v' = ps *. cs *. Ontology.similarity onto pid cid in
          if v' > v then (v', Some (pid, cid)) else best)
        best c.labels)
    (0., None) p.labels

let keyword_overlap (p : page) (c : creative) =
  let wanted = List.map keyword c.keywords in
  let hits = List.filter (fun k -> List.mem k p.keywords) wanted in
  match wanted with [] -> (0., []) | _ -> (float (List.length hits) /. float (List.length wanted), hits)

(* Learned offline from engagement logs: lift of a product category on a page
   category, so a new creative inherits what its category already taught us. *)
let lift affinity (p : page) (c : creative) =
  List.fold_left
    (fun ((v, _) as best) (pid, ps) ->
      match Hashtbl.find_opt affinity (c.product, pid) with
      | Some l when ps *. l > v -> (ps *. l, Some pid)
      | _ -> best)
    (0., None) p.labels

(* shortcut: fixed blend. Fit it as a logistic regression on engagement logs
   (Chakrabarti et al. 2008), then explore with a contextual bandit. *)
let score onto ~affinity (p : page) (c : creative) =
  match refusal onto p c with
  | Some why -> Blocked why
  | None ->
      let t, pair = topical onto p c in
      let k, hits = keyword_overlap p c in
      let l, lifted = lift affinity p c in
      let reasons =
        List.filter_map Fun.id
          [ Option.map
              (fun (a, b) -> Printf.sprintf "topic %s ~ %s (%.2f)" (Ontology.path onto a) (Ontology.path onto b) t)
              pair;
            (if hits = [] then None else Some ("keywords: " ^ String.concat ", " hits));
            Option.map
              (fun pid -> Printf.sprintf "lift of product %s on %s (%.2f)" c.product (Ontology.name onto pid) l)
              lifted ]
      in
      Eligible { score = (0.6 *. t) +. (0.25 *. k) +. (0.15 *. l); reasons }

let rank onto ~affinity p creatives =
  let key = function Eligible e -> -.e.score | Blocked _ -> infinity in
  List.map (fun c -> (c, score onto ~affinity p c)) creatives
  |> List.stable_sort (fun (_, a) (_, b) -> compare (key a) (key b))
