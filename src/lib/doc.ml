type media_kind = Image | Video
type media = { kind : media_kind; src : string; text : string }

(* A visible block in document order. Boilerplate (nav, footer, aside...) is
   kept with [main = false]: noise for topic, real adjacency risk for safety.
   [article]: the innermost <article> around it, numbered in document order
   from 1, 0 outside any: a URL may hold several stories (live blogs,
   infinite scroll, multi-article pages), and a slot's page is its story. *)
type segment = { tag : string; text : string; main : bool; article : int }

type content = {
  title : string;
  description : string;
  keywords : string list;
  section : string list;
  headings : string list;
  paragraphs : string list;
  media : media list;
  segments : segment list;
  lang : string; (* <html lang>, else og:locale; "" when undeclared *)
  published : string; (* JSON-LD datePublished, else article:published_time; "" when undeclared *)
  live : bool; (* a JSON-LD LiveBlogPosting *)
  ad_slots : (string * int) list;
      (* ad containers by element id, with the number of segments before each:
         where the template puts its slots (a GPID ends with that id) *)
}

(* [hints] are known before any fetch (sitemap news/video tags, OpenRTB
   site.keywords). [content] is lazy so the cheapest tiers provably never fetch. *)
type t = { url : string; hints : string list; content : content Lazy.t }

let empty =
  { title = ""; description = ""; keywords = []; section = []; headings = []; paragraphs = []; media = []; segments = [];
    lang = ""; published = ""; live = false; ad_slots = [] }

let split_list s = List.filter (( <> ) "") (List.map String.trim (String.split_on_char ',' s))

let dedup l =
  let seen = Hashtbl.create 8 in
  List.filter
    (fun s ->
      let k = String.lowercase_ascii s in
      if Hashtbl.mem seen k then false else (Hashtbl.add seen k (); true))
    l

(* og:video, a VideoObject and a <video> tag often point at one file: one item,
   texts merged, so it is described (and paid for) once. *)
let merge_media media =
  List.fold_left
    (fun acc m ->
      if m.src <> "" && List.exists (fun x -> x.src = m.src) acc then
        List.map (fun x -> if x.src = m.src then { x with text = String.trim (x.text ^ " " ^ m.text) } else x) acc
      else acc @ [ m ])
    [] media

let finish c =
  { c with
    keywords = dedup (List.rev c.keywords);
    section = dedup (List.rev c.section);
    headings = List.rev c.headings;
    paragraphs = List.rev c.paragraphs;
    media = merge_media (List.rev c.media);
    segments = List.rev c.segments;
    ad_slots = List.rev c.ad_slots }

let add_media c kind src text = { c with media = { kind; src; text } :: c.media }

let add_block c tag s =
  match tag with
  | "title" -> if c.title = "" then { c with title = s } else c
  | "h1" | "h2" | "h3" -> { c with headings = s :: c.headings }
  | "figcaption" -> add_media c Image "" s
  | _ -> { c with paragraphs = s :: c.paragraphs }

let add_meta c attrs =
  let get k = Option.value (List.assoc_opt k attrs) ~default:"" in
  let key = String.lowercase_ascii (if get "property" <> "" then get "property" else get "name") in
  let content = get "content" in
  match key with
  | ("description" | "og:description") when c.description = "" -> { c with description = content }
  | "og:title" when c.title = "" -> { c with title = content }
  | "keywords" | "news_keywords" | "article:tag" ->
      { c with keywords = List.rev_append (split_list content) c.keywords }
  | "article:section" -> { c with section = content :: c.section }
  | "og:locale" when c.lang = "" -> { c with lang = content }
  | "article:published_time" when c.published = "" -> { c with published = content }
  | "og:image" -> add_media c Image content ""
  | "og:video" | "og:video:url" -> add_media c Video content ""
  | _ -> c

let embeds src hosts = List.exists (fun h -> Text.contains src h) hosts

let add_element c tag attrs =
  let get k = Option.value (List.assoc_opt k attrs) ~default:"" in
  let src = get "src" and text = String.trim (get "alt" ^ " " ^ get "title") in
  let pixel = get "width" = "1" || get "height" = "1" in
  match tag with
  | "html" -> { c with lang = get "lang" }
  | "img" when src <> "" && not pixel -> add_media c Image src text
  | "video" -> add_media c Video src text
  | "iframe" when embeds src [ "youtube"; "vimeo"; "dailymotion" ] -> add_media c Video src text
  | _ -> c

let rec add_jsonld c (j : Yojson.Safe.t) =
  match j with
  | `List l -> List.fold_left add_jsonld c l
  | `Assoc kv ->
      let str k = match List.assoc_opt k kv with Some (`String s) -> s | _ -> "" in
      let strs k =
        match List.assoc_opt k kv with
        | Some (`String s) -> split_list s
        | Some (`List l) -> List.filter_map (function `String s -> Some s | _ -> None) l
        | _ -> []
      in
      let joined keys = String.concat " " (List.filter (( <> ) "") (List.map str keys)) in
      let c =
        match str "@type" with
        | "VideoObject" | "Clip" ->
            add_media c Video (str "contentUrl") (joined [ "name"; "description"; "transcript" ])
        | "BreadcrumbList" ->
            let crumb = function
              | `Assoc e -> ( match List.assoc_opt "name" e with Some (`String s) -> Some s | _ -> None)
              | _ -> None
            in
            let crumbs =
              match List.assoc_opt "itemListElement" kv with
              | Some (`List l) -> List.filter_map crumb l
              | _ -> []
            in
            { c with section = List.rev_append crumbs c.section }
        | _ ->
            { c with
              title = (if c.title = "" then str "headline" else c.title);
              description = (if c.description = "" then str "description" else c.description);
              keywords = List.rev_append (strs "keywords") c.keywords;
              section = List.rev_append (strs "articleSection") c.section;
              published = (if c.published = "" then str "datePublished" else c.published);
              live = c.live || str "@type" = "LiveBlogPosting" }
      in
      List.fold_left
        (fun c k -> match List.assoc_opt k kv with Some v -> add_jsonld c v | None -> c)
        c [ "@graph"; "video"; "associatedMedia" ]
  | _ -> c

(* shortcut: skip nav/footer/aside and keep block text; Trafilatura-grade
   main-content extraction (link density, text density) when measured to matter. *)
let boilerplate = [ "nav"; "footer"; "aside"; "form"; "noscript"; "svg" ]
let blocks = [ "title"; "h1"; "h2"; "h3"; "p"; "li"; "blockquote"; "figcaption" ]

let segment c tag text main article = { c with segments = { tag; text; main; article } :: c.segments }

(* Ids publishers and ad servers give ad containers: a word such as ad,
   advert, mpu, leaderboard, dfp or gpt, or publicite in their language,
   after a dash, an underscore or the start, before one of those, a digit
   or the end. div-gpt-ad-1699, ad_slot_2, mpu1, top-leaderboard,
   pubblicita-box and sidebar-ad match; header, download-link, advice,
   masthead, 03ad57e2ae8c9629 and consent-banner do not. Only on
   containers: a stylesheet's id is no slot. *)
let ad_id =
  Re.Perl.compile_pat ~opts:[ `Caseless ]
    {|(^|[-_])(ads?|adv|advert|advertisement|adslot|adunit|billboard|dfp|gpt|inread|leaderboard|mpu|outstream|skyscraper|sponsor|pubblicita|publicite|publicidad|werbung|anzeige)([-_\d]|$)|adsbygoogle|google_ads|ad-?slot|ad-?unit|}

