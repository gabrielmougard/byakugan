(* robots.txt matchers, timed and compared on real robots.txt files:
   - re: a pure-OCaml matcher (Robots_re): parse once, regexes;
   - oneshot: Google's matcher called as apeschar/robotstxt-ocaml calls it,
     re-parsing the robots.txt for every URL;
   - replay: Robots, our adapter: Google's parser once, then a replay of the
     parsed directives into Google's matcher for every URL.
   replay must agree with oneshot on every URL; re's disagreements are its bugs.

   robots_bench.exe DIR   (DIR holds one <host>.txt robots.txt per file) *)

open Contextual

external oneshot : string -> string -> string -> bool = "bench_robots_oneshot" [@@noalloc]

let agent = "ContextBot"

(* Seconds per call of [f], repeated until 0.2 s have passed. *)
let per_call f =
  ignore (f ());
  let rec go n =
    let t0 = Unix.gettimeofday () in
    for _ = 1 to n do ignore (Sys.opaque_identity (f ())) done;
    let dt = Unix.gettimeofday () -. t0 in
    if dt < 0.2 then go (n * 2) else dt /. float n
  in
  go 1

(* Every Allow/Disallow pattern made concrete, a few variants of each, and
   common article-like paths: the checks exercise the rules that exist. *)
let paths body =
  let base =
    [ "/"; "/news/2026/nov/05/some-article"; "/sport/football/123456"; "/search?q=boots"; "/index.html";
      "/amp/news/x"; "/api/v1/items?id=3"; "/wp-admin/"; "/tag/food/"; "/video/clip.mp4" ]
  in
  let from_rules =
    List.concat_map
      (fun line ->
        match String.index_opt line ':' with
        | None -> []
        | Some i ->
            let key = String.lowercase_ascii (String.trim (String.sub line 0 i)) in
            let v = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
            let v = match String.index_opt v '#' with Some j -> String.trim (String.sub v 0 j) | None -> v in
            if (key = "allow" || key = "disallow") && v <> "" && v.[0] = '/' then
              let c = String.concat "x" (String.split_on_char '*' v) in
              let c = if String.ends_with ~suffix:"$" c then String.sub c 0 (String.length c - 1) else c in
              [ c; c ^ "page.html"; c ^ "/a?b=1" ]
            else [])
      (String.split_on_char '\n' body)
  in
  (* URLs on the wire are percent-encoded (RFC 3986); Google expects that. *)
  let encode p =
    String.concat "" (List.map (fun c -> if Char.code c >= 0x80 then Printf.sprintf "%%%02X" (Char.code c) else String.make 1 c) (List.of_seq (String.to_seq p)))
  in
  List.sort_uniq compare (List.map encode (base @ from_rules))

