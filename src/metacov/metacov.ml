(* How much of their own metadata publishers give a crawler. Reads "url" or
   "url<TAB>impressions" lines (src/data/golden_sample.tsv,
   deploy/golden.example.sh; a missing count is 1) and takes the [--pages]
   pages with the most impressions of each publisher. Per origin: robots.txt, then
   sitemaps as the crawler reads them (plain XML, the newest five children of
   an index, two levels deep). Per page: JSON-LD, Open Graph and meta tags.
   No T4, nothing stored; one request per second per origin, origins in
   parallel. Prints one TSV row per publisher, then the totals.
     metacov [--pages 10] < sample.tsv > report.tsv *)

open Contextual
open Serve
open Lwt.Syntax

type page = { url : string; imps : float }

type found = {
  jsonld : bool;
  article : bool; (* a JSON-LD @type ending in Article or BlogPosting *)
  ld_section : bool;
  ld_keywords : bool;
  breadcrumb : bool;
  og : bool;
  og_article : bool; (* og:type = article *)
  art_section : bool;
  art_tag : bool;
  meta_keywords : bool; (* keywords or news_keywords *)
  lang : bool;
  section : bool; (* what Doc extracts, from any of the above *)
  keywords : bool;
}

let none =
  { jsonld = false; article = false; ld_section = false; ld_keywords = false; breadcrumb = false; og = false;
    og_article = false; art_section = false; art_tag = false; meta_keywords = false; lang = false; section = false;
    keywords = false }

type outcome = Found of found * bool (* in a sitemap *) | Refused | Failed of string

type origin = {
  sitemaps_declared : int;
  sitemap_files : int;
  sitemaps_refused : int; (* by robots.txt *)
  gz_skipped : int;
  news : bool;
  sitemap_urls : int;
  outcomes : (page * outcome) list;
}