(* Extraction in one pass over the page's tokens (Html.parse_html). Every
   block of text is a segment, in document order; main ones also feed the
   zones the tiers read; meta tags and JSON-LD fill the rest.

     <title>Derby</title>                    title, no segment
     <div id="div-gpt-ad-top">               ad slot ("div-gpt-ad-top", 0)
     <article>                               story 1
       <h1>Derby report</h1>                 segment 0  h1   main  story 1
       <p>The striker scored twice.</p>      segment 1  p    main  story 1
       <div id="ad-mpu-1">                   ad slot ("ad-mpu-1", 2)
       <p>The keeper saved a penalty.</p>    segment 2  p    main  story 1
     </article>
     <article><p>Slow-cooked lamb ...</p>    segment 3  p    main  story 2
     <aside><li>Most read: ...</li>          segment 4  li   not main
     <nav><img src="/logo.png">              nothing: no media in boilerplate
     <img src="/x.jpg" alt="Goal">           segment 5  img  main, and media
     <meta>, JSON-LD                         description, keywords, section,
                                             lang, published, live, media

   Main segments also land in headings (h1-h3), paragraphs (p, li,
   blockquote) or media (figcaption). An ad slot counts the segments before
   its container. *)
let of_tokens tokens =
  let c = ref empty and skip = ref 0 and current = ref None and articles = ref [] and seen = ref 0 in
  let article () = match !articles with a :: _ -> a | [] -> 0 in
  let flush () =
    Option.iter
      (fun (tag, main, buf, art) ->
        let s = Text.squash (Buffer.contents buf) in
        if s <> "" && tag <> "title" then c := segment !c tag s main art;
        if s <> "" && main then c := add_block !c tag s)
      !current;
    current := None
  in
  let note_ad = function
    | Html.Open (("div" | "ins" | "aside" | "section" | "span" | "figure"), a) -> (
        match List.assoc_opt "id" a with
        | Some id when id <> "" && Re.execp ad_id id && not (List.mem_assoc id !c.ad_slots) ->
            c := { !c with ad_slots = (id, List.length !c.segments) :: !c.ad_slots }
        | _ -> ())
    | _ -> ()
  in
  List.iter
    (fun tok ->
      note_ad tok;
      (match tok with
      | Html.Open ("article", _) -> flush (); incr seen; articles := !seen :: !articles
      | Html.Close "article" -> flush (); articles := (match !articles with _ :: r -> r | [] -> [])
      | _ -> ());
      match tok with
      | Html.Open (t, _) when List.mem t boilerplate -> flush (); incr skip
      | Html.Close t when List.mem t boilerplate -> flush (); skip := max 0 (!skip - 1)
      | Html.Open (t, _) when List.mem t blocks ->
          flush ();
          current := Some (t, !skip = 0, Buffer.create 128, article ())
      | Html.Close t when Option.map (fun (t, _, _, _) -> t) !current = Some t -> flush ()
      | Html.Text s when !skip > 0 -> Option.iter (fun (_, _, buf, _) -> Buffer.add_string buf s) !current
      | _ when !skip > 0 -> ()
      | Html.Open ("meta", a) -> c := add_meta !c a
      | Html.Open ((("img" | "iframe" | "video") as t), a) ->
          let before = List.length !c.media in
          c := add_element !c t a;
          if List.length !c.media > before then c := segment !c t (List.hd !c.media).text true (article ())
      | Html.Script (a, body) when List.assoc_opt "type" a = Some "application/ld+json" -> (
          match Yojson.Safe.from_string body with
          | j -> c := add_jsonld !c j
          | exception Yojson.Json_error _ -> ())
      | Html.Open (t, a) -> c := add_element !c t a
      | Html.Text s -> Option.iter (fun (_, _, buf, _) -> Buffer.add_string buf s) !current
      | Html.Close _ | Html.Script _ -> ())
    tokens;
  flush ();
  finish !c

