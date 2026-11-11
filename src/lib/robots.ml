(* robots.txt through Google's reference parser and matcher (RFC 9309, plus
   Google's documented extensions), src/vendor/robotstxt, via our adapter
   src/stubs/robots_stubs.cc. A robots.txt is parsed once; every URL check
   replays the parsed directives in C++ and allocates nothing on the OCaml
   heap. Directives Google ignores but we honour come out of the same pass:
   Crawl-delay, Content-Usage (IETF aipref), Content-Signal (Cloudflare) and
   License (RSL). Their meaning is decided in Ai_use; this module only scopes
   and matches them. *)

type native

external compile : string -> string -> native = "ctx_robots_compile"
external decide : native -> string -> int = "ctx_robots_decide" [@@noalloc]
external our_group : native -> bool = "ctx_robots_our_group" [@@noalloc]
external directives : native -> (string * string * int * int) array = "ctx_robots_directives"
external pattern_matches : string -> string -> bool = "ctx_robots_pattern_matches" [@@noalloc]

(* Where a directive sits; the numbering is the adapter's Scope enum. *)
type scope = Outside | Global_group | Our_group | Other_group

let scope_of = function 1 -> Global_group | 2 -> Our_group | 3 -> Other_group | _ -> Outside

type directive = { key : string; value : string; line : int; scope : scope }

type t = {
  native : native;
  delay : float option;
  sitemaps : string list;
  usage_rules : directive list; (* Content-Usage rules of the group that applies to us *)
  signals : string list; (* Content-Signal values of that group, else outside any group *)
  licenses : string list; (* RSL license URLs that apply to us *)
}

type decision = { allowed : bool; line : int (* deciding robots.txt line, 0 if none *) }

let parse ~agent body =
  let native = compile body agent in
  let all =
    Array.to_list
      (Array.map (fun (key, value, line, s) -> { key; value; line; scope = scope_of s }) (directives native))
  in
  (* REP group selection: the group naming our product token, else "*". *)
  let selected = if our_group native then Our_group else Global_group in
  let pick key scope = List.filter (fun d -> d.key = key && d.scope = scope) all in
  let values = List.map (fun d -> d.value) in
  (* RSL 1.0 §4.4.2: License lines in the selected group replace the global
     ones. Publishers put "global" ones anywhere, some after the last group
     (so, by REP grammar, inside another bot's); and RSL asks for a
     conservative reading. So without a License in our group, every License
     not in our group counts: another bot's license can only deny T4 or
     change nothing, never grant more than having no license. *)
  let licenses =
    match pick "license" selected with
    | [] -> List.filter (fun d -> d.key = "license" && d.scope <> selected) all
    | l -> l
  in
  { native;
    delay = List.find_map (fun d -> float_of_string_opt d.value) (pick "crawl-delay" selected);
    sitemaps = values (List.filter (fun d -> d.key = "sitemap") all);
    usage_rules = pick "content-usage" selected;
    signals = values (match pick "content-signal" selected with [] -> pick "content-signal" Outside | l -> l);
    licenses = values licenses }

(* RFC 9309 §2.3.1.3: an unreachable or missing file. *)
let allow_all = parse ~agent:"any" ""
let disallow_all = parse ~agent:"any" "User-agent: *\nDisallow: /"

let decision t url =
  let r = decide t.native url in
  { allowed = r land 1 = 1; line = r lsr 1 }

let allowed t url = decide t.native url land 1 = 1

(* aipref attach §3.2: an optional path ending at the first SP or HTAB, then
   the statement of preference. A path-less rule covers every path.
   split_usage "/paid/ ai-use=n" = ("/paid/", "ai-use=n");
   split_usage "ai-use=y" = ("", "ai-use=y") *)
let split_usage v =
  let v = String.trim v in
  if v = "" || v.[0] <> '/' then ("", v)
  else
    match String.index_from_opt v 0 ' ', String.index_from_opt v 0 '\t' with
    | None, None -> (v, "")
    | a, b ->
        let i = min (Option.value a ~default:max_int) (Option.value b ~default:max_int) in
        (String.sub v 0 i, String.trim (String.sub v i (String.length v - i)))

(* aipref attach §3.1: the longest matching path wins, as for Allow and
   Disallow; rules sharing that length all apply (combined by the caller,
   vocab §5.1). Returns (statement of preference, robots.txt line). *)
let content_usage t url =
  let matching =
    List.filter_map
      (fun d ->
        let path, statement = split_usage d.value in
        if pattern_matches url path then Some (String.length path, statement, d.line) else None)
      t.usage_rules
  in
  let longest = List.fold_left (fun m (n, _, _) -> max m n) (-1) matching in
  List.filter_map (fun (n, s, line) -> if n = longest then Some (s, line) else None) matching
