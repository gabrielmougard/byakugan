(* The page's key in the lab: the bidder's normalisation, or the URL itself
   when Go would refuse it (the bidder then never looks the page up). *)
let normalize url = match Url_key.normalize url with Ok n -> n | Error _ -> url

(* What a page nobody crawled yet inherits until the crawler gets to it: its
   top section (first path segment), then its site, each the mean of the
   pages crawled there (Lab.save_profile). Prefixes of the bidder's
   normalised URL, query left out; a site's top page has no section, and a
   URL Go refuses has neither. sdks/go's Sections spells them the same.
   sections "https://www.dailysport.example/football/2026/11/05/new-signing"
   = [ "dailysport.example/football"; "dailysport.example" ] *)
let sections url =
  match Url_key.normalize url with
  | Error _ -> []
  | Ok n -> (
      match String.split_on_char '/' (List.hd (String.split_on_char '?' n)) with
      | "" :: _ | [] -> []
      | site :: section :: _ when section <> "" -> [ site ^ "/" ^ section; site ]
      | site :: _ -> [ site ])

(* Apart from pages' keys: a section's top page normalises to the same
   string as the section. *)
let section_key prefix = "contextual:section:" ^ Digestif.SHA256.(to_hex (digest_string prefix))

(* Pages that share a layout: the site, the top section and the URL depth,
   capped at 4. Ad slot positions are learned per template.
   template "https://www.gazzetta.it/Calcio/Serie-A/Inter/x.shtml"
   = "gazzetta.it/Calcio#4"; template "https://www.gazzetta.it/" = "gazzetta.it#0" *)
let template url =
  match Url_key.normalize url with
  | Error _ -> ""
  | Ok n -> (
      match List.filter (( <> ) "") (String.split_on_char '/' (List.hd (String.split_on_char '?' n))) with
      | [] -> ""
      | [ site ] -> site ^ "#0"
      | site :: first :: rest -> Printf.sprintf "%s/%s#%d" site first (min 4 (1 + List.length rest)))