let parse html = of_tokens (Html.parse_html html)

let of_html ?(hints = []) ~url html = { url; hints; content = lazy (parse (Html.to_utf8 html)) }

type sitemap = { pages : (t * string option) list; children : string list }

(* One page per <url>, its news/video/image tags as hints; <sitemap><loc> of a
   sitemap index lands in [children]. [fetch] runs only if a tier forces it. *)
let parse_sitemap ~fetch xml =
  let pages = ref [] and children = ref [] in
  let url = ref "" and hints = ref [] and lastmod = ref None in
  let field = ref "" and in_url = ref false in
  List.iter
    (function
      | Html.Open ("url", _) ->
          in_url := true;
          url := "";
          hints := [];
          lastmod := None
      | Html.Close "url" ->
          in_url := false;
          let u = !url in
          pages := ({ url = u; hints = List.rev !hints; content = lazy (fetch u) }, !lastmod) :: !pages
      | Html.Open (tag, _) -> field := tag
      | Html.Close _ -> field := ""
      | Html.Text s -> (
          let s = String.trim s in
          match !field with
          | _ when s = "" -> ()
          | "loc" when !in_url -> url := s
          | "loc" -> children := s :: !children
          | "lastmod" -> lastmod := Some s
          | "news:publication_date" when !lastmod = None -> lastmod := Some s
          | "news:title" | "video:title" | "video:description" | "image:caption" | "image:title" ->
              hints := s :: !hints
          | "news:keywords" | "video:tag" -> hints := List.rev_append (split_list s) !hints
          | _ -> ())
      | Html.Script _ -> ())
    (Html.tokenize xml);
  { pages = List.rev !pages; children = List.rev !children }