(* shortcut: no public-suffix list; two labels, three under a two-letter
   country code's co/com/org/net/gov/ac. Enough for the top publishers. *)
let domain url =
  let host = Option.value (Uri.host (Uri.of_string url)) ~default:"" in
  let labels = String.split_on_char '.' host in
  let n = List.length labels in
  let keep =
    if n >= 3 && String.length (List.nth labels (n - 1)) = 2
       && List.mem (List.nth labels (n - 2)) [ "co"; "com"; "org"; "net"; "gov"; "ac" ]
    then 3
    else 2
  in
  String.concat "." (List.filteri (fun i _ -> i >= n - keep) labels)

let origin url =
  let u = Uri.of_string url in
  Printf.sprintf "%s://%s" (Option.value (Uri.scheme u) ~default:"https") (Option.value (Uri.host u) ~default:"")

let normalized url = match Url_key.normalize url with Ok n -> n | Error _ -> url

let polite ?max_bytes url =
  let* () = Lwt_unix.sleep 1. in
  Web.fetch ?max_bytes url

let rec scan_jsonld f (j : Yojson.Safe.t) =
  match j with
  | `List l -> List.fold_left scan_jsonld f l
  | `Assoc kv ->
      let types =
        match List.assoc_opt "@type" kv with
        | Some (`String s) -> [ s ]
        | Some (`List l) -> List.filter_map (function `String s -> Some s | _ -> None) l
        | _ -> []
      in
      let present k =
        match List.assoc_opt k kv with
        | Some (`String s) -> String.trim s <> ""
        | Some (`List (_ :: _)) -> true
        | _ -> false
      in
      let article =
        List.exists (fun t -> String.ends_with ~suffix:"Article" t || String.ends_with ~suffix:"BlogPosting" t) types
      in
      let f =
        { f with
          jsonld = true;
          article = f.article || article;
          ld_section = f.ld_section || present "articleSection";
          ld_keywords = f.ld_keywords || present "keywords";
          breadcrumb = f.breadcrumb || List.mem "BreadcrumbList" types }
      in
      List.fold_left
        (fun f k -> match List.assoc_opt k kv with Some v -> scan_jsonld f v | None -> f)
        f [ "@graph"; "mainEntity" ]
  | _ -> f

let scan_meta f attrs =
  let get k = Option.value (List.assoc_opt k attrs) ~default:"" in
  let key = String.lowercase_ascii (if get "property" <> "" then get "property" else get "name") in
  let content = String.trim (get "content") in
  match key with
  | "og:type" -> { f with og = true; og_article = f.og_article || String.lowercase_ascii content = "article" }
  | "article:section" -> { f with art_section = f.art_section || content <> "" }
  | "article:tag" -> { f with art_tag = f.art_tag || content <> "" }
  | "keywords" | "news_keywords" -> { f with meta_keywords = f.meta_keywords || content <> "" }
  | k when String.starts_with ~prefix:"og:" k -> { f with og = true }
  | _ -> f

let scan html =
  let tokens = Html.parse_html html in
  let f =
    List.fold_left
      (fun f -> function
        | Html.Script (a, body) when List.assoc_opt "type" a = Some "application/ld+json" -> (
            match Yojson.Safe.from_string body with j -> scan_jsonld f j | exception Yojson.Json_error _ -> f)
        | Html.Open ("meta", a) -> scan_meta f a
        | Html.Open ("html", a) -> { f with lang = Option.value (List.assoc_opt "lang" a) ~default:"" <> "" }
        | _ -> f)
      none tokens
  in
  let c = Doc.of_tokens tokens in
  { f with section = c.section <> []; keywords = c.keywords <> [] }

(* At most 30 sitemap files per origin, so a long robots.txt list of sitemaps
   cannot turn the check into a crawl. Sitemaps obey robots.txt like pages. *)
let read_sitemaps urls =
  let seen = Hashtbl.create 1024 and files = ref 0 and gz = ref 0 and news = ref false and refused = ref 0 in
  let rec read ~depth url =
    if depth > 2 || !files >= 30 then Lwt.return_unit
    else
      let* ok = Web.allowed url in
      if not ok then (incr refused; Lwt.return_unit)
      else if String.ends_with ~suffix:".gz" url then (incr gz; Lwt.return_unit)
      else
        let* r = polite ~max_bytes:50_000_000 url in
        match r with
        | Ok { status = 200; body; _ } ->
            incr files;
            if Text.contains body "<news:news" then news := true;
            let sm = Doc.parse_sitemap ~fetch:(fun _ -> Doc.empty) body in
            List.iter (fun ((d : Doc.t), _) -> Hashtbl.replace seen (normalized d.url) ()) sm.pages;
            let children = List.filteri (fun i _ -> i < 5) (List.rev (List.sort compare sm.children)) in
            Lwt_list.iter_s (read ~depth:(depth + 1)) children
        | _ -> Lwt.return_unit
  in
  let+ () = Lwt_list.iter_s (read ~depth:0) urls in
  (seen, !files, !gz, !news, !refused)

let check_origin o pages =
  let* robots = Web.robots o in
  let declared = robots.sitemaps in
  let* seen, files, gz, news, refused =
    read_sitemaps (if declared = [] then [ o ^ "/sitemap.xml" ] else declared)
  in
  let check p =
    if not (Robots.allowed robots p.url) then Lwt.return (p, Refused)
    else
      let+ r = polite p.url in
      match r with
      | Ok { status = 200; body; content_type; _ } when Text.contains (String.lowercase_ascii content_type) "html" ->
          (p, Found (scan body, Hashtbl.mem seen (normalized p.url)))
      | Ok { status; _ } -> (p, Failed (Printf.sprintf "HTTP %d" status))
      | Error e -> (p, Failed e)
  in
  let+ outcomes = Lwt_list.map_s check pages in
  { sitemaps_declared = List.length declared; sitemap_files = files; sitemaps_refused = refused; gz_skipped = gz; news;
    sitemap_urls = Hashtbl.length seen; outcomes }

let flags =
  [ ("jsonld", fun f -> f.jsonld); ("article", fun f -> f.article); ("ld_section", fun f -> f.ld_section);
    ("ld_keywords", fun f -> f.ld_keywords); ("breadcrumb", fun f -> f.breadcrumb); ("og", fun f -> f.og);
    ("og_article", fun f -> f.og_article); ("art_section", fun f -> f.art_section); ("art_tag", fun f -> f.art_tag);
    ("meta_keywords", fun f -> f.meta_keywords); ("lang", fun f -> f.lang); ("section", fun f -> f.section);
    ("keywords", fun f -> f.keywords) ]

let header =
  String.concat "\t"
    ([ "publisher"; "origins"; "sitemaps_declared"; "sitemap_files"; "sitemaps_refused"; "gz_skipped"; "news_sitemap";
       "sitemap_urls";
       "pages"; "fetched"; "robots_refused"; "failed"; "in_sitemap" ]
    @ List.map fst flags)

let row name origins =
  let sum f = List.fold_left (fun a o -> a + f o) 0 origins in
  let outcomes = List.concat_map (fun o -> o.outcomes) origins in
  let found = List.filter_map (function _, Found (f, s) -> Some (f, s) | _ -> None) outcomes in
  let count p = List.length (List.filter p found) in
  String.concat "\t"
    ([ name; string_of_int (List.length origins); string_of_int (sum (fun o -> o.sitemaps_declared));
       string_of_int (sum (fun o -> o.sitemap_files)); string_of_int (sum (fun o -> o.sitemaps_refused));
       string_of_int (sum (fun o -> o.gz_skipped));
       string_of_bool (List.exists (fun o -> o.news) origins); string_of_int (sum (fun o -> o.sitemap_urls));
       string_of_int (List.length outcomes); string_of_int (List.length found);
       string_of_int (List.length (List.filter (function _, Refused -> true | _ -> false) outcomes));
       string_of_int (List.length (List.filter (function _, Failed _ -> true | _ -> false) outcomes));
       string_of_int (count snd) ]
    @ List.map (fun (_, get) -> string_of_int (count (fun (f, _) -> get f))) flags)

(* Shares over fetched pages, plain and weighted by each page's impressions. *)
let totals publishers =
  let found =
    List.concat_map
      (fun (_, origins) ->
        List.concat_map (fun o -> List.filter_map (function p, Found (f, s) -> Some (p, f, s) | _ -> None) o.outcomes) origins)
      publishers
  in
  let n = float (List.length found) and w = List.fold_left (fun a (p, _, _) -> a +. p.imps) 0. found in
  let share get =
    let k = List.filter (fun (_, f, s) -> get f s) found in
    Printf.sprintf "%.0f%% (%.0f%% of impressions)" (100. *. float (List.length k) /. n)
      (100. *. List.fold_left (fun a (p, _, _) -> a +. p.imps) 0. k /. w)
  in
  let any p = List.length (List.filter (fun (_, origins) -> List.exists p origins) publishers) in
  Printf.printf "\n# %d publishers: %d with a sitemap read, %d with a news sitemap\n" (List.length publishers)
    (any (fun o -> o.sitemap_files > 0)) (any (fun o -> o.news));
  Printf.printf "# %d pages fetched\n# in_sitemap\t%s\n" (List.length found) (share (fun _ s -> s));
  List.iter (fun (name, get) -> Printf.printf "# %s\t%s\n" name (share (fun f _ -> get f))) flags

let read_sample () =
  In_channel.input_lines stdin
  |> List.filter_map (fun line ->
         match String.split_on_char '\t' line with
         | [ url; imps ] -> Some { url; imps = float_of_string imps }
         | [ url ] when url <> "" -> Some { url; imps = 1. }
         | _ -> None)

let group key l =
  let t = Hashtbl.create 64 in
  List.iter (fun x -> Hashtbl.replace t (key x) (x :: Option.value (Hashtbl.find_opt t (key x)) ~default:[])) l;
  Hashtbl.fold (fun k v acc -> (k, List.rev v) :: acc) t [] |> List.sort compare

let () =
  let per = ref 10 in
  Arg.parse [ ("--pages", Arg.Set_int per, "N pages per publisher, most impressions first") ] ignore
    "metacov [--pages N] < sample.tsv";
  let pages =
    group (fun p -> domain p.url) (read_sample ())
    |> List.concat_map (fun (_, ps) ->
           List.filteri (fun i _ -> i < !per) (List.sort (fun a b -> compare b.imps a.imps) ps))
  in
  let by_origin = group (fun p -> origin p.url) pages in
  Lwt_main.run
    (let+ checked = Lwt_list.map_p (fun (o, ps) -> let+ r = check_origin o ps in (o, r)) by_origin in
     let publishers = group (fun (o, _) -> domain o) checked |> List.map (fun (d, l) -> (d, List.map snd l)) in
     print_endline header;
     List.iter (fun (d, origins) -> print_endline (row d origins)) publishers;
     totals publishers;
     List.iter
       (fun (_, o) ->
         List.iter
           (function p, Failed e -> Printf.eprintf "failed %s: %s\n" p.url e | _ -> ())
           o.outcomes)
       checked)
