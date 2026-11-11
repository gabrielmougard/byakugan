(* Lexicon candidates for people to review. For each node:
   - terms from an LLM in the languages served, TELEClass-style: the
     prompt names the node's path, children and siblings, so the terms tell
     it apart from its neighbours;
   - Wikidata labels and aliases in the same languages, when an entity's
     English label is the node's name.
   Writes "id<TAB>term<TAB>weight<TAB>language<TAB>source" lines on stdout.
   Nothing here feeds the classifier: reviewed lines go into data/lexicon.tsv.

   --review LANG reads those candidates back and asks the model, one call per
   node, which of them a reader of LANG would keep. It can drop a term or
   change its weight, never add one, so every kept line is a candidate.
   Writes "id<TAB>term<TAB>weight<TAB>LANG" lines for lexicon.tsv.

   lexgen.exe [--data DIR] [--env FILE] [--model ID] [--review LANG] [ID...]
   Without ids: the 37 tier-1 nodes and the Sensitive Topics; with --review,
   every node that has candidates in LANG. *)

open Contextual
open Serve
open Lwt.Syntax

let languages = [ "en"; "it"; "fr"; "de"; "es" ]
let sensitive_topics = "v9i3On"

let children onto id = List.filter (fun c -> (Hashtbl.find onto.Ontology.nodes c).parent = Some id) (Ontology.ids onto)

let siblings onto id =
  match (Hashtbl.find onto.Ontology.nodes id).parent with
  | Some p -> List.filter (( <> ) id) (children onto p)
  | None -> List.filter (( <> ) id) (Ontology.roots onto)

let names onto ids = String.concat "; " (List.sort compare (List.map (Ontology.name onto) ids))

let prompt onto id =
  Printf.sprintf
    {|You build a keyword lexicon for a web page classifier that uses the IAB Content Taxonomy 3.1.

Category: %s
Its subcategories: %s
Sibling categories, which the terms must not also indicate: %s

For each language (%s), list 15 to 25 words or short phrases (at most 4 words) that, found in a news, sport or magazine page, are strong evidence that the page is about this category. Prefer specific terms over generic ones. Leave out terms that fit a sibling category as well, and terms that are only the category name translated. Write terms in lowercase, with the language's own spelling and accents.

Weight each term: 2 = enough on its own, 1 = strong evidence, 0.5 = supporting evidence.

Answer with JSON only: {"en": [["term", 1], ...], "it": [...], "fr": [...], "de": [...], "es": [...]}|}
    (Ontology.path onto id)
    (match children onto id with [] -> "none" | c -> names onto c)
    (names onto (siblings onto id))
    (String.concat ", " languages)

let clean term = String.trim (String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) term)