type row = {
  host : string;
  lines : int;
  checks : int;
  parse_re : float;
  parse_replay : float;
  re : float;
  oneshot : float;
  replay : float;
  re_wrong : (string * bool) list; (* path, Google's answer *)
  replay_wrong : int;
}

let bench dir file =
  let host = Filename.chop_suffix file ".txt" in
  let body = In_channel.with_open_bin (Filename.concat dir file) In_channel.input_all in
  let ps = Array.of_list (paths body) in
  let urls = Array.map (fun p -> "https://" ^ host ^ p) ps in
  let old = Robots_re.parse ~agent body and fresh = Robots.parse ~agent body in
  let google = Array.map (fun u -> oneshot body agent u) urls in
  let each f () = Array.iteri (fun i _ -> ignore (Sys.opaque_identity (f i))) urls in
  let n = float (Array.length urls) in
  { host;
    lines = List.length (String.split_on_char '\n' body);
    checks = Array.length urls;
    parse_re = per_call (fun () -> Robots_re.parse ~agent body);
    parse_replay = per_call (fun () -> Robots.parse ~agent body);
    re = per_call (each (fun i -> Robots_re.allowed old ps.(i))) /. n;
    oneshot = per_call (each (fun i -> oneshot body agent urls.(i))) /. n;
    replay = per_call (each (fun i -> Robots.allowed fresh urls.(i))) /. n;
    re_wrong =
      List.filter_map Fun.id
        (Array.to_list (Array.mapi (fun i p -> if Robots_re.allowed old p <> google.(i) then Some (p, google.(i)) else None) ps));
    replay_wrong =
      Array.fold_left ( + ) 0 (Array.mapi (fun i u -> if Robots.allowed fresh u <> google.(i) then 1 else 0) urls) }

(* Throughput of replay checks on [d] domains sharing the parsed robots.txt. *)
let scaling dir files d =
  let work =
    List.map
      (fun f ->
        let body = In_channel.with_open_bin (Filename.concat dir f) In_channel.input_all in
        let host = Filename.chop_suffix f ".txt" in
        (Robots.parse ~agent body, Array.of_list (List.map (fun p -> "https://" ^ host ^ p) (paths body))))
      files
  in
  let per_domain = 400_000 in
  let run () =
    let k = ref 0 in
    while !k < per_domain do
      List.iter (fun (r, urls) -> Array.iter (fun u -> if !k < per_domain then (ignore (Robots.allowed r u); incr k)) urls) work
    done
  in
  let t0 = Unix.gettimeofday () in
  List.iter Domain.join (List.init d (fun _ -> Domain.spawn run));
  float (d * per_domain) /. (Unix.gettimeofday () -. t0)

(* Where Robots_re and Google's reference part ways. *)
let edge_cases =
  [ ("raw UTF-8 pattern, percent-encoded URL", "User-agent: *\nDisallow: /caf\xc3\xa9", "/caf%C3%A9");
    ("lower-case escape in pattern", "User-agent: *\nDisallow: /a%3cb", "/a%3Cb");
    ("typo: Dissallow", "User-agent: *\nDissallow: /x", "/x");
    ("missing colon", "User-agent: *\nDisallow /x", "/x");
    ("agent token with a version", "User-agent: ContextBot/1.0\nDisallow: /x", "/x");
    ("/index.html allows its directory", "User-agent: *\nDisallow: /d/\nAllow: /d/index.html", "/d/") ]

let () =
  let dir = Sys.argv.(1) in
  let files = List.sort compare (List.filter (fun f -> Filename.check_suffix f ".txt") (Array.to_list (Sys.readdir dir))) in
  let rows = List.map (bench dir) files in
  let us x = x *. 1e6 and ns x = x *. 1e9 in
  print_endline "| robots.txt | lines | URLs | parse µs: re / replay | check ns: re / oneshot / replay | replay vs oneshot | re vs Google |";
  print_endline "|---|---|---|---|---|---|---|";
  List.iter
    (fun r ->
      Printf.printf "| %s | %d | %d | %.1f / %.1f | %.0f / %.0f / %.0f | %s | %d wrong |\n" r.host r.lines r.checks
        (us r.parse_re) (us r.parse_replay) (ns r.re) (ns r.oneshot) (ns r.replay)
        (if r.replay_wrong = 0 then "identical" else Printf.sprintf "%d differ" r.replay_wrong)
        (List.length r.re_wrong))
    rows;
  let total f = List.fold_left (fun acc r -> acc +. (f r *. float r.checks)) 0. rows in
  let checks = float (List.fold_left (fun acc r -> acc + r.checks) 0 rows) in
  Printf.printf "\nmean per check: re %.0f ns, oneshot %.0f ns, replay %.0f ns\n" (ns (total (fun r -> r.re) /. checks))
    (ns (total (fun r -> r.oneshot) /. checks)) (ns (total (fun r -> r.replay) /. checks));
  Printf.printf "mean parse: re %.1f µs, replay %.1f µs\n"
    (us (List.fold_left (fun a r -> a +. r.parse_re) 0. rows /. float (List.length rows)))
    (us (List.fold_left (fun a r -> a +. r.parse_replay) 0. rows /. float (List.length rows)));
  List.iter
    (fun d -> Printf.printf "replay on %d domain(s): %.1f M checks/s\n%!" d (scaling dir files d /. 1e6))
    [ 1; 4; 8 ];
  print_endline "\n| edge case | re | Google |\n|---|---|---|";
  let word b = if b then "allowed" else "disallowed" in
  List.iter
    (fun (name, body, path) ->
      Printf.printf "| %s | %s | %s |\n" name
        (word (Robots_re.allowed (Robots_re.parse ~agent body) path))
        (word (oneshot body agent ("https://x.example" ^ path))))
    edge_cases;
  print_endline "\nre disagreements with Google (first 3 per file):";
  List.iter
    (fun r ->
      List.iteri
        (fun i (p, g) -> if i < 3 then Printf.printf "  %s %s: re says %s, Google says %s\n" r.host p (if g then "disallowed" else "allowed") (if g then "allowed" else "disallowed"))
        r.re_wrong)
    rows
