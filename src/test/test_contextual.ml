open Contextual

let tsv rows = String.concat "\n" (List.map (String.concat "\t") rows)

(* Real ids from IAB Tech Lab Content Taxonomy 3.1 (cattax 9). *)
let taxonomy =
  tsv
    [ [ "Unique ID"; "Parent"; "Name"; "Tier 1"; "Tier 2"; "Tier 3"; "Tier 4" ];
      [ "483"; ""; "Sports" ];
      [ "533"; "483"; "Soccer" ];
      [ "539"; "483"; "Tennis" ];
      [ "210"; ""; "Food & Drink" ];
      [ "211"; "210"; "Alcoholic Beverages" ];
      [ "216"; "210"; "Cooking" ];
      [ "1"; ""; "Automotive" ];
      [ "16"; "1"; "Auto Type" ];
      [ "22"; "16"; "Green Vehicles" ];
      [ "380"; ""; "Crime" ];
      [ "v9i3On"; ""; "Sensitive Topics" ];
      [ "XtODT3"; "v9i3On"; "Crime & Harmful Acts to Individuals, Society & Human Right Violations" ];
      [ "I4GWl6"; "v9i3On"; "Death, Injury, or Military Conflict" ] ]

let lexicon =
  tsv
    [ [ "483"; "sport" ]; [ "483"; "sports" ];
      [ "533"; "soccer"; "1.5" ]; [ "533"; "football" ]; [ "533"; "premier league"; "2" ];
      [ "533"; "champions league"; "2" ]; [ "533"; "goalkeeper"; "1.5" ]; [ "533"; "penalty"; "0.5" ];
      [ "539"; "tennis"; "1.5" ]; [ "539"; "wimbledon"; "2" ];
      [ "211"; "wine" ]; [ "211"; "beer" ]; [ "211"; "cocktail" ];
      [ "216"; "recipe"; "1.5" ]; [ "216"; "cooking" ]; [ "216"; "oven"; "0.8" ];
      [ "22"; "electric vehicle"; "2" ]; [ "22"; "charging"; "0.8" ];
      [ "380"; "police"; "0.7" ]; [ "380"; "arrested"; "0.8" ]; [ "380"; "stabbing"; "1.5" ];
      [ "XtODT3"; "stabbing"; "1.5" ]; [ "XtODT3"; "murder"; "1.5" ];
      [ "I4GWl6"; "killed"; "1.2" ]; [ "I4GWl6"; "fatal"; "1.2" ] ]

let onto = Ontology.of_tsv ~taxonomy ~lexicon

(* Toy static embeddings on named axes: sport, soccer, tennis, food, auto,
   crime. They know words the lexicon does not ("striker", "keeper"), which is
   the vocabulary gap the dense tier exists to close. *)
let embed =
  let v sport soccer tennis food auto crime = [| sport; soccer; tennis; food; auto; crime |] in
  let table = Hashtbl.create 64 in
  List.iter
    (fun (w, x) -> Hashtbl.replace table w x)
    [ ("sport", v 1. 0.3 0.3 0. 0. 0.); ("sports", v 1. 0.3 0.3 0. 0. 0.);
      ("soccer", v 1. 1. 0. 0. 0. 0.); ("football", v 1. 1. 0. 0. 0. 0.);
      ("premier", v 0.5 0.8 0. 0. 0. 0.); ("league", v 0.5 0.8 0. 0. 0. 0.);
      ("champions", v 0.5 0.8 0. 0. 0. 0.); ("goalkeeper", v 0.6 1. 0. 0. 0. 0.);
      ("penalty", v 0.5 0.6 0. 0. 0. 0.1); ("striker", v 0.6 1. 0. 0. 0. 0.);
      ("keeper", v 0.6 0.9 0. 0. 0. 0.); ("midfielder", v 0.6 1. 0. 0. 0. 0.);
      ("pitch", v 0.5 0.7 0. 0. 0. 0.); ("whistle", v 0.5 0.5 0. 0. 0. 0.);
      ("booked", v 0.3 0.5 0. 0. 0. 0.); ("stoppage", v 0.4 0.6 0. 0. 0. 0.);
      ("tennis", v 1. 0. 1. 0. 0. 0.); ("wimbledon", v 0.6 0. 1. 0. 0. 0.);
      ("wine", v 0. 0. 0. 0.8 0. 0.); ("beer", v 0. 0. 0. 0.8 0. 0.); ("cocktail", v 0. 0. 0. 0.8 0. 0.);
      ("beef", v 0. 0. 0. 1. 0. 0.); ("recipe", v 0. 0. 0. 1. 0. 0.); ("cooking", v 0. 0. 0. 1. 0. 0.);
      ("oven", v 0. 0. 0. 0.8 0. 0.); ("electric", v 0. 0. 0. 0. 1. 0.); ("charging", v 0. 0. 0. 0. 0.8 0.);
      ("police", v 0. 0. 0. 0. 0. 0.8); ("stabbing", v 0. 0. 0. 0. 0. 1.); ("murder", v 0. 0. 0. 0. 0. 1.) ];
  Vec.static_embedder table ~dim:6

