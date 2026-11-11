(* Context of one ad slot, not of the whole URL. Offsets are in viewport
   heights from the slot (what a reader sees at once, device-independent):
   negative = above, already scrolled past and read; positive = not seen yet.

     offset  block                     kernel k (reach above 1, below 0.5)
      -2.0   p   main   read already   exp(-2.0 / 1.0) = 0.14
      -0.5   p   main                  exp(-0.5 / 1.0) = 0.61   ┐ co-visible:
       0     ════ slot ════                                     │ |offset| <= 1
      +0.5   li  not main, most read   no topic weight          ┘
      +2.0   p   main   not seen yet   exp(-2.0 / 0.5) = 0.02

     relevance(id)   = page_weight * page(id)
                       + (1 - page_weight) * sum (k * block(id)) / sum k
                       over main blocks; the page alone when there are none
     suitability(id) = max of page(id) and block(id) over co-visible blocks,
                       main or not; Sensitive Topics ids only, and it
                       replaces their relevance *)
type block = {
  offset : float;
  main : bool; (* article text/images; false for comments, related links, sidebars *)
  labels : (Ontology.id * float) list;
}

type geometry = { page_weight : float; reach_above : float; reach_below : float }

(* Formats by where the ad sits against the content, not by product name.
   Map yours onto one:

     fullscreen      covers the page between views: interstitials, takeovers
     scroll-through  a window that opens inside the text as the reader
                     scrolls: interscrollers, scroll reveals
     in-article      sits in the text: MPUs, in-read video, native units
     sticky          stays on screen while the text scrolls under it:
                     anchors, overscrollers
     banner          outside the text: leaderboards, skyscrapers, sidebars

   shortcut: priors, not fitted. Fit page_weight and the reaches per format
   on engagement logs (study/matching.md §5). *)
let formats = [ "fullscreen"; "scroll-through"; "in-article"; "sticky"; "banner" ]

let geometry = function
  | "fullscreen" -> { page_weight = 0.9; reach_above = 1.; reach_below = 0.5 } (* no anchor in the text *)
  | "scroll-through" -> { page_weight = 0.4; reach_above = 1.; reach_below = 0.5 } (* read through the text around it *)
  | _ -> { page_weight = 0.6; reach_above = 1.; reach_below = 0.5 }

(* What a reader sees together with the ad. *)
let co_visible = 1.

let kernel g d = exp (-.Float.abs d /. if d < 0. then g.reach_above else g.reach_below)
let score_in labels id = Option.value (List.assoc_opt id labels) ~default:0.

let ids_of lists = List.sort_uniq compare (List.concat_map (List.map fst) lists)

(* Relevance: page prior blended with nearby main content, decaying with
   distance, slower upwards (read) than downwards (unseen). *)
let relevance g (page : Matcher.page) blocks =
  let main = List.filter (fun b -> b.main) blocks in
  let total = List.fold_left (fun acc b -> acc +. kernel g b.offset) 0. main in
  if total = 0. then page.labels
  else
    let local id = List.fold_left (fun acc b -> acc +. (kernel g b.offset *. score_in b.labels id)) 0. main /. total in
    List.map
      (fun id -> (id, (g.page_weight *. score_in page.labels id) +. ((1. -. g.page_weight) *. local id)))
      (ids_of (page.labels :: List.map (fun b -> b.labels) main))

(* Suitability never averages: worst of the page and of everything co-visible,
   comments and "most read" widgets included, because that is what a
   screenshot of the ad would show. *)
let adjacency onto (page : Matcher.page) blocks =
  let visible = List.filter (fun b -> Float.abs b.offset <= co_visible) blocks in
  let lists = page.labels :: List.map (fun b -> b.labels) visible in
  List.filter_map
    (fun id ->
      if Ontology.is_under onto id ~root:Matcher.sensitive_topics then
        Some (id, List.fold_left (fun acc l -> Float.max acc (score_in l id)) 0. lists)
      else None)
    (ids_of lists)

let context onto ~format (page : Matcher.page) blocks =
  let unsafe = adjacency onto page blocks in
  let relevant = List.filter (fun (id, _) -> not (List.mem_assoc id unsafe)) (relevance (geometry format) page blocks) in
  { page with labels = relevant @ unsafe }

(* At bid time the browser says which blocks surround the slot (sdks/prebid:
   ortb2Imp.ext.data.ctx), each as (SimHash of its words, offset in
   viewports); they are matched to the profile's blocks (Profile.blocks) by
   the nearest SimHash within 3 bits. A block the profile does not know
   counts as main content without labels: it still dilutes the
   neighbourhood. sdks/go LocalContext does the same. *)
let of_wire known wire =
  List.map
    (fun (hash, offset) ->
      let best =
        List.fold_left
          (fun best (h, main, labels) ->
            let d = Refresh.distance h hash in
            match best with Some (d', _, _) when d' <= d -> best | _ when d > 3 -> best | _ -> Some (d, main, labels))
          None known
      in
      match best with
      | Some (_, main, labels) -> { offset; main; labels }
      | None -> { offset; main = true; labels = [] })
    wire
