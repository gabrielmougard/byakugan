(* Nodes come from the IAB Tech Lab TSVs as published (Unique ID, Parent, Name,
   Tier 1..4, Extension). The lexicon is ours: "id<TAB>term[<TAB>weight[<TAB>lang]]"
   lines, generated offline (LLM taxonomy enrichment, Wikidata aliases) and
   reviewed, so every lexical decision traces back to an editable line. A line
   with a language only fires on pages in that language or in none declared:
   "var" is a football term in Italian, not in English. *)

type id = string
type node = { parent : id option; name : string }

type t = {
  nodes : (id, node) Hashtbl.t;
  lexicon : (string, id * float * string) Hashtbl.t; (* term -> node, weight, language ("" = any); one term may map to several nodes *)
}

(* A declared language ("it-IT", "fr_FR", "de") as its two-letter code, "" when
   undeclared or unreadable: language "EN_us" = "en", language "eng" = "". *)
let language lang =
  let l = String.lowercase_ascii (String.trim lang) in
  if String.length l >= 2 && (String.length l = 2 || l.[2] = '-' || l.[2] = '_') then String.sub l 0 2 else ""

let speaks ~lang l = l = "" || lang = "" || l = lang

let fields line = List.map String.trim (String.split_on_char '\t' line)
let term_key term = String.concat " " (Array.to_list (Text.tokens term))

let of_tsv ~taxonomy ~lexicon =
  let nodes = Hashtbl.create 1024 and lex = Hashtbl.create 4096 in
  List.iter
    (fun line ->
      match fields line with
      | id :: parent :: name :: _ when id <> "" && id <> "Unique ID" && name <> "" ->
          Hashtbl.replace nodes id
            { parent = (if parent = "" then None else Some parent); name }
      | _ -> ())
    (String.split_on_char '\n' taxonomy);
  List.iter
    (fun line ->
      match fields line with
      | [ id; term ] -> Hashtbl.add lex (term_key term) (id, 1., "")
      | [ id; term; weight ] -> Hashtbl.add lex (term_key term) (id, float_of_string weight, "")
      | [ id; term; weight; lang ] -> Hashtbl.add lex (term_key term) (id, float_of_string weight, language lang)
      | _ -> ())
    (String.split_on_char '\n' lexicon);
  { nodes; lexicon = lex }

let name t id = match Hashtbl.find_opt t.nodes id with Some n -> n.name | None -> id

(* Self first, root last; [] for an unknown id. *)
let rec ancestors t id =
  match Hashtbl.find_opt t.nodes id with
  | None -> []
  | Some { parent = None; _ } -> [ id ]
  | Some { parent = Some p; _ } -> id :: ancestors t p

(* Root first: "Sports > Soccer". *)
let path t id =
  match ancestors t id with [] -> id | a -> String.concat " > " (List.rev_map (name t) a)

let is_under t id ~root = List.mem root (ancestors t id)

(* Wu-Palmer: 2 * depth(lowest common ancestor) / (depth a + depth b), a
   root at depth 1. Two children of one root: 2 * 1 / (2 + 2) = 0.5. *)
let similarity t a b =
  let aa = ancestors t a and bb = ancestors t b in
  match (aa, bb) with
  | [], _ | _, [] -> 0.
  | _ ->
      let common = List.length (List.filter (fun x -> List.mem x bb) aa) in
      2. *. float common /. float (List.length aa + List.length bb)

let ids t = Hashtbl.fold (fun id _ acc -> id :: acc) t.nodes []
let roots t = Hashtbl.fold (fun id n acc -> if n.parent = None then id :: acc else acc) t.nodes []
(* A node's terms in [lang] and in no language; every term when [lang] is "". *)
let terms ?(lang = "") t id =
  let lang = language lang in
  List.sort_uniq compare
    (Hashtbl.fold (fun term (i, _, l) acc -> if i = id && speaks ~lang l then term :: acc else acc) t.lexicon [])

let languages t = List.sort_uniq compare (Hashtbl.fold (fun _ (_, _, l) acc -> if l = "" then acc else l :: acc) t.lexicon [])

let max_ngram = 4

(* Lexicon terms present in [text], a page in [lang], as (node, term, weight).
   N-gram lookups make this O(tokens), whatever the lexicon size. *)
let hits ?(lang = "") t text =
  let lang = language lang in
  let toks = Text.tokens text in
  let n = Array.length toks in
  let found = ref [] in
  for i = 0 to n - 1 do
    for len = 1 to min max_ngram (n - i) do
      let term = String.concat " " (Array.to_list (Array.sub toks i len)) in
      (* A term listed for a node in several languages counts once, at its best weight. *)
      List.fold_left
        (fun best (id, w, l) ->
          if not (speaks ~lang l) then best
          else match List.assoc_opt id best with Some w' when w' >= w -> best | _ -> (id, w) :: List.remove_assoc id best)
        [] (Hashtbl.find_all t.lexicon term)
      |> List.iter (fun (id, w) -> found := (id, term, w) :: !found)
    done
  done;
  !found
