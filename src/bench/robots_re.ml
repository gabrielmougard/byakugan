(* A pure-OCaml robots.txt matcher (Re regexes, parse once), the baseline
   for robots_bench.ml. The crawler uses Robots. *)

(* RFC 9309: the group naming our product token wins, else "*"; within it the
   longest matching pattern decides, Allow on a tie. "*" and a final "$" are
   the only special characters. *)

type rule = { allow : bool; length : int; re : Re.re }
type t = { rules : rule list; delay : float option; sitemaps : string list }

let allow_all = { rules = []; delay = None; sitemaps = [] }

let compile pattern =
  let anchored = String.ends_with ~suffix:"$" pattern in
  let body = if anchored then String.sub pattern 0 (String.length pattern - 1) else pattern in
  let parts = List.map Re.str (String.split_on_char '*' body) in
  let wild = List.concat (List.mapi (fun i p -> if i = 0 then [ p ] else [ Re.rep Re.any; p ]) parts) in
  Re.compile (Re.seq ((Re.bos :: wild) @ if anchored then [ Re.eos ] else []))

let line l =
  let l = match String.index_opt l '#' with Some i -> String.sub l 0 i | None -> l in
  match String.index_opt l ':' with
  | None -> None
  | Some i ->
      let key = String.lowercase_ascii (String.trim (String.sub l 0 i)) in
      Some (key, String.trim (String.sub l (i + 1) (String.length l - i - 1)))

type group = { agents : string list; group_rules : rule list; group_delay : float option }

let groups text =
  let close g acc = if g.agents = [] then acc else g :: acc in
  let empty = { agents = []; group_rules = []; group_delay = None } in
  let rec go lines g in_rules acc sitemaps =
    match lines with
    | [] -> (List.rev (close g acc), List.rev sitemaps)
    | l :: rest -> (
        match line l with
        | Some ("user-agent", a) when in_rules -> go rest { empty with agents = [ String.lowercase_ascii a ] } false (close g acc) sitemaps
        | Some ("user-agent", a) -> go rest { g with agents = String.lowercase_ascii a :: g.agents } false acc sitemaps
        | Some ((("allow" | "disallow") as k), p) when p <> "" ->
            let r = { allow = k = "allow"; length = String.length p; re = compile p } in
            go rest { g with group_rules = r :: g.group_rules } true acc sitemaps
        | Some ("crawl-delay", d) -> go rest { g with group_delay = float_of_string_opt d } true acc sitemaps
        | Some ("sitemap", s) -> go rest g in_rules acc (s :: sitemaps)
        | Some (("allow" | "disallow"), _) -> go rest g true acc sitemaps
        | _ -> go rest g in_rules acc sitemaps)
  in
  go (String.split_on_char '\n' text) empty false [] []

let parse ~agent text =
  let agent = String.lowercase_ascii agent in
  let all, sitemaps = groups text in
  let ours = List.filter (fun g -> List.exists (fun a -> a <> "*" && String.starts_with ~prefix:a agent) g.agents) all in
  let chosen = if ours <> [] then ours else List.filter (fun g -> List.mem "*" g.agents) all in
  { rules = List.concat_map (fun g -> g.group_rules) chosen;
    delay = List.find_map (fun g -> g.group_delay) chosen;
    sitemaps }

let allowed t path =
  let matching = List.filter (fun r -> Re.execp r.re path) t.rules in
  match List.sort (fun a b -> compare (b.length, b.allow) (a.length, a.allow)) matching with
  | [] -> true
  | best :: _ -> best.allow
