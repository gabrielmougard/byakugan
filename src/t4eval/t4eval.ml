(* Which OpenRouter model should run T4? Re-fetches the crawled pages, builds
   each page's real T4 prompt (dry run, deep preset), sends it to every model,
   and scores the answers against reference models:
   - ok: a parseable answer
   - kept: candidates selected with confidence >= 0.5
   - invented: ids outside the shortlist (dropped by Tier.judge)
   - verified: quotes found verbatim on the page (unverified halve confidence)
   - agree: Jaccard of the kept set with each reference's, averaged
   - top1: same most-confident label as the reference
   - $/1k calls, tokens and latency come from OpenRouter's usage report.
   With --judgements (the golden set), the pages are the judged ones whose
   stored profile allows T4, read from golden's cache, and each model is also
   scored against gold (hierarchical, ancestors added):
   - T4 hF1: the labels it keeps
   - deep hP / hR / hF1: what the deep level serves (>= 0.5) with its answers

   t4eval --env .env --data data --valkey valkey://localhost:6379 --ref A --ref B MODEL... > report.md
   t4eval --valkey valkey://localhost:6390 --judgements data/golden_labels.tsv MODEL... > report.md *)

open Contextual
open Serve
open Lwt.Syntax

type page = { url : string; prompt : string; candidates : string list; text : string; doc : Doc.t; gold : Ontology.id list }
type run = { page : page; answer : (Openrouter.answer, string) result }

(* The crawled URLs, from the summaries in Valkey. *)
let urls kv =
  let+ summaries = Lab.summaries kv in
  List.sort compare (List.filter_map (fun j -> Yojson.Safe.Util.(to_string_option (member "url" j))) summaries)

let host url = Option.value (Uri.host (Uri.of_string url)) ~default:""

(* One request at a time per host, one second apart; hosts in parallel. *)
let fetch_all urls =
  let hosts = List.sort_uniq compare (List.map host urls) in
  let+ per_host =
    Lwt_list.map_p
      (fun h ->
        Lwt_list.map_s
          (fun u ->
            let* r = Web.fetch u in
            let+ () = Lwt_unix.sleep 1. in
            match r with Ok { status = 200; body; _ } -> Some (u, body) | _ -> None)
          (List.filter (fun u -> host u = h) urls))
      hosts
  in
  List.filter_map Fun.id (List.concat per_host)

let page_of engine ~gold (url, html) =
  let d = Doc.of_html ~url html in
  match Engine.llm_prompts ~cost:0. engine ~describe:(fun _ -> None) d with
  | [] -> None
  | prompts ->
      let prompt = List.nth prompts (List.length prompts - 1) in
      Some
        { url; prompt; candidates = Tier.prompt_candidates prompt; text = Text.normalize (Doc.all_text d); doc = d;
          gold = Option.value (List.assoc_opt url gold) ~default:[] }

(* The golden set's judged pages that allow T4, from golden's page cache
   (src/store/golden), fetched politely when missing. *)
let judged kv ~file ~cache =
  let gold =
    In_channel.with_open_bin file In_channel.input_lines
    |> List.filter_map (fun l ->
           match String.split_on_char '\t' l with
           | url :: g :: _ when url <> "url" -> Some (url, List.filter (( <> ) "") (String.split_on_char ',' g))
           | _ -> None)
  in
  let* index = Lab.profile_index kv in
  let* bodies = Lwt_list.map_s (Lab.profiles kv) (Lab.chunks 100 (List.map fst index)) in
  let allowed =
    List.filter_map
      (fun b ->
        let p = Profile.of_json (Yojson.Safe.from_string b) in
        if List.mem_assoc p.url gold && String.starts_with ~prefix:"allowed" p.t4_gate then Some p.url else None)
      (List.filter_map Fun.id (List.concat bodies))
  in
  let file url = Filename.concat cache Digestif.SHA256.(to_hex (digest_string url)) in
  let cached = List.filter_map (fun u -> if Sys.file_exists (file u) then Some (u, In_channel.with_open_bin (file u) In_channel.input_all) else None) allowed in
  let+ fetched = fetch_all (List.filter (fun u -> not (List.mem_assoc u cached)) allowed) in
  (gold, cached @ fetched)

let kept r =
  match r.answer with
  | Error _ -> []
  | Ok a ->
      Tier.parse_answer a.content
      |> List.filter (fun (id, c, _) -> c >= 0.5 && List.mem id r.page.candidates)
      |> List.sort (fun (_, a, _) (_, b, _) -> compare b a)

let jaccard a b =
  let a = List.sort_uniq compare a and b = List.sort_uniq compare b in
  let inter = List.length (List.filter (fun x -> List.mem x b) a) in
  let union = List.length a + List.length b - inter in
  if union = 0 then 1. else float inter /. float union

let mean = function [] -> 0. | l -> List.fold_left ( +. ) 0. l /. float (List.length l)
let ids r = List.map (fun (id, _, _) -> id) (kept r)
let top1 r = match kept r with (id, _, _) :: _ -> Some id | [] -> None

let percentile p l =
  match List.sort compare l with [] -> 0. | s -> List.nth s (min (List.length s - 1) (int_of_float (p *. float (List.length s))))

(* Scores against gold: what T4 keeps, and what deep serves with its answers. *)
let against_gold engine runs =
  let onto = engine.Engine.onto in
  let ok = List.filter (fun r -> Result.is_ok r.answer) runs in
  let served r =
    let complete _ = match r.answer with Ok a -> a.Openrouter.content | Error _ -> "" in
    let tiers = Engine.tiers ~llm:{ Engine.complete; cost = 0.; name = "eval" } engine ~describe:(fun _ -> None) in
    let res = Cascade.run onto Cascade.deep tiers r.page.doc in
    List.filter_map (fun (l : Label.t) -> if l.score >= 0.5 then Some l.id else None) res.labels
  in
  let prf f = Golden.prf (List.map (fun r -> Golden.overlap onto ~gold:r.page.gold ~predicted:(f r)) ok) in
  let _, _, t4 = prf ids and p, r, f = prf served in
  Printf.sprintf " %.3f | %.3f | %.3f | %.3f |" t4 p r f

let row ?gold ~refs (model : Openrouter.model) runs =
  let oks = List.filter_map (fun r -> match r.answer with Ok a -> Some (r, a) | Error _ -> None) runs in
  let answers = List.map snd oks in
  let parsed = List.filter (fun (_, (a : Openrouter.answer)) -> Tier.parse_answer a.content <> []) oks in
  let all_ids = List.concat_map (fun (_, (a : Openrouter.answer)) -> Tier.parse_answer a.content) oks in
  let invented = List.filter (fun (id, _, _) -> not (List.exists (fun (r, _) -> List.mem id r.page.candidates) oks)) all_ids in
  let quotes =
    List.concat_map
      (fun (r, (a : Openrouter.answer)) ->
        List.map (fun (_, _, q) -> String.trim q <> "" && Text.contains r.page.text (Text.normalize q)) (Tier.parse_answer a.content))
      oks
  in
  let versus (ref_runs : run list) =
    List.filter_map
      (fun r ->
        match List.find_opt (fun x -> x.page.url = r.page.url && Result.is_ok x.answer) ref_runs with
        | Some x when Result.is_ok r.answer -> Some (jaccard (ids r) (ids x), if top1 r = top1 x then 1. else 0.)
        | _ -> None)
      runs
  in
  let pairs = List.concat_map versus refs in
  let n = float (max 1 (List.length answers)) in
  let agree = if pairs = [] then "-" else Printf.sprintf "%.2f" (mean (List.map fst pairs))
  and top1 = if pairs = [] then "-" else Printf.sprintf "%.0f%%" (100. *. mean (List.map snd pairs)) in
  Printf.sprintf "| `%s` | %.2f / %.2f | %d/%d | %.1f | %d | %.0f%% | %s | %s | %.3f | %.0f / %.0f | %.1f / %.1f |"
    model.id model.prompt_price model.completion_price (List.length parsed) (List.length runs)
    (mean (List.map (fun r -> float (List.length (kept r))) runs))
    (List.length invented)
    (100. *. mean (List.map (fun v -> if v then 1. else 0.) quotes))
    agree top1
    (1000. *. List.fold_left (fun acc (a : Openrouter.answer) -> acc +. a.cost) 0. answers /. n)
    (mean (List.map (fun (a : Openrouter.answer) -> float a.prompt_tokens) answers))
    (mean (List.map (fun (a : Openrouter.answer) -> float a.completion_tokens) answers))
    (percentile 0.5 (List.map (fun (a : Openrouter.answer) -> a.seconds) answers))
    (percentile 0.95 (List.map (fun (a : Openrouter.answer) -> a.seconds) answers))
  ^ match gold with Some engine -> against_gold engine runs | None -> ""

let run_model key ?cheap id pages =
  let* model = Openrouter.find_model ?cheap id in
  let client = { Openrouter.key; model } in
  (* 24 calls in flight at most: hundreds at once draw rate-limit errors. *)
  let+ runs =
    Lwt.map List.concat
      (Lwt_list.map_s
         (Lwt_list.map_p (fun page -> Lwt.map (fun answer -> { page; answer }) (Openrouter.complete client page.prompt)))
         (Lab.chunks 24 pages))
  in
  let errors = List.filter_map (fun r -> match r.answer with Error e -> Some e | Ok _ -> None) runs in
  if errors <> [] then Printf.eprintf "%s: %d errors, first: %s\n%!" id (List.length errors) (List.hd errors);
  (model, runs)

let () =
  let data = ref "data" and valkey = ref "valkey://localhost:6379" and env_file = ref ".env" and refs = ref [] and models = ref [] in
  let judgements = ref "" and cache = ref "store/golden" and cap = ref infinity in
  Arg.parse
    [ ("--data", Arg.Set_string data, "DIR");
      ("--valkey", Arg.Set_string valkey, "URI where the crawled profiles are: their URLs are re-fetched");
      ("--env", Arg.Set_string env_file, "FILE with OPENROUTER_API_KEY");
      ("--ref", Arg.String (fun r -> refs := !refs @ [ r ]), "MODEL reference, default reasoning (repeatable)");
      ("--judgements", Arg.Set_string judgements, "FILE golden labels (url, gold ids): judged pages only, scored against gold");
      ("--cache", Arg.Set_string cache, "DIR golden's page cache (store/golden)");
      ("--cap", Arg.Set_float cap, "USD stop starting models once this much is billed") ]
    (fun m -> models := !models @ [ m ])
    "t4eval [options] MODEL...";
  let key = Openrouter.key ~env_file:!env_file in
  let engine = Engine.load ~vision:false !data in
  Lwt_main.run
    (let kv = Valkey.create !valkey in
     let* gold, fetched =
       if !judgements = "" then Lwt.map (fun f -> ([], f)) (Lwt.bind (urls kv) fetch_all)
       else judged kv ~file:!judgements ~cache:!cache
     in
     let pages = List.filter_map (page_of engine ~gold) fetched in
     Printf.eprintf "%d pages, prompt %.0f chars on average\n%!" (List.length pages)
       (mean (List.map (fun p -> float (String.length p.prompt)) pages));
     let* references = Lwt_list.map_s (fun r -> run_model key ~cheap:false r pages) !refs in
     let ref_runs = List.map snd references in
     let spent runs = List.fold_left (fun acc r -> match r.answer with Ok a -> acc +. a.Openrouter.cost | Error _ -> acc) 0. runs in
     let billed = ref (List.fold_left (fun acc runs -> acc +. spent runs) 0. ref_runs) in
     let* rows =
       Lwt_list.filter_map_s
         (fun m ->
           if !billed >= !cap then (
             Printf.eprintf "%s skipped: $%.4f billed, cap $%.2f\n%!" m !billed !cap;
             Lwt.return_none)
           else
             let+ (model, runs) = run_model key m pages in
             billed := !billed +. spent runs;
             Printf.eprintf "%s: $%.4f, total $%.4f\n%!" m (spent runs) !billed;
             Some (model, runs))
         !models
     in
     let gold_cols = !judgements <> "" in
     let line (m, runs) = row ?gold:(if gold_cols then Some engine else None) ~refs:(List.filter (fun x -> x != runs) ref_runs) m runs in
     print_endline
       ("| model | $/M in / out | ok | kept | invented | verified | agree | top1 | $/1k calls | tokens in / out | s p50 / p95 |"
       ^ if gold_cols then " T4 hF1 | deep hP | deep hR | deep hF1 |" else "");
     print_endline ("|---|---|---|---|---|---|---|---|---|---|---|" ^ if gold_cols then "---|---|---|---|" else "");
     List.iter (fun x -> print_endline (line x)) (references @ rows);
     Lwt.return_unit)