let fake_oembed (m : Doc.media) =
  if m.kind = Doc.Video then
    Some "What a save! The goalkeeper denied the penalty and the Champions League tie goes on."
  else None

let fake_llm prompt =
  assert (Text.contains prompt "211 = Food & Drink > Alcoholic Beverages");
  {|{"labels":[
      {"id":"211","confidence":0.9,"quote":"Which red wine goes with a football supper?"},
      {"id":"533","confidence":0.5,"quote":"Arsenal fans swear by Rioja."},
      {"id":"9999","confidence":0.99,"quote":"invented"}]}|}

let tiers =
  [ Tier.url_and_hints onto;
    Tier.lexical onto;
    Tier.dense ~similarity:(let s = Tier.similarity_of_embed ~embed onto in fun _ -> s) ~calibrate:(fun _ -> Tier.platt ~a:12. ~b:(-7.2)) ();
    Tier.media ~kinds:[ Doc.Video ] ~describe:fake_oembed onto;
    Tier.llm ~complete:fake_llm onto ]

let ids (r : Cascade.result) = List.map (fun (l : Label.t) -> l.id) r.labels
let score_of (r : Cascade.result) id = (List.find (fun (l : Label.t) -> l.id = id) r.labels).score
let has_tier (r : Cascade.result) name = List.mem name r.ran

(* T0-T2 evidence must quote the page verbatim: explanations are checkable. *)
let quotes_on_page d (r : Cascade.result) =
  let text = Doc.all_text d in
  let on_page (e : Label.evidence) =
    let q = e.quote in
    let q = if String.ends_with ~suffix:"..." q then String.sub q 0 (String.length q - 3) else q in
    (not (List.mem e.tier [ "t0"; "t1"; "t2" ])) || Text.contains text q
  in
  List.for_all (fun (l : Label.t) -> List.for_all on_page l.evidence) r.labels

let show title d (r : Cascade.result) =
  Printf.printf "\n== %s ==\n%s\n%s\n" title d.Doc.url (Cascade.explain onto r)

let sitemap =
  {|<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
        xmlns:news="http://www.google.com/schemas/sitemap-news/0.9">
  <url>
    <loc>https://www.dailysport.example/football/2026/11/04/arsenal-edge-chelsea</loc>
    <lastmod>2026-11-04T21:40:00+00:00</lastmod>
    <news:news>
      <news:publication><news:name>Daily Sport</news:name><news:language>en</news:language></news:publication>
      <news:title>Arsenal edge Chelsea in Premier League thriller</news:title>
      <news:keywords>Premier League, Arsenal, Chelsea</news:keywords>
    </news:news>
  </url>
</urlset>|}

let match_report =
  {|<html><head><title>Late drama at the Emirates</title></head><body>
<nav><a href="/tennis">Tennis</a> <a href="/food">Recipes</a></nav>
<article><p>The striker curled a shot past the keeper in stoppage time.</p>
<p>The midfielder had been booked, and the pitch erupted at the final whistle.</p></article>
<footer>Wine club offers. Cookie policy.</footer></body></html>|}

let wine_page =
  {|<html><head><title>Wine pairing for the big match</title></head><body>
<p>Which red wine goes with a football supper? A rich Rioja works with slow-cooked beef. Pour it before kick-off.</p>
</body></html>|}

let video_page =
  {|<html><head><title>Watch: last night's highlights</title>
<meta property="og:video" content="https://cdn.example/v/123.mp4">
<script type="application/ld+json">{"@context":"https://schema.org","@type":"VideoObject","name":"Highlights","contentUrl":"https://cdn.example/v/123.mp4"}</script>
</head><body><p>Watch the full replay below.</p></body></html>|}

let crime_page =
  {|<html><head><title>Man arrested after fatal stabbing in town centre</title>
<meta name="description" content="Police are appealing for witnesses."></head>
<body><p>Police arrested a 34-year-old man after a fatal stabbing on Monday night. The victim was killed near the station.</p></body></html>|}

let creative id product labels keywords ?(targets = []) ?(blocks = []) () =
  { Matcher.id; product; labels; keywords; targets; blocks; avoid_sensitive = true }

(* Ad Product Taxonomy 2.0 ids: 1070 Footwear, 1004 Beer, 1571 Electric
   Vehicles, 1123 Consumer Packaged Goods. *)
let creatives =
  [ creative "boots" "1070" [ ("533", 0.9) ] [ "football"; "premier league" ] ();
    creative "beer" "1004" [ ("211", 0.9) ] [ "beer" ] ();
    creative "ev" "1571" [ ("22", 0.9) ] [ "electric" ] ~blocks:[ "483" ] ();
    creative "cookware" "1123" [ ("216", 0.9) ] [ "recipe" ] ~targets:[ "210" ] () ]