(* A sitemap date (W3C Datetime: a day, or a time with its zone) in Unix
   seconds: sitemap_time "2026-11-04" = Some 1793750400.
   shortcut: times without seconds are not read. *)
let sitemap_time s =
  let s = if String.length s = 10 then s ^ "T00:00:00Z" else s in
  match Ptime.of_rfc3339 ~strict:false s with Ok (t, _, _) -> Some (Ptime.to_float_s t) | Error _ -> None

(* The words of a URL's path, minus numbers and html, htm, php, amp, index:
   url_words "https://www.lefigaro.fr/economie/la-dette-de-l-etat-2026"
   = "economie la dette de l etat". *)
let url_words url =
  let after_host =
    match Text.find url ~from:0 "://" with
    | None -> url
    | Some i -> (
        match String.index_from_opt url (i + 3) '/' with
        | Some j -> String.sub url j (String.length url - j)
        | None -> "")
  in
  let path = List.hd (String.split_on_char '?' (List.hd (String.split_on_char '#' after_host))) in
  let noise w =
    String.for_all (fun c -> c >= '0' && c <= '9') w
    || List.mem w [ "html"; "htm"; "php"; "amp"; "index" ]
  in
  String.concat " " (List.filter (fun w -> not (noise w)) (Array.to_list (Text.tokens path)))

(* Zones carry the weight of where a term was seen: a title hit says more than
   a body hit. Pre-fetch and content zones are disjoint, so their evidence adds. *)
let pre_fetch_zones d = [ ("url", 2.0, [ url_words d.url ]); ("hint", 2.0, d.hints) ]

let content_zones c =
  [ ("title", 3.0, [ c.title ]);
    ("section", 2.5, c.section);
    ("keywords", 2.0, c.keywords);
    ("description", 1.5, [ c.description ]);
    ("headings", 1.5, c.headings);
    ("media-text", 1.0, List.map (fun (m : media) -> m.text) c.media);
    ("body", 1.0, List.concat_map Text.sentences c.paragraphs) ]

let text_units c =
  List.filter (( <> ) "") (c.title :: c.description :: List.concat_map Text.sentences c.paragraphs)

let all_text d =
  let c = Lazy.force d.content in
  String.concat "\n"
    ((url_words d.url :: d.hints) @ (c.title :: c.description :: c.keywords) @ c.section @ c.headings
    @ c.paragraphs @ List.map (fun (m : media) -> m.text) c.media)

(* Slot positions as a template keeps them: counted in main blocks ("after
   the 3rd paragraph"), so pages of one template but different lengths
   agree. [main_before] turns a segment index into that count,
   [after_main] back. With segments [nav li; p; p; p]:
   main_before segs 3 = 2 and after_main segs 2 = 3. *)
let main_before (segs : segment list) index = List.length (List.filteri (fun i (s : segment) -> i < index && s.main) segs)

let after_main (segs : segment list) k =
  let rec go i seen = function
    | _ when seen >= k -> i
    | [] -> i
    | (s : segment) :: rest -> go (i + 1) (if s.main then seen + 1 else seen) rest
  in
  go 0 0 segs

(* The main content's text: what refresh compares between two fetches. *)
let main_text d =
  String.concat "\n" (List.filter_map (fun (s : segment) -> if s.main then Some s.text else None) (Lazy.force d.content).segments)

(* What a System-2 model sees: head, first sentences, media text. Never the raw page. *)
let condensed d =
  let c = Lazy.force d.content in
  String.concat "\n"
    ([ "URL: " ^ d.url;
       "Title: " ^ c.title;
       "Description: " ^ c.description;
       "Section: " ^ String.concat ", " c.section;
       "Keywords: " ^ String.concat ", " (d.hints @ c.keywords) ]
    @ List.filteri (fun i _ -> i < 15) (List.concat_map Text.sentences c.paragraphs)
    @ List.filter_map (fun (m : media) -> if m.text = "" then None else Some ("Media: " ^ m.text)) c.media)
