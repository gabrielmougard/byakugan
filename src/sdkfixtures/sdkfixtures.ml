(* Fixtures for the Go SDK (sdks/go/contextual/testdata), so the OCaml
   reference and the Go port are checked against the same cases (option A,
   study/matching.md §8):
   - keys.tsv: normalised URL<TAB>Redis key<TAB>its top section's key<TAB>its
     site's key ("" when none, Store.sections), for every URL of the bidder's
     own NormalizeURL fixtures (src/test/url_key.tsv) that Go accepts;
   - context.tsv: served profile with blocks (protobuf, hex)<TAB>format<TAB>
     the bid request's ortb2Imp.ext.data.ctx (JSON)<TAB>Slot.context's labels
     ("id=score;..."), the blocks matched by SimHash as Slot.of_wire does;
   - sensitive.txt: the Sensitive Topics ids, one per line;
   - gpid.tsv: served profile with blocks and ad slots (hex)<TAB>a GPID<TAB>
     Profile.gpid_slot's blocks ("simhash:offset;...", or "none");
   - refusal.tsv: served profile (protobuf, hex)<TAB>targets<TAB>blocks<TAB>
     avoid Sensitive Topics (0/1)<TAB>Matcher.refusal's verdict (eligible,
     block, sensitive or target). The profiles are built as the cascade
     builds them: a few nodes, ancestors added, highest first, at most 20,
     scores rounded to float32 as the wire carries them.
   With --prebid DIR, also DIR/test/simhash.tsv: text<TAB>its words as
   Text.tokens sees them<TAB>Refresh.simhash, for the Prebid module's
   JavaScript.
     sdkfixtures --taxonomy data/content_taxonomy_3.1.tsv --urls test/url_key.tsv -o ../sdks/go/contextual/testdata \
       --prebid ../sdks/prebid *)

open Contextual
module Pb = Protos.Profile.Contextual.V1

let hex s = String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))
let f32 x = Int32.float_of_bits (Int32.bits_of_float x)

let keys ~urls out =
  let oc = open_out_bin out in
  List.iter
    (fun line ->
      match String.split_on_char '\t' line with
      | [ url; normalised ] when normalised <> "!" ->
          let key = "contextual:" ^ Digestif.SHA256.(to_hex (digest_string normalised)) in
          assert (Url_key.serving_key url = Ok key);
          let section, site =
            match List.map Store.section_key (Store.sections url) with
            | [ section; site ] -> (section, site)
            | [ site ] -> ("", site)
            | _ -> ("", "")
          in
          Printf.fprintf oc "%s\t%s\t%s\t%s\n" normalised key section site
      | _ -> ())
    (In_channel.with_open_bin urls In_channel.input_lines);
  close_out oc

let pick rng a = a.(Random.State.int rng (Array.length a))

(* One to four nodes, a third of the time one under Sensitive Topics. *)
let profile rng onto ids sensitive =
  List.init
    (1 + Random.State.int rng 4)
    (fun _ ->
      let id = if Random.State.int rng 3 = 0 then pick rng sensitive else pick rng ids in
      { Label.id; score = Float.round ((0.31 +. Random.State.float rng 0.69) *. 1000.) /. 1000.; evidence = [] })
  |> Label.finalize onto ~reject:0.3
  |> List.filteri (fun i _ -> i < 20)
  |> List.map (fun (l : Label.t) -> (l.id, f32 l.score))

(* Rule ids drawn half from the page, half from anywhere. *)
let some_ids rng ids labels n =
  List.init (Random.State.int rng (n + 1)) (fun _ ->
      if labels <> [] && Random.State.bool rng then fst (List.nth labels (Random.State.int rng (List.length labels)))
      else pick rng ids)

let encode labels =
  Pb.PageProfile.make
    ~labels:(List.map (fun (id, score) -> Pb.Label.make ~id ~score ()) labels)
    ~keywords:[ "fixture" ] ~fetched_at:1793873484 ~preset:"rich" ()
  |> Pb.PageProfile.to_proto |> Ocaml_protoc_plugin.Writer.contents

let verdict onto labels ~targets ~blocks ~avoid =
  let c =
    { Matcher.id = "deal"; product = ""; labels = []; keywords = []; targets; blocks; avoid_sensitive = avoid }
  in
  match Matcher.refusal onto { Matcher.labels; keywords = [] } c with
  | None -> "eligible"
  | Some why when String.starts_with ~prefix:"advertiser blocks" why -> "block"
  | Some why when String.starts_with ~prefix:"brand suitability" why -> "sensitive"
  | Some _ -> "target"