let llm_terms client onto id =
  let+ r = Openrouter.complete ~max_tokens:4000 client (prompt onto id) in
  match r with
  | Error e ->
      Printf.eprintf "%s: %s\n%!" id e;
      ([], 0.)
  | Ok a ->
      let module J = Yojson.Safe.Util in
      let terms lang =
        match J.member lang (Yojson.Safe.from_string a.content) with
        | `List l ->
            List.filter_map
              (function
                | `List [ `String t; w ] when clean t <> "" -> (
                    match J.to_number_option w with Some w -> Some (clean t, w, lang) | None -> None)
                | _ -> None)
              l
        | _ -> []
        | exception _ -> []
      in
      (List.concat_map terms languages, a.cost)

let language_names = [ ("en", "English"); ("it", "Italian"); ("fr", "French"); ("de", "German"); ("es", "Spanish") ]

let review_prompt onto id lang terms =
  let language = List.assoc lang language_names in
  Printf.sprintf
    {|You review a keyword lexicon for a web page classifier that uses the IAB Content Taxonomy 3.1. You are a native reader of %s.

Category: %s
Its subcategories: %s
Sibling categories: %s

A term fires when its words appear anywhere in a %s news, sport or magazine page (whole words; case and accents ignored), and then counts as evidence that the page is about this category. Candidate terms, with their weight (2 = enough on its own, 1 = strong evidence, 0.5 = supporting evidence):
%s

Keep a term only if a %s journalist would use it, and finding it on a page is real evidence that the page is about this category. Drop it when:
- it is an everyday %s word or phrase with other common meanings, or turns up in many pages on other topics;
- it points to a sibling category more than to this one;
- it is not %s, unless %s pages use it as is;
- it is misspelled, or a translation no %s writer would use.
%sFix a weight only when it is clearly wrong; weights are 2, 1 or 0.5.

Answer with JSON only, copying kept terms exactly as written above: {"keep": [["term", 1], ...]}|}
    language (Ontology.path onto id)
    (match children onto id with [] -> "none" | c -> names onto c)
    (names onto (siblings onto id))
    language
    (String.concat "\n" (List.map (fun (t, w) -> Printf.sprintf "%s\t%g" t w) terms))
    language language language language language
    (if Ontology.is_under onto id ~root:sensitive_topics then
       "This is a brand-safety category, where missing a page costs more than a false alarm: keep terms an advertiser would want flagged even when they are only weak evidence alone (weight 0.5).\n"
     else "")

(* The model's kept terms, restricted to the candidates. *)
let review client onto id lang terms =
  let+ r = Openrouter.complete ~max_tokens:4000 client (review_prompt onto id lang terms) in
  match r with
  | Error e ->
      Printf.eprintf "%s: %s\n%!" id e;
      ([], 0.)
  | Ok a ->
      let module J = Yojson.Safe.Util in
      let kept =
        match J.member "keep" (Yojson.Safe.from_string a.content) with
        | `List l ->
            List.filter_map
              (function
                | `List [ `String t; w ] -> (
                    match List.assoc_opt (clean t) terms with
                    | Some w0 ->
                        let w = Option.value (J.to_number_option w) ~default:w0 in
                        Some (clean t, if List.mem w [ 2.; 1.; 0.5 ] then w else w0)
                    | None -> None)
                | _ -> None)
              l
        | _ -> []
        | exception _ -> []
      in
      (List.sort_uniq (fun (a, _) (b, _) -> compare a b) kept, a.cost)

(* Candidates in [lang] per node, first weight of each term, file order. *)
let candidates file lang =
  let by_node = Hashtbl.create 64 and order = ref [] in
  In_channel.with_open_text file In_channel.input_lines
  |> List.iter (fun line ->
         match String.split_on_char '\t' line with
         | id :: term :: weight :: l :: _ when l = lang -> (
             let terms = Option.value (Hashtbl.find_opt by_node id) ~default:[] in
             if terms = [] then order := id :: !order;
             match float_of_string_opt weight with
             | Some w when not (List.mem_assoc term terms) -> Hashtbl.replace by_node id (terms @ [ (term, w) ])
             | _ -> ())
         | _ -> ());
  List.rev_map (fun id -> (id, Hashtbl.find by_node id)) !order

let review_all client onto ~file ~lang ids =
  let nodes = candidates file lang in
  let nodes = if ids = [] then nodes else List.filter (fun (id, _) -> List.mem id ids) nodes in
  let+ results =
    Lwt_list.map_s
      (Lwt_list.map_p (fun (id, terms) ->
           let+ kept, cost = review client onto id lang terms in
           Printf.eprintf "%s %s: kept %d of %d\n%!" id (Ontology.path onto id) (List.length kept) (List.length terms);
           (id, kept, cost)))
      (Lab.chunks 8 nodes)
  in
  let results = List.concat results in
  List.iter (fun (id, kept, _) -> List.iter (fun (t, w) -> Printf.printf "%s\t%s\t%g\t%s\n" id t w lang) kept) results;
  let total f = List.fold_left (fun n (_, k, c) -> n +. f k c) 0. results in
  Printf.eprintf "%s: kept %.0f of %d terms over %d nodes, $%.4f\n" lang
    (total (fun k _ -> float (List.length k)))
    (List.fold_left (fun n (_, t) -> n + List.length t) 0 nodes)
    (List.length nodes) (total (fun _ c -> c))

let wikidata = "https://www.wikidata.org/w/api.php?format=json&"

let get_json url =
  let+ r = Web.fetch url in
  match r with Ok { status = 200; body; _ } -> ( try Some (Yojson.Safe.from_string body) with _ -> None) | _ -> None

