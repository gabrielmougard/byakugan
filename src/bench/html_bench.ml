(* HTML extraction on real pages, two token sources for the same Doc:
   - scanner: the tolerant tag scanner (Html.tokenize);
   - lexbor: lexbor's HTML5 parser, its tree flattened in C (Html.parse_html).
   Times both, alone and through Doc.of_tokens, and compares what each page
   yields: title, segments, main text, media.

   html_bench.exe DIR   (DIR holds the pages, *.html) *)

open Contextual

(* Seconds per call of [f], repeated until 0.3 s have passed. *)
let per_call f =
  ignore (f ());
  let rec go n =
    let t0 = Unix.gettimeofday () in
    for _ = 1 to n do ignore (Sys.opaque_identity (f ())) done;
    let dt = Unix.gettimeofday () -. t0 in
    if dt < 0.3 then go (n * 2) else dt /. float n
  in
  go 1

let main_chars (c : Doc.content) =
  List.fold_left (fun n (s : Doc.segment) -> if s.main then n + String.length s.text else n) 0 c.segments

let () =
  let dir = Sys.argv.(1) in
  let pages =
    Sys.readdir dir |> Array.to_list |> List.filter (fun f -> Filename.check_suffix f ".html") |> List.sort compare
    |> List.map (fun f -> (f, In_channel.with_open_bin (Filename.concat dir f) In_channel.input_all))
  in
  let bytes = List.fold_left (fun n (_, h) -> n + String.length h) 0 pages in
  let total f = List.fold_left (fun t (_, h) -> t +. per_call (fun () -> f h)) 0. pages in
  let mb_s t = float bytes /. 1048576. /. t in
  let scan_tok = total Html.tokenize and lex_tok = total Html.parse_html in
  let scan_doc = total (fun h -> Doc.of_tokens (Html.tokenize h)) in
  let lex_doc = total (fun h -> Doc.of_tokens (Html.parse_html h)) in
  Printf.printf "%d pages, %.1f MB\n\n" (List.length pages) (float bytes /. 1048576.);
  Printf.printf "| | scanner | lexbor |\n|---|---|---|\n";
  Printf.printf "| tokens, ms per page | %.2f | %.2f |\n" (scan_tok *. 1e3 /. float (List.length pages))
    (lex_tok *. 1e3 /. float (List.length pages));
  Printf.printf "| tokens, MB/s | %.0f | %.0f |\n" (mb_s scan_tok) (mb_s lex_tok);
  Printf.printf "| tokens + Doc, ms per page | %.2f | %.2f |\n" (scan_doc *. 1e3 /. float (List.length pages))
    (lex_doc *. 1e3 /. float (List.length pages));
  Printf.printf "| tokens + Doc, MB/s | %.0f | %.0f |\n\n" (mb_s scan_doc) (mb_s lex_doc);
  Printf.printf "| page | title same | segments (main) scanner | lexbor | main text chars scanner | lexbor | media scanner | lexbor |\n";
  Printf.printf "|---|---|---|---|---|---|---|---|\n";
  List.iter
    (fun (f, h) ->
      let a = Doc.of_tokens (Html.tokenize h) and b = Doc.of_tokens (Html.parse_html h) in
      let segs (c : Doc.content) =
        Printf.sprintf "%d (%d)" (List.length c.segments)
          (List.length (List.filter (fun (s : Doc.segment) -> s.main) c.segments))
      in
      Printf.printf "| %s | %s | %s | %s | %d | %d | %d | %d |\n" f
        (if a.title = b.title then "yes" else Printf.sprintf "no: %S / %S" a.title b.title)
        (segs a) (segs b) (main_chars a) (main_chars b) (List.length a.media) (List.length b.media))
    pages