let refusals onto out =
  let rng = Random.State.make [| 20261108 |] in
  let ids = Array.of_list (List.sort compare (Ontology.ids onto)) in
  let sensitive = Array.of_list (List.filter (fun id -> Ontology.is_under onto id ~root:Matcher.sensitive_topics) (Array.to_list ids)) in
  let oc = open_out_bin out in
  for _ = 1 to 3000 do
    let labels = profile rng onto ids sensitive in
    let targets = some_ids rng ids labels 3 and blocks = some_ids rng ids labels 2 and avoid = Random.State.bool rng in
    Printf.fprintf oc "%s\t%s\t%s\t%d\t%s\n" (hex (encode labels)) (String.concat "," targets) (String.concat "," blocks)
      (Bool.to_int avoid) (verdict onto labels ~targets ~blocks ~avoid)
  done;
  close_out oc

let random64 rng = Int64.logor (Int64.shift_left (Random.State.bits64 rng) 1) (Int64.of_int (Random.State.int rng 2))

let flip rng h n =
  let rec go h k = if k = 0 then h else go (Int64.logxor h (Int64.shift_left 1L (Random.State.int rng 64))) (k - 1) in
  go h n

let contexts onto out =
  let rng = Random.State.make [| 20261111 |] in
  let ids = Array.of_list (List.sort compare (Ontology.ids onto)) in
  let sensitive = Array.of_list (List.filter (fun id -> Ontology.is_under onto id ~root:Matcher.sensitive_topics) (Array.to_list ids)) in
  let oc = open_out_bin out in
  for _ = 1 to 2000 do
    let page = profile rng onto ids sensitive in
    let known =
      List.init (Random.State.int rng 10) (fun _ ->
          (random64 rng, Random.State.int rng 5 > 0, List.filteri (fun i _ -> i < 8) (profile rng onto ids sensitive)))
    in
    let wire =
      List.init (Random.State.int rng 9) (fun _ ->
          let hash =
            match known with
            | _ :: _ when Random.State.int rng 10 < 7 ->
                let h, _, _ = List.nth known (Random.State.int rng (List.length known)) in
                flip rng h (Random.State.int rng 6)
            | _ -> random64 rng
          in
          (hash, Float.round ((Random.State.float rng 6. -. 3.) *. 100.) /. 100.))
    in
    let format = [| "fullscreen"; "scroll-through"; "in-article" |].(Random.State.int rng 3) in
    let context = Slot.context onto ~format { Matcher.labels = page; keywords = [] } (Slot.of_wire known wire) in
    let body =
      Pb.PageProfile.make
        ~labels:(List.map (fun (id, score) -> Pb.Label.make ~id ~score ()) page)
        ~blocks:
          (List.map
             (fun (simhash, main, labels) ->
               Pb.Block.make ~simhash ~main ~labels:(List.map (fun (id, score) -> Pb.Label.make ~id ~score ()) labels) ())
             known)
        ~fetched_at:1794400000 ~preset:"rich" ()
      |> Pb.PageProfile.to_proto |> Ocaml_protoc_plugin.Writer.contents
    in
    let ctx =
      Printf.sprintf {|{"v":1,"vh":844,"b":[%s]}|}
        (String.concat "," (List.map (fun (h, d) -> Printf.sprintf {|["%016Lx",%.2f]|} h d) wire))
    in
    Printf.fprintf oc "%s\t%s\t%s\t%s\n" (hex body) format ctx
      (String.concat ";" (List.map (fun (id, s) -> Printf.sprintf "%s=%.9g" id s) context.labels))
  done;
  close_out oc;
  Out_channel.with_open_bin (Filename.concat (Filename.dirname out) "sensitive.txt") (fun oc ->
      Array.iter (fun id -> output_string oc (id ^ "\n")) sensitive)

(* Texts the browser and the crawler must hash alike: five languages,
   typographic punctuation, accents, digits, CJK, symbols, emoji. *)
