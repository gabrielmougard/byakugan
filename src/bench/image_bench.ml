(* How SigLIP 2 reads the images publishers put on their pages. Reads
   "url" or "url<TAB>impressions" lines (src/data/golden_sample.tsv; a
   missing count is 1), takes the [--pages] pages with the most impressions
   of each host, and for each page: the text-only labels of the standard
   preset, then up to three images without alt text (Tier.undescribed),
   fetched, decoded and embedded, with their top zero-shot nodes. robots.txt is honoured for pages and images; one request
   per second per origin, origins in parallel. No T4.
     image_bench --data DIR [--pages 2] [--max-patches 256] [--threads 4] < sample.tsv *)

open Contextual
open Serve
open Lwt.Syntax

type image = { page : string; src : string; outcome : string; ms : float; labels : (string * float) list; text_root : string; image_root : string }

let host url = Option.value (Uri.host (Uri.of_string url)) ~default:""
let resolve base src = Uri.to_string (Uri.resolve "" (Uri.of_string base) (Uri.of_string src))

let polite url ~headers =
  let* () = Lwt_unix.sleep 1. in
  Web.fetch ~headers url

let root onto id = List.hd (List.rev (id :: Ontology.ancestors onto id))

(* The tier-1 node holding most of the image's probability mass, the mass
   being a softmax over every node's SigLIP logit. *)
let image_root onto ids p =
  let mass = Hashtbl.create 64 in
  let logit x = log (x /. (1. -. x)) in
  let m = Array.fold_left (fun a x -> max a (logit x)) neg_infinity p in
  Array.iteri (fun j x -> let r = root onto ids.(j) in Hashtbl.replace mass r (exp (logit x -. m) +. Option.value (Hashtbl.find_opt mass r) ~default:0.)) p;
  fst (Hashtbl.fold (fun r v (br, bv) -> if v > bv then (r, v) else (br, bv)) mass ("", neg_infinity))

let text_root onto e d =
  let levels = Engine.levels e ~describe:(fun _ -> None) d in
  let std = (List.find (fun (l : Profile.level) -> l.preset = "standard") levels).result.labels in
  match List.sort (fun (a : Label.t) b -> compare b.score a.score) std with
  | l :: _ -> root onto l.id
  | [] -> ""

let check_page pool e (v : Engine.vision) ~max_patches ~threads url =
  let* page_ok = Web.allowed url in
  if not page_ok then Lwt.return []
  else
    let* r = polite url ~headers:[] in
    match r with
    | Ok { status = 200; body; _ } ->
        let d = Doc.of_html ~url body in
        let onto = e.Engine.onto in
        let troot = text_root onto e d in
        Lwt_list.map_s
          (fun (m : Doc.media) ->
            let src = resolve url m.src in
            let base = { page = url; src; outcome = ""; ms = 0.; labels = []; text_root = troot; image_root = "" } in
            let* ok = Web.allowed src in
            if not ok then Lwt.return { base with outcome = "robots" }
            else
              let* r = polite src ~headers:[ "Accept: image/webp,image/png,image/jpeg;q=0.9,*/*;q=0.1" ] in
              match r with
              | Ok { status = 200; body; content_type; _ } -> (
                  let t0 = Unix.gettimeofday () in
                  let+ emb = Web.detach pool (fun b -> Siglip.embed v.model b ~max_patches ~min_side:v.min_side ~threads) body in
                  let ms = (Unix.gettimeofday () -. t0) *. 1000. in
                  match emb with
                  | Error why -> { base with outcome = why ^ " " ^ content_type }
                  | Ok emb ->
                      let p = Siglip.zero_shot v.model v.protos emb in
                      let labels = List.sort (fun (_, a, _) (_, b, _) -> compare b a) (Engine.image_labels e v emb) in
                      { base with outcome = "ok " ^ content_type; ms;
                        labels = List.map (fun (id, s, _) -> (Ontology.path onto id, s)) (List.filteri (fun i _ -> i < 3) labels);
                        image_root = image_root onto v.protos.ids p })
              | Ok { status; _ } -> Lwt.return { base with outcome = Printf.sprintf "HTTP %d" status }
              | Error err -> Lwt.return { base with outcome = err })
          (Tier.undescribed [ Doc.Image ] d)
    | _ -> Lwt.return []

(* Embedding time alone, one image after another: each budget x thread count,
   best of 3 runs per image. *)
let time_images (v : Engine.vision) files =
  let images = List.map (fun f -> In_channel.with_open_bin f In_channel.input_all) files in
  List.iter
    (fun max_patches ->
      List.iter
        (fun threads ->
          let per =
            List.map
              (fun b ->
                List.fold_left min infinity
                  (List.init 3 (fun _ ->
                       let t0 = Unix.gettimeofday () in
                       ignore (Siglip.embed v.model b ~max_patches ~min_side:1 ~threads);
                       (Unix.gettimeofday () -. t0) *. 1000.)))
              images
          in
          Printf.printf "max_patches %d, %d thread(s): %.0f ms per image\n%!" max_patches threads
            (List.fold_left ( +. ) 0. per /. float (List.length per)))
        [ 1; 4 ])
    [ 256; 128; 64 ]

let () =
  let data = ref "data" and per = ref 2 and max_patches = ref 256 and threads = ref 4 and time = ref [] in
  Arg.parse
    [ ("--data", Arg.Set_string data, "DIR with the models");
      ("--pages", Arg.Set_int per, "N pages per host, most impressions first");
      ("--max-patches", Arg.Set_int max_patches, "N NaFlex patch budget");
      ("--threads", Arg.Set_int threads, "N ggml threads per image");
      ("--time", Arg.Rest (fun f -> time := !time @ [ f ]), "FILE... time the embedding of these images instead") ]
    ignore "image_bench --data DIR < sample.tsv";
  let e = Engine.load !data in
  let v = Option.get e.vision in
  if !time <> [] then (time_images v !time; exit 0);
  let pool = Web.setup_pool () in
  let pages =
    In_channel.input_lines stdin
    |> List.filter_map (fun l -> match String.split_on_char '\t' l with [ u; n ] -> Some (u, float_of_string n) | [ u ] when u <> "" -> Some (u, 1.) | _ -> None)
  in
  let by_host = Hashtbl.create 64 in
  List.iter (fun (u, n) -> Hashtbl.replace by_host (host u) ((u, n) :: Option.value (Hashtbl.find_opt by_host (host u)) ~default:[])) pages;
  let picked =
    Hashtbl.fold (fun h l acc -> (h, List.filteri (fun i _ -> i < !per) (List.sort (fun (_, a) (_, b) -> compare b a) l)) :: acc) by_host []
  in
  let images =
    Lwt_main.run
      (Lwt_list.map_p
         (fun (_, l) -> Lwt_list.map_s (fun (u, _) -> check_page pool e v ~max_patches:!max_patches ~threads:!threads u) l)
         picked)
    |> List.concat |> List.concat
  in
  List.iter
    (fun i ->
      Printf.printf "%s\t%s\t%s\t%.0f ms\ttext %s\timage %s\t%s\n" (host i.page) (Filename.extension (Uri.path (Uri.of_string i.src))) i.outcome i.ms (Ontology.name e.onto i.text_root)
        (Ontology.name e.onto i.image_root)
        (String.concat "; " (List.map (fun (p, x) -> Printf.sprintf "%s %.3f" p x) i.labels)))
    images;
  let ok = List.filter (fun i -> String.starts_with ~prefix:"ok" i.outcome) images in
  let times = List.sort compare (List.map (fun i -> i.ms) ok) in
  let nth q = if times = [] then 0. else List.nth times (min (List.length times - 1) (int_of_float (q *. float (List.length times)))) in
  let agree = List.length (List.filter (fun i -> i.text_root <> "" && i.text_root = i.image_root) ok) in
  let with_text = List.length (List.filter (fun i -> i.text_root <> "") ok) in
  Printf.printf "# %d images on %d pages; %d embedded, %d undecodable, %d under the minimum size\n" (List.length images)
    (List.length (List.sort_uniq compare (List.map (fun i -> i.page) images)))
    (List.length ok)
    (List.length (List.filter (fun i -> String.starts_with ~prefix:"undecodable" i.outcome) images))
    (List.length (List.filter (fun i -> String.starts_with ~prefix:"small" i.outcome) images));
  Printf.printf "# embed ms (fetch excluded): median %.0f, p90 %.0f\n" (nth 0.5) (nth 0.9);
  Printf.printf "# image tier-1 = text tier-1 on %d of %d images with text labels\n" agree with_text;
  let labelled = List.filter (fun i -> i.labels <> []) ok in
  let first_root i = match i.labels with (p, _) :: _ -> List.hd (String.split_on_char '>' p) |> String.trim | [] -> "" in
  let agree_labelled = List.length (List.filter (fun i -> i.text_root <> "" && Ontology.name e.onto i.text_root = first_root i) labelled) in
  Printf.printf "# %d images get a label >= 0.3; its tier-1 = text tier-1 on %d of %d with text labels\n" (List.length labelled)
    agree_labelled (List.length (List.filter (fun i -> i.text_root <> "") labelled))