(* Labels and aliases of the entity whose English label is the node's name. *)
let wikidata_terms onto id =
  let module J = Yojson.Safe.Util in
  let name = Ontology.name onto id in
  let enc = Uri.pct_encode ~component:`Query_value in
  let* search = get_json (wikidata ^ "action=wbsearchentities&language=en&limit=5&search=" ^ enc name) in
  let hit =
    Option.bind search (fun j ->
        List.find_opt
          (fun e -> String.lowercase_ascii (J.to_string (J.member "label" e)) = String.lowercase_ascii name)
          (try J.to_list (J.member "search" j) with _ -> []))
  in
  match hit with
  | None -> Lwt.return []
  | Some e ->
      let q = J.to_string (J.member "id" e) in
      let+ entity =
        get_json
          (wikidata ^ "action=wbgetentities&props=labels%7Caliases&languages=" ^ String.concat "%7C" languages ^ "&ids=" ^ q)
      in
      let entity = Option.map (fun j -> J.member q (J.member "entities" j)) entity in
      let values field lang =
        match entity with
        | None -> []
        | Some e -> (
            match J.member lang (J.member field e) with
            | `List l -> List.map (fun v -> J.to_string (J.member "value" v)) l
            | `Assoc _ as v -> [ J.to_string (J.member "value" v) ]
            | _ -> [])
      in
      List.concat_map
        (fun lang ->
          List.map (fun t -> (clean (String.lowercase_ascii t), 1., lang)) (values "labels" lang @ values "aliases" lang))
        languages
      |> List.map (fun (t, w, l) -> (t, w, l, "wikidata:" ^ q))

let () =
  let data = ref "data" and env_file = ref ".env" and model = ref "deepseek/deepseek-v4.1-flash-1017" and ids = ref [] in
  let lang = ref "" in
  Arg.parse
    [ ("--data", Arg.Set_string data, "DIR taxonomy (data)");
      ("--env", Arg.Set_string env_file, "FILE holding OPENROUTER_API_KEY=... (.env)");
      ("--model", Arg.Set_string model, "ID OpenRouter model (deepseek/deepseek-v4.1-flash-1017)");
      ("--review", Arg.Set_string lang, "LANG review DIR/lexicon_candidates.tsv in LANG instead of generating") ]
    (fun id -> ids := id :: !ids)
    "lexgen [options] [id ...]";
  if !lang <> "" && not (List.mem_assoc !lang language_names) then failwith ("--review: no language " ^ !lang);
  let onto =
    let read f = In_channel.with_open_bin (Filename.concat !data f) In_channel.input_all in
    Ontology.of_tsv ~taxonomy:(read "content_taxonomy_3.1.tsv") ~lexicon:""
  in
  if !lang <> "" then begin
    let key = Openrouter.key ~env_file:!env_file in
    Lwt_main.run
      (let* m = Openrouter.find_model !model in
       review_all { Openrouter.key; model = m } onto ~file:(Filename.concat !data "lexicon_candidates.tsv") ~lang:!lang
         (List.rev !ids));
    exit 0
  end;
  let ids =
    match List.rev !ids with
    | [] -> List.sort compare (List.filter (( <> ) sensitive_topics) (Ontology.roots onto)) @ children onto sensitive_topics
    | l -> l
  in
  let key = Openrouter.key ~env_file:!env_file in
  Lwt_main.run
    (let* m = Openrouter.find_model !model in
     let client = { Openrouter.key; model = m } in
     let* spent =
       Lwt_list.fold_left_s
         (fun spent id ->
           let* llm, cost = llm_terms client onto id in
           let+ wiki = wikidata_terms onto id in
           let seen = Hashtbl.create 64 in
           List.iter
             (fun (term, weight, lang, source) ->
               if not (Hashtbl.mem seen (lang, term)) then begin
                 Hashtbl.add seen (lang, term) ();
                 Printf.printf "%s\t%s\t%g\t%s\t%s\n%!" id term weight lang source
               end)
             (List.map (fun (t, w, l) -> (t, w, l, "llm:" ^ m.id)) llm @ wiki);
           Printf.eprintf "%s %s: %d LLM terms, %d Wikidata terms\n%!" id (Ontology.path onto id) (List.length llm)
             (List.length wiki);
           spent +. cost)
         0. ids
     in
     Printf.eprintf "%d nodes, $%.4f\n" (List.length ids) spent;
     Lwt.return_unit)