let texts =
  [ "Marcus Thuram prima di Feyenoord-Inter: «Abbiamo sbagliato, ora dobbiamo vincere»";
    "L’ÉCONOMIE française résiste : la Banque de France relève sa prévision de croissance à 1,2 %";
    "Der FC Bayern München gewinnt 3:1 gegen Borussia Dortmund – Kane trifft doppelt";
    "El Real Madrid golea al Atlético en el derbi y se coloca líder de LaLiga";
    "Breaking: Prime Minister announces £2.5bn package for the NHS after winter crisis";
    "Città, perché l’inflazione è scesa al 2,1% a ottobre? Ecco cosa dice l’Istat";
    "Ça y est : les aurores boréales seront visibles ce dimanche 5 novembre en France";
    "Größte Übernahme des Jahres: Siemens kauft Software-Firma für 10 Mrd. Euro";
    "¿Quién ganará el Balón de Oro 2026? Los cinco favoritos según los expertos";
    "Apple’s iPhone 18 Pro review — the camera is great, the battery isn't";
    "东京奥运会 女子100米 决赛 结果 公布";
    "Prix : 49,99 € TTC (au lieu de 69 €) — offre valable jusqu’au 30/11";
    "Recipe: slow-cooked lamb shoulder with rosemary & garlic (serves 6–8)";
    "Mortal accident on the A1 motorway: two dead, three injured, police said";
    "Serie A, la classifica aggiornata dopo la 12ª giornata: Napoli 28, Inter 27, Milan 25";
    "🔥 Les 10 séries Netflix à ne pas manquer en novembre 🍿";
    "Il governo Meloni approva la manovra: cosa cambia per pensioni, Irpef e bonus casa";
    "Champions League: Real Madrid vs. Liverpool — live updates, line-ups & score";
    "Die Inflationsrate in Deutschland ist im Oktober auf 2,3 Prozent gestiegen";
    "La Bourse de Paris termine en hausse de 0,8 %, portée par le luxe et l’automobile";
    "  Spaces\u{00a0}and\u{00a0}no-break spaces   around   words  ";
    "Tennis: Sinner batte Alcaraz in tre set e vola in finale alle ATP Finals di Torino";
    "Nuevo récord de temperaturas en España: 44,5 grados en Córdoba";
    "What the Fed’s rate cut means for your mortgage, savings and 401(k)";
    "Kim Kardashian x Skims : la collab mode qui affole les réseaux sociaux" ]

let gpids out =
  let rng = Random.State.make [| 20261112 |] in
  let oc = open_out_bin out in
  for _ = 1 to 1000 do
    let blocks =
      List.init (Random.State.int rng 40) (fun _ ->
          (random64 rng, Random.State.bool rng, [ ("483", f32 0.5) ], f32 (Random.State.float rng 30.)))
    in
    let tops = List.init (Random.State.int rng 5) (fun i -> (Printf.sprintf "div-gpt-ad-%d" i, f32 (Random.State.float rng 30.))) in
    let gpid =
      match Random.State.int rng 3 with
      | 0 -> "/1234/news#div-gpt-ad-" ^ string_of_int (Random.State.int rng 6)
      | 1 -> "div-gpt-ad-" ^ string_of_int (Random.State.int rng 6)
      | _ -> "/1234/news/top"
    in
    let body =
      Pb.PageProfile.make
        ~blocks:
          (List.map
             (fun (simhash, main, labels, top) ->
               Pb.Block.make ~simhash ~main ~top ~labels:(List.map (fun (id, score) -> Pb.Label.make ~id ~score ()) labels) ())
             blocks)
        ~ad_slots:(List.map (fun (id, top) -> Pb.AdSlot.make ~id ~top ()) tops)
        ~fetched_at:1794400000 ~preset:"rich" ()
      |> Pb.PageProfile.to_proto |> Ocaml_protoc_plugin.Writer.contents
    in
    let expected =
      match Profile.gpid_slot ~tops ~blocks gpid with
      | None -> "none"
      | Some wire -> String.concat ";" (List.map (fun (h, d) -> Printf.sprintf "%016Lx:%.9g" h d) wire)
    in
    Printf.fprintf oc "%s\t%s\t%s\n" (hex body) gpid expected
  done;
  close_out oc

let simhashes dir =
  Out_channel.with_open_bin (Filename.concat dir "test/simhash.tsv") (fun oc ->
      List.iter
        (fun t ->
          Printf.fprintf oc "%s\t%s\t%016Lx\n" t (String.concat " " (Array.to_list (Text.tokens t))) (Refresh.simhash t))
        texts)

let () =
  let taxonomy = ref "data/content_taxonomy_3.1.tsv" and urls = ref "test/url_key.tsv" and out = ref "" in
  let prebid = ref "" in
  Arg.parse
    [ ("--taxonomy", Arg.Set_string taxonomy, "FILE IAB Content Taxonomy 3.1 TSV");
      ("--urls", Arg.Set_string urls, "FILE url<TAB>normalised fixtures");
      ("-o", Arg.Set_string out, "DIR output directory");
      ("--prebid", Arg.Set_string prebid, "DIR the Prebid module, for its test/simhash.tsv") ]
    ignore "sdkfixtures -o DIR";
  if !out = "" then failwith "-o is required";
  let onto = Ontology.of_tsv ~taxonomy:(In_channel.with_open_bin !taxonomy In_channel.input_all) ~lexicon:"" in
  keys ~urls:!urls (Filename.concat !out "keys.tsv");
  refusals onto (Filename.concat !out "refusal.tsv");
  contexts onto (Filename.concat !out "context.tsv");
  gpids (Filename.concat !out "gpid.tsv");
  if !prebid <> "" then simhashes !prebid