let affinity =
  let t = Hashtbl.create 4 in
  Hashtbl.replace t ("1004", "483") 0.6;
  t

let show_ranking title ranking =
  Printf.printf "\n== %s ==\n" title;
  List.iter
    (fun ((c : Matcher.creative), v) ->
      match v with
      | Matcher.Blocked why -> Printf.printf "  %-9s blocked  %s\n" c.id why
      | Matcher.Eligible e -> Printf.printf "  %-9s %.3f    %s\n" c.id e.score (String.concat "; " e.reasons))
    ranking

let () =
  (* T0 settles a news-sitemap entry without fetching the page. *)
  let site = Doc.parse_sitemap ~fetch:(fun _ -> failwith "zero-fetch tier fetched") sitemap in
  let arsenal, lastmod = List.hd site.pages in
  let r = Cascade.run onto Cascade.zero_fetch tiers arsenal in
  show "sitemap entry, zero_fetch" arsenal r;
  assert (lastmod = Some "2026-11-04T21:40:00+00:00");
  assert (Doc.sitemap_time "2026-11-04T22:40:00+01:00" = Doc.sitemap_time "2026-11-04T21:40:00.000Z");
  assert (Doc.sitemap_time "2026-11-04" = Some 1793750400. && Doc.sitemap_time "4 Nov" = None);
  let news = Doc.parse_sitemap ~fetch:(fun _ -> Doc.empty)
      {|<urlset><url><loc>https://n.example/a</loc><news:news><news:publication_date>2026-11-05</news:publication_date></news:news></url></urlset>|} in
  assert (List.map snd news.pages = [ Some "2026-11-05" ]);
  assert (r.stop = Cascade.Settled && r.ran = [ "t0-url+hints" ] && r.spent = 0.);
  assert (List.mem "533" (ids r) && List.mem "483" (ids r));
  assert (not (Lazy.is_val arsenal.content));

  (* Vocabulary gap: no lexicon term on the page, nav/footer links ignored. *)
  let late = Doc.of_html ~url:"https://www.dailysport.example/news/2026/11/04/late-drama" match_report in
  let cheap = Cascade.run onto Cascade.zero_fetch tiers late in
  assert (cheap.stop = Cascade.Out_of_budget && cheap.labels = []);
  let r = Cascade.run onto Cascade.standard tiers late in
  show "vocabulary gap, standard" late r;
  assert (r.stop = Cascade.Settled && has_tier r "t2-dense");
  assert (score_of r "533" > 0.9);
  assert (not (List.exists (fun id -> List.mem id [ "539"; "216"; "211" ]) (ids r)));
  assert (quotes_on_page late r);

  (* Media without free text: the video's description settles it (one item:
     og:video and the VideoObject share a src). *)
  let video = Doc.of_html ~url:"https://www.dailysport.example/video/highlights-123" video_page in
  assert (List.length (Tier.undescribed [ Doc.Video ] video) = 1);
  let r = Cascade.run onto Cascade.rich tiers video in
  show "video, rich" video r;
  assert (r.stop = Cascade.Settled && has_tier r "t3-media" && not (has_tier r "t4-llm"));
  assert (score_of r "533" > 0.8);

  (* Deep audit: the LLM overrides T2's over-eager Cooking; its hallucinated
     id is dropped and its unverifiable quote halved below reject. *)
  let wine = Doc.of_html ~url:"https://www.dailysport.example/food/2026/11/wine-pairing-big-match" wine_page in
  let r = Cascade.run onto Cascade.deep tiers wine in
  show "mixed topics, deep" wine r;
  assert (r.stop = Cascade.Exhausted && has_tier r "t4-llm");
  assert (score_of r "211" >= 0.85);
  assert (not (List.exists (fun id -> List.mem id [ "216"; "533"; "9999" ]) (ids r)));
  let alcohol = List.find (fun (l : Label.t) -> l.id = "211") r.labels in
  assert (List.exists (fun (e : Label.evidence) -> e.why = "quote verified on page") alcohol.evidence);
  let halved = Tier.judge ~page:(Text.normalize "the cat sat") [ ("533", 0.8, "dog barked") ] "533" in
  assert (halved.score = 0.4);

  (* Brand suitability. *)
  let crime = Doc.of_html ~url:"https://www.localnews.example/news/man-arrested-after-fatal-stabbing" crime_page in
  let rc = Cascade.run onto Cascade.standard tiers crime in
  show "crime news, standard" crime rc;
  assert (rc.stop = Cascade.Settled && List.mem "XtODT3" (ids rc) && quotes_on_page crime rc);

  (* Matching. *)
  let ranking = Matcher.rank onto ~affinity (Matcher.page_of (Cascade.run onto Cascade.zero_fetch tiers arsenal) arsenal) creatives in
  show_ranking "creatives on the Arsenal page" ranking;
  (match ranking with (c, Matcher.Eligible _) :: _ -> assert (c.id = "boots") | _ -> assert false);
  let verdict id = List.assoc id (List.map (fun ((c : Matcher.creative), v) -> (c.id, v)) ranking) in
  (match verdict "ev" with Matcher.Blocked why -> assert (Text.contains why "Sports") | _ -> assert false);
  (match verdict "cookware" with Matcher.Blocked _ -> () | _ -> assert false);
  let crime_ranking = Matcher.rank onto ~affinity (Matcher.page_of rc crime) creatives in
  show_ranking "creatives on the crime page" crime_ranking;
  assert (List.for_all (function _, Matcher.Blocked _ -> true | _ -> false) crime_ranking);

  (* Slot context: the boundary depends on the format. A weekend food guide;
     the slot sits right after its recipe section, wine sections far away. *)
  let guide = { Matcher.labels = [ ("210", 0.85); ("216", 0.5); ("211", 0.85) ]; keywords = [] } in
  let section offset labels = { Slot.offset; main = true; labels } in
  let sections =
    [ section (-0.3) [ ("210", 0.9); ("216", 0.9) ];
      section (-2.0) [ ("210", 0.9); ("211", 0.9) ];
      section 1.5 [ ("210", 0.9); ("211", 0.9) ] ]
  in
  let most_read offset = { Slot.offset; main = false; labels = [ ("380", 0.9); ("XtODT3", 0.9) ] } in
  let food = List.filter (fun (c : Matcher.creative) -> List.mem c.id [ "cookware"; "beer" ]) creatives in
  let ranking format blocks = Matcher.rank onto ~affinity (Slot.context onto ~format guide blocks) food in
  let best format blocks =
    match ranking format blocks with (c, Matcher.Eligible _) :: _ -> c.Matcher.id | _ -> "none"
  in
  show_ranking "food guide, scroll-through right after the recipe" (ranking "scroll-through" sections);
  show_ranking "food guide, fullscreen" (ranking "fullscreen" sections);
  assert (best "scroll-through" sections = "cookware");
  assert (best "fullscreen" sections = "beer");
  assert (best "scroll-through" (most_read 2.5 :: sections) = "cookware");
  let flagged = ranking "scroll-through" (most_read 0.4 :: sections) in
  show_ranking "same slot, crime headline in a co-visible widget" flagged;
  assert (List.for_all (function _, Matcher.Blocked why -> Text.contains why "brand suitability" | _ -> false) flagged);

  (* Refresh: a 3-word edit keeps the SimHash within 3 bits, another story
     does not; the schedule backs off; hubs are told from articles. *)
  let story = String.concat " " (List.init 300 (fun i -> Printf.sprintf "parola%d" (i mod 97 * 7 + i))) in
  let edited = story ^ " aggiornamento ore dodici" in
  let other = String.concat " " (List.init 300 (fun i -> Printf.sprintf "altro%d" i)) in
  assert (not (Refresh.moved (Refresh.simhash story) (Refresh.simhash edited)));
  assert (Refresh.moved (Refresh.simhash story) (Refresh.simhash other));
  let st = Refresh.of_json (Refresh.to_json { Refresh.url = "u"; etag = "e"; last_modified = ""; simhash = -3L; version = "v";
                                              published = 0.; unchanged = 3; moved = 0; hub = false }) in
  assert (st.simhash = -3L && st.unchanged = 3);
  assert (Refresh.interval ~now:(47. *. 3600.) st = 7200. && Refresh.interval ~now:1e9 st = 8. *. 86400.);
  assert (Refresh.interval ~now:1e9 { st with unchanged = 9 } = 14. *. 86400. && Refresh.interval ~now:1e9 { st with hub = true } = 86400.);
  assert (Refresh.time_of "2026-11-04T10:00:00+0100" = Refresh.time_of "2026-11-04T09:00:00Z" && Refresh.time_of "2026-11-04" <> None);
  let hub url ~dated = Refresh.is_hub ~url ~live:false ~dated ~moved:0 in
  assert (hub "https://www.eurosport.fr/" ~dated:true && hub "https://www.eurosport.fr/football" ~dated:false);
  assert (not (hub "https://www.newsweek.com/could-trump-be-impeached-12656715" ~dated:true));
  assert (not (hub "https://www.gazzetta.it/Calcio/Serie-A/x.shtml" ~dated:false));

  let live =
    Lazy.force
      (Doc.of_html ~url:"https://x.example/live"
         {|<html><head><script type="application/ld+json">{"@type":"LiveBlogPosting","datePublished":"2026-11-10T08:00:00+01:00","headline":"Live"}</script></head><body><p>Goal at minute ten of the match.</p></body></html>|})
        .content
  in
  assert (live.live && live.published = "2026-11-10T08:00:00+01:00");

  (* WARC (FastWARC): a record reads back alone from its gzip member, and a
     file of concatenated members replays in order. *)
  let html = "<html><body><p>Caf\xc3\xa9 r\xc3\xa9sum\xc3\xa9</p></body></html>" in
  let http = Warc.http ~status:200 ~headers:[ ("content-type", "text/html; charset=utf-8"); ("content-encoding", "gzip") ] html in
  let member url = Warc.response ~uri:url ~date:(Warc.iso_date 1794400000.) ~http in
  (match Warc.read (member "https://x.example/a") with
  | Some r ->
      assert (r.uri = "https://x.example/a" && r.status = 200 && r.body = html);
      assert (r.content_type = "text/html; charset=utf-8" && r.date = "2026-11-11T12:26:40Z")
  | None -> assert false);
  let file = Filename.temp_file "ctx" ".warc.gz" in
  Out_channel.with_open_bin file (fun oc -> List.iter (fun u -> output_string oc (member u)) [ "https://x.example/1"; "https://x.example/2" ]);
  assert (List.rev (Warc.fold file (fun acc r -> r.uri :: acc) []) = [ "https://x.example/1"; "https://x.example/2" ]);
  Sys.remove file;
  let page = {|<html><HEAD><meta http-equiv="refresh" content="5"></HEAD><img class=x src="blank.gif" data-src="/a.jpg"></html>|} in
  assert (Replay.prepare ~url:"https://x.example/p" page
          = {|<html><HEAD><base href="https://x.example/p"></HEAD><img src="/a.jpg" class=x data-src="/a.jpg"></html>|});

  (* Ad containers by id, with their place among the blocks; stories by
     <article>, numbered in document order. *)
  let two =
    Lazy.force
      (Doc.of_html ~url:"https://x.example/live"
         {|<html><body><div id="header">x</div><div id="div-gpt-ad-top"></div>
           <article><h1>Derby report</h1><p>The striker scored twice in the derby.</p><div id="ad-mpu-1"></div><p>The keeper saved a penalty.</p></article>
           <article><p>Slow-cooked lamb with rosemary.</p></article><div class="x" id="download-link"></div></body></html>|})
        .content
  in
  assert (two.ad_slots = [ ("div-gpt-ad-top", 0); ("ad-mpu-1", 2) ]);
  assert (List.map (fun (s : Doc.segment) -> s.article) two.segments = [ 1; 1; 1; 2 ]);
  assert (Doc.main_before two.segments 2 = 2 && Doc.after_main two.segments 2 = 2 && Doc.after_main two.segments 9 = 4);
  assert (Store.template "https://www.gazzetta.it/Calcio/Serie-A/Inter/x.shtml" = "gazzetta.it/Calcio#4"
          && Store.template "https://www.gazzetta.it/" = "gazzetta.it#0");
  assert (Html.to_utf8 "c'\xe8 \x93x\x94" = "c'\xc3\xa8 \xe2\x80\x9cx\xe2\x80\x9d" && Html.to_utf8 "d\xc3\xa9j\xc3\xa0" = "d\xc3\xa9j\xc3\xa0");
  assert (List.for_all (fun id -> not (Re.execp Doc.ad_id id)) [ "header"; "download-link"; "advice"; "masthead"; "loading"; "03ad57e2ae8c9629"; "consent-banner" ]);
  assert (List.for_all (Re.execp Doc.ad_id) [ "div-gpt-ad-1699"; "ad_slot_2"; "mpu1"; "top-leaderboard"; "pubblicita-box"; "sidebar-ad" ]);

  (* Page = story: on a URL with a football report then a recipe, a slot in
     the recipe takes the recipe as its page, and the page's own ad slots
     are the candidates. *)
  let sim = Tier.similarity_of_embed ~embed onto in
  let e = { Engine.onto; english = sim; multilingual = [ ("", sim) ]; vision = None; version = "" } in
  let seg i article labels =
    { Profile.tag = "p"; text = "block"; main = true; top = float i; height = 1.; labels; simhash = 0L; article }
  in
  let mixed =
    { Profile.url = "https://x.example/live"; key = "x.example/live"; site = "x.example"; title = ""; fetched_at = 0.;
      keywords = []; t4_gate = ""; version = "";
      levels = [ { preset = "rich"; result = { Cascade.labels = [ { Label.id = "533"; score = 0.8; evidence = [] } ]; spent = 0.; ran = []; stop = Cascade.Settled } } ];
      segments = [ seg 0 1 [ ("533", 0.9) ]; seg 1 1 [ ("533", 0.9) ]; seg 6 2 [ ("216", 0.9) ]; seg 7 2 [ ("216", 0.9) ] ];
      ad_slots =
        [ { id = "ad-1-wrapper"; index = 1; learned = false }; { id = "ad-1"; index = 1; learned = false };
          { id = "ad-2"; index = 3; learned = false } ];
      articles = [ (1, [ ("533", 0.9); ("483", 0.9) ]); (2, [ ("216", 0.9); ("210", 0.9) ]) ] }
  in
  let cookware = List.nth creatives 3 in
  let placed = Engine.slots e ~format:"in-article" ~level:"rich" mixed cookware in
  assert (List.map (fun (s : Engine.slot) -> s.ad) placed = [ "ad-1"; "ad-2" ]);
  (match placed with
  | [ sport; food ] -> assert (food.fit > sport.fit && sport.fit < 0.1)
  | _ -> assert false);

  (* Cold start: an unseen article inherits its top section, then its site. *)
  assert (Store.sections "https://www.dailysport.example/football/2026/11/05/new-signing?utm_source=x&id=a/b"
          = [ "dailysport.example/football"; "dailysport.example" ]);
  assert (Store.sections "https://dailysport.example/?page=2" = [ "dailysport.example" ]);
  assert (Store.sections "https://x.example/\x01" = []);
  assert (Profile.mean_labels ~pages:4 [ ("483", 2.); ("533", 1.2); ("v9i3On", 0.) ] = [ ("483", 0.5); ("533", 0.3) ]);

  (* The bidder's URL normalisation, byte for byte: expectations written by a
     Go implementation ("!" = Go refuses the URL), and the key it reads profiles from. *)
  let fixture = In_channel.with_open_bin "url_key.tsv" In_channel.input_all in
  List.iter
    (fun line ->
      if line <> "" then begin
        let i = String.index line '\t' in
        let url = String.sub line 0 i and want = String.sub line (i + 1) (String.length line - i - 1) in
        let got = match Url_key.normalize url with Ok n -> n | Error _ -> "!" in
        if got <> want then Printf.printf "NormalizeURL %S: want %S, got %S\n" url want got;
        assert (got = want)
      end)
    (String.split_on_char '\n' fixture);
  assert (Url_key.normalize "https://x.example/\x01" |> Result.is_error);
  assert (Url_key.serving_key "https://www.example.com/page/?utm_source=x"
          = Ok "contextual:d641f3ecfa3d1007cb7e145a76a12b4d969513a43ec173d57480df068534f9b8");

  (* Italian and French text: Unicode case, accents, typographic apostrophes,
     guillemets and non-breaking spaces, as BERT's normaliser treats them. *)
  assert (Text.tokens "l’ÉCONOMIE dell’Inter «Macron»\xc2\xa0: città" = [| "l"; "economie"; "dell"; "inter"; "macron"; "citta" |]);
  assert (Text.tokens "" = [||] && Text.tokens " « » " = [||]);
  (* Invalid UTF-8 becomes U+FFFD, which BERT's clean-up drops. *)
  assert (Text.tokens "caf\xff\xfe ok" = [| "caf"; "ok" |]);
  let fr = Ontology.of_tsv ~taxonomy ~lexicon:"52\téconomie\t2\n52\tÉtat\t1" in
  let ids text = List.sort_uniq compare (List.map (fun (id, _, _) -> id) (Ontology.hits fr text)) in
  assert (ids "Ce que l’État change pour l’économie" = [ "52" ]);
  assert (ids (Doc.url_words "https://www.lefigaro.fr/economie/la-dette-de-l-etat-2026") = [ "52" ]);
  assert (Text.contains (Text.normalize "« L’ÉCONOMIE française »") (Text.normalize "l'economie francaise"));

  (* A term with a language fires on pages in it or in none declared; a line
     without one fires everywhere. Prototypes take the same terms. *)
  let lex = Ontology.of_tsv ~taxonomy ~lexicon:"533\tvar\t1\tit\n533\tcalcio\t2\tit-IT\n533\tgoal\t1" in
  let ids lang text = List.sort_uniq compare (List.map (fun (_, t, _) -> t) (Ontology.hits ~lang lex text)) in
  assert (ids "it_IT" "il var e il goal" = [ "goal"; "var" ]);
  assert (ids "en-GB" "the var and the goal" = [ "goal" ]);
  assert (ids "" "var calcio" = [ "calcio"; "var" ]);
  assert (Ontology.terms ~lang:"fr" lex "533" = [ "goal" ] && Ontology.terms ~lang:"it" lex "533" = [ "calcio"; "goal"; "var" ]);
  assert (Ontology.languages lex = [ "it" ] && Ontology.language "EN_us" = "en" && Ontology.language "eng" = "");
  let dup = Ontology.of_tsv ~taxonomy ~lexicon:"539\ttennis\t1\tit\n539\ttennis\t2\tfr\n539\ttennis\t0.5" in
  assert (Ontology.hits dup "tennis" = [ ("539", "tennis", 2.) ] && Ontology.hits ~lang:"it" dup "tennis" = [ ("539", "tennis", 1.) ]);

  (* Depth follows value: a hot article affords the LLM, a long-tail URL does not. *)
  assert (Cascade.value_budget ~daily_impressions:1000. ~cpm:2. () > 1e-3);
  assert (Cascade.value_budget ~daily_impressions:5. ~cpm:2. () < 1e-3);

  (* robots.txt through Google's matcher: our group beats "*", the longest
     pattern wins, Allow wins ties, and the deciding line is reported. *)
  let robots =
    Robots.parse ~agent:"ContextBot"
      "License: https://x.example/site.xml\nUser-agent: *\nDisallow: /\nContent-Usage: ai-use=n\n\nUser-agent: contextbot\nDisallow: /private\nAllow: /private/ok$\nDisallow: /*.pdf\nCrawl-delay: 3\nContent-Usage: ai-use=y\nContent-Usage: /paid/ ai-use=n, train-ai=n\nSitemap: https://x.example/sitemap.xml"
  in
  let at path = "https://x.example" ^ path in
  assert (Robots.allowed robots (at "/football/article"));
  assert (not (Robots.allowed robots (at "/private/page")));
  assert ((Robots.decision robots (at "/private/page")).line = 7);
  assert (Robots.allowed robots (at "/private/ok"));
  assert (not (Robots.allowed robots (at "/private/ok/more")));
  assert (not (Robots.allowed robots (at "/files/report.pdf")));
  assert (robots.delay = Some 3. && robots.sitemaps = [ "https://x.example/sitemap.xml" ]);
  assert (not (Robots.allowed Robots.disallow_all (at "/a")) && Robots.allowed Robots.allow_all (at "/a"));

  (* aipref: Content-Usage rules of our group, longest path first; the "*"
     group's ai-use=n does not apply to us. RSL: no License line in our
     group, so the one outside any group applies. *)
  assert (List.map fst (Robots.content_usage robots (at "/news/x")) = [ "ai-use=y" ]);
  assert (List.map fst (Robots.content_usage robots (at "/paid/x")) = [ "ai-use=n, train-ai=n" ]);
  assert (robots.licenses = [ "https://x.example/site.xml" ]);
  assert (
    (Robots.parse ~agent:"ContextBot" "User-agent: *\nAllow: /\n\nUser-agent: AhrefsBot\nDisallow: /\n\nLicense: https://x.example/l.xml").licenses
    = [ "https://x.example/l.xml" ]);
  assert (Ai_use.preference "ai-use" "train-ai=y, ai-use=n" = Ai_use.Disallow);
  assert (Ai_use.preference "ai-use" "ai-use=y;src=x, search=n" = Ai_use.Allow);
  assert (Ai_use.preference "ai-use" "ai-use=y, ai-use" = Ai_use.Unknown);
  assert (Ai_use.preference "ai-use" "AI-USE=n" = Ai_use.Unknown);
  assert (Ai_use.preference "ai-use" "ai-use=n," = Ai_use.Unknown);
  assert (Ai_use.signal "ai-input" "search=yes, ai-input=no, ai-train=no" = Ai_use.Disallow);
  assert (Ai_use.signal "ai-input" "search=yes, ai-train=no" = Ai_use.Unknown);
  assert ((Robots.parse ~agent:"ContextBot" "User-agent: *\nContent-Signal: ai-input=no\nAllow: /").signals = [ "ai-input=no" ]);

  (* RSL 1.0: the narrowest <content> wins and prohibitions beat permits. *)
  let license =
    Ai_use.Rsl.parse
      {|<rsl xmlns="https://rslstandard.org/rsl">
          <content url="/"><license><permits type="usage">all</permits></license></content>
          <content url="/articles/"><license><prohibits type="usage">ai-train ai-input</prohibits></license></content>
          <content url="/paid/"><license><permits type="usage">ai-input</permits><payment type="use"/></license></content>
        </rsl>|}
  in
  let gate path =
    Ai_use.t4 ~prefs:[] ~licenses:[ ("https://x.example/site.xml", license) ] ~url:(at path) ~path
  in
  assert (match gate "/sport/x" with Ai_use.Allowed _ -> true | Ai_use.Denied _ -> false);
  assert (match gate "/articles/x" with Ai_use.Denied _ -> true | Ai_use.Allowed _ -> false);
  assert (match gate "/paid/x" with Ai_use.Denied _ -> true | Ai_use.Allowed _ -> false);
  assert (Ai_use.Rsl.parse "<rsl><content url=\"/\"/></rsl>" = None);
  assert (Ai_use.Rsl.max_age_days {|<rsl xmlns="https://rslstandard.org/rsl" max-age="7"><content url="/"/></rsl>|} = Some 7);
  assert (
    match Ai_use.t4 ~prefs:[ (Ai_use.preference "ai-use" "ai-use=n", "header") ] ~licenses:[] ~url:(at "/") ~path:"/" with
    | Ai_use.Denied _ -> true
    | Ai_use.Allowed _ -> false);
  assert (
    Ai_use.link_licenses {|<https://x.example/l.xml>; rel="license"; type="application/rsl+xml", <https://x.example/o>; rel="next"|}
    = [ "https://x.example/l.xml" ]);

  (* HTML5 parsing (lexbor): implied end tags, character references, a '>'
     in an attribute, no-break spaces as spaces, a <noscript> pixel left out,
     and formatting reconstructed as a browser would. *)
  let d =
    Doc.parse
      {|<head><title>A &amp; B</title><noscript><img src="https://px.example/p.gif"></noscript></head><p>one<p>two&nbsp;words &copy; <a title="x > y">link</a><img alt="photo" src="/a.jpg"><style>p{}</style>|}
  in
  assert (d.title = "A & B");
  assert (List.map (fun (s : Doc.segment) -> s.text) d.segments = [ "one"; "photo"; "two words \xc2\xa9 link" ]);
  assert (List.map (fun (m : Doc.media) -> m.src) d.media = [ "/a.jpg" ]);
  assert (Html.parse_html "<p>a<b>b</p>c"
          = Html.[ Open ("html", []); Open ("head", []); Close "head"; Open ("body", []); Open ("p", []); Text "a";
                   Open ("b", []); Text "b"; Close "b"; Close "p"; Open ("b", []); Text "c"; Close "b"; Close "body";
                   Close "html" ]);

  (* Segments keep boilerplate for adjacency checks, flagged as not main. *)
  let segs =
    (Doc.parse "<nav><li>Home</li></nav><h1>Match report</h1><p>Body text.</p><aside><li>Most read: man stabbed</li></aside>")
      .segments
  in
  assert (List.map (fun (s : Doc.segment) -> (s.tag, s.main)) segs
          = [ ("li", false); ("h1", true); ("p", true); ("li", false) ]);

  (* Profiles survive the store round trip. *)
  let p =
    { Profile.url = "https://x.example/a"; key = "x.example/a"; site = "x.example"; title = "A"; fetched_at = 1.;
      keywords = [ "k" ]; levels = [ { preset = "rich"; result = Cascade.run onto Cascade.rich tiers late } ];
      segments = Profile.layout segs (List.map (fun _ -> [ ("533", 0.9) ]) segs); t4_gate = "allowed: test"; version = "v";
      ad_slots = [ { Profile.id = "div-gpt-ad-1"; index = 2; learned = false } ]; articles = [ (1, [ ("533", 0.7) ]) ] }
  in
  assert (Profile.of_json (Profile.to_json p) = p);
  let json = Yojson.Safe.to_string (Profile.to_json p) in
  assert (Zstd.decompress (Zstd.compress json) = json && Zstd.decompress_if_framed json = json);

  (* The bidder's view: the "rich" level's labels and the keywords, protobuf. *)
  (match Profile.serving p with
  | Some body ->
      let pb = Profile.Pb.PageProfile.from_proto_exn (Ocaml_protoc_plugin.Reader.create body) in
      assert (pb.preset = "rich" && pb.keywords = [ "k" ] && pb.fetched_at = 1 && pb.version = "v");
      assert (List.map (fun (l : Profile.Pb.Label.t) -> l.id) pb.labels
              = List.map (fun (l : Label.t) -> l.id) (List.hd p.levels).result.labels)
  | None -> assert false);
  let s = Profile.of_serving ~presets:[ "rich"; "deep" ] ~key:"x.example/sport" (Profile.encode ~labels:[ ("483", 0.5) ] ~keywords:[] ~fetched_at:2. ~version:"v" ()) in
  assert (List.map (fun (l : Profile.level) -> List.map (fun (x : Label.t) -> (x.id, x.score)) l.result.labels) s.levels = [ [ ("483", 0.5) ]; [ ("483", 0.5) ] ]);
  assert (s.site = "x.example" && s.segments = [] && s.version = "v");
  (* Golden-set statistics. *)
  let o = Golden.overlap onto ~gold:[ "533" ] ~predicted:[ "483"; "539" ] in
  assert (o = { Golden.hit = 1; predicted = 2; gold = 2 });
  let p, r, _ = Golden.prf [ o ] in
  assert (p = 0.5 && r = 0.5);
  let rng = Random.State.make [| 7 |] in
  let pairs =
    List.init 20_000 (fun _ ->
        let x = Random.State.float rng 2. -. 1. in
        (x, Random.State.float rng 1. < Tier.platt ~a:3. ~b:(-1.) x))
  in
  let a, b = Golden.fit_platt pairs in
  assert (Float.abs (a -. 3.) < 0.3 && Float.abs (b +. 1.) < 0.15);
  assert (Golden.ece (List.map (fun (x, y) -> (Tier.platt ~a ~b x, y)) pairs) < 0.02);
  assert (Golden.ece [ (0.95, false); (0.95, false) ] > 0.9);
  let stated = List.map (fun (x, y) -> (Tier.platt ~a:6. ~b:(-2.) x, y)) pairs in
  assert (Float.abs (Golden.fit_temperature stated -. 2.) < 0.3);
  assert (Golden.accept_threshold [ (0.9, true); (0.8, true); (0.7, false); (0.6, true) ] = Some 0.8);
  assert (Golden.reject_threshold ~miss:0.25 [ (0.1, true); (0.5, true); (0.6, true); (0.9, true); (0.2, false) ] = 0.1);
  print_endline "\nall checks passed"
