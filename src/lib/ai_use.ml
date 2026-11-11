(* May this page's text go into a generative model? T4 sends a condensed page
   to an LLM, which is "AI Use" in IETF aipref (draft-ietf-aipref-vocab-08
   §4.2) and "ai-input" in RSL 1.0 (§3.4.1.1). Two publisher signals are
   checked, and the most restrictive answer wins:
   - aipref: Content-Usage rules in robots.txt (draft-ietf-aipref-attach-05
     §3, found by Robots.content_usage) and the page's Content-Usage header;
   - RSL: license documents named by robots.txt License lines, the page's
     Link header, or <link rel="license" type="application/rsl+xml">.
   Cloudflare Content Signals ("Content-Signal: ai-input=no" in robots.txt),
   which RSL 1.0 §3.4.1.1 folds into its usage vocabulary, count like aipref.
   Nothing here is hot (once per page or per license document), so it is
   plain OCaml. *)

type pref = Allow | Disallow | Unknown

(* RFC 9651 Dictionary: the full grammar, so that malformed statements are
   rejected as the vocabulary requires (§6.5.1: then every preference is
   unknown). Values other than tokens are kept as Other. *)
module Sf = struct
  exception Fail

  type item = Token of string | Other

  let is_lcalpha c = c >= 'a' && c <= 'z'
  let is_alpha c = is_lcalpha c || (c >= 'A' && c <= 'Z')
  let is_digit c = c >= '0' && c <= '9'
  let is_tchar c = is_alpha c || is_digit c || String.contains "!#$%&'*+-.^_`|~" c
  let is_base64 c = is_alpha c || is_digit c || String.contains "+/=" c

  let parse_dictionary s =
    let n = String.length s and i = ref 0 in
    let peek () = if !i < n then Some s.[!i] else None in
    let advance () = incr i in
    let expect c = if peek () = Some c then advance () else raise Fail in
    let skip p = while (match peek () with Some c -> p c | None -> false) do advance () done in
    let sp () = skip (fun c -> c = ' ') in
    let ows () = skip (fun c -> c = ' ' || c = '\t') in
    let take p =
      let start = !i in
      skip p;
      String.sub s start (!i - start)
    in
    let key () =
      match peek () with
      | Some c when is_lcalpha c || c = '*' ->
          take (fun c -> is_lcalpha c || is_digit c || String.contains "_-.*" c)
      | _ -> raise Fail
    in
    let number () =
      if peek () = Some '-' then advance ();
      let int_part = take is_digit in
      if int_part = "" || String.length int_part > 15 then raise Fail;
      if peek () = Some '.' then (
        advance ();
        let frac = take is_digit in
        if String.length int_part > 12 || frac = "" || String.length frac > 3 then raise Fail)
    in
    let quoted ~display =
      advance ();
      let rec go () =
        match peek () with
        | None -> raise Fail
        | Some '"' -> advance ()
        | Some '\\' when not display -> (
            advance ();
            match peek () with Some ('"' | '\\') -> advance (); go () | _ -> raise Fail)
        | Some c when c < ' ' || c > '~' -> raise Fail
        | Some _ -> advance (); go ()
      in
      go ()
    in
    let bare_item () =
      match peek () with
      | Some c when c = '-' || is_digit c -> number (); Other
      | Some '"' -> quoted ~display:false; Other
      | Some c when is_alpha c || c = '*' ->
          Token (take (fun c -> is_tchar c || c = ':' || c = '/'))
      | Some ':' -> advance (); ignore (take is_base64); expect ':'; Other
      | Some '?' -> (
          advance ();
          match peek () with Some ('0' | '1') -> advance (); Other | _ -> raise Fail)
      | Some '@' -> advance (); number (); Other
      | Some '%' -> advance (); if peek () <> Some '"' then raise Fail; quoted ~display:true; Other
      | _ -> raise Fail
    in
    let parameters () =
      while peek () = Some ';' do
        advance ();
        sp ();
        ignore (key ());
        if peek () = Some '=' then (advance (); ignore (bare_item ()))
      done
    in
    let member () =
      if peek () = Some '(' then (
        advance ();
        let rec items () =
          sp ();
          if peek () = Some ')' then advance ()
          else (
            ignore (bare_item ());
            parameters ();
            match peek () with Some (' ' | ')') -> items () | _ -> raise Fail)
        in
        items ();
        parameters ();
        Other)
      else
        let v = bare_item () in
        parameters ();
        v
    in
    sp ();
    let entries = ref [] in
    let rec loop () =
      if !i < n then (
        let k = key () in
        let v = if peek () = Some '=' then (advance (); member ()) else (parameters (); Other) in
        entries := (k, v) :: !entries;
        ows ();
        if !i < n then (
          expect ',';
          ows ();
          if !i >= n then raise Fail;
          loop ()))
    in
    loop ();
    (* Duplicate keys: the last value wins (RFC 9651 §4.2.2). *)
    !entries
end

(* vocab §6.5: preference "ai-use" "train-ai=y, ai-use=n" = Disallow; a
   malformed statement such as "ai-use=n," is Unknown for every category. *)
let preference category statement =
  match Sf.parse_dictionary statement with
  | exception Sf.Fail -> Unknown
  | entries -> (
      match List.assoc_opt category entries with
      | Some (Sf.Token "y") -> Allow
      | Some (Sf.Token "n") -> Disallow
      | _ -> Unknown)

(* Content Signals: "search=yes, ai-input=no, ai-train=no"; the last value
   for a key wins, anything but yes/no is unknown. *)
let signal key statement =
  List.fold_left
    (fun acc part ->
      match String.split_on_char '=' part with
      | [ k; v ] when String.lowercase_ascii (String.trim k) = key -> (
          match String.lowercase_ascii (String.trim v) with "yes" -> Allow | "no" -> Disallow | _ -> acc)
      | _ -> acc)
    Unknown (String.split_on_char ',' statement)

(* vocab §5.1: any disallow wins, then any allow, else unknown. *)
let combine prefs =
  if List.mem Disallow prefs then Disallow else if List.mem Allow prefs then Allow else Unknown

(* RSL 1.0 *)
module Rsl = struct
  type terms = (string * string list) list (* type attribute -> tokens *)

  type license = { permits : terms; prohibits : terms; payment : string option }
  type content = { url : string; server : bool; licenses : license list }

  let namespace = "https://rslstandard.org/rsl"
  let local name = match String.index_opt name ':' with Some i -> String.sub name (i + 1) (String.length name - i - 1) | None -> name
  let words s = List.filter (( <> ) "") (String.split_on_char ' ' (String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) s))

  (* None unless the root is <rsl xmlns="https://rslstandard.org/rsl">
     (§4.3: an invalid document leaves the asset unlicensed). *)
  let parse xml =
    let contents = ref [] and content = ref None and license = ref None and terms = ref None in
    let root_ok = ref None in
    let attr a k = Option.value (List.assoc_opt k a) ~default:"" in
    let close_license () =
      match (!content, !license) with
      | Some c, Some l -> content := Some { c with licenses = l :: c.licenses }; license := None
      | _ -> ()
    in
    List.iter
      (function
        | Html.Open (tag, a) -> (
            match local tag with
            | "rsl" when !root_ok = None ->
                root_ok := Some (attr a "xmlns" = namespace || attr a "xmlns:rsl" = namespace)
            | "content" -> content := Some { url = attr a "url"; server = attr a "server" <> ""; licenses = [] }
            | "license" -> license := Some { permits = []; prohibits = []; payment = None }
            | ("permits" | "prohibits") as kind -> terms := Some (kind, attr a "type", Buffer.create 32)
            | "payment" ->
                Option.iter
                  (fun l -> license := Some { l with payment = Some (match attr a "type" with "" -> "free" | t -> t) })
                  !license
            | _ -> ())
        | Html.Text s -> Option.iter (fun (_, _, b) -> Buffer.add_string b s) !terms
        | Html.Close tag -> (
            match local tag with
            | "permits" | "prohibits" -> (
                match (!terms, !license) with
                | Some (kind, ty, b), Some l ->
                    let entry = ((if ty = "" then "usage" else ty), words (Buffer.contents b)) in
                    license :=
                      Some (if kind = "permits" then { l with permits = entry :: l.permits } else { l with prohibits = entry :: l.prohibits });
                    terms := None
                | _ -> terms := None)
            | "license" -> close_license ()
            | "content" ->
                close_license ();
                Option.iter (fun c -> contents := c :: !contents) !content;
                content := None
            | _ -> ())
        | Html.Script _ -> ())
      (Html.tokenize xml);
    if !root_ok = Some true && !contents <> [] then Some (List.rev !contents) else None

  (* §3.2.1: the root's max-age, in days. *)
  let max_age_days xml =
    List.find_map
      (function Html.Open (tag, a) when local tag = "rsl" -> Option.bind (List.assoc_opt "max-age" a) int_of_string_opt | _ -> None)
      (Html.tokenize xml)

  let covers ~url ~path c =
    c.url = "" || (c.url.[0] = '/' && String.starts_with ~prefix:c.url path) || String.starts_with ~prefix:c.url url

  let mentions terms ty tokens = List.exists (fun (t, ws) -> t = ty && List.exists (fun x -> List.mem x ws) tokens) terms
  let has terms ty = List.exists (fun (t, _) -> t = ty) terms

  (* Our use: "ai-input" (or the umbrella "ai-all" / "all") by a commercial
     user. Read conservatively, as §3.1.1 requires: any prohibition wins, a
     <permits> list must name our use, and anything we cannot satisfy
     unattended (payment, attribution, a license server, geographic terms)
     counts as not licensed. *)
  let usage = [ "ai-input"; "ai-all"; "all" ]

  let license_allows l =
    (not (mentions l.prohibits "usage" usage))
    && (not (mentions l.prohibits "user" [ "commercial" ]))
    && ((not (has l.permits "usage")) || mentions l.permits "usage" usage)
    && ((not (has l.permits "user")) || mentions l.permits "user" [ "commercial" ])
    && (not (has l.permits "geo"))
    && (not (has l.prohibits "geo"))
    && (l.payment = None || l.payment = Some "free")

  (* §3.1.1: the most specific <content> scope that covers the page. *)
  let verdict doc ~url ~path =
    let covering = List.filter (covers ~url ~path) doc in
    match List.sort (fun a b -> compare (String.length b.url) (String.length a.url)) covering with
    | [] -> Error "no <content> covers this page"
    | c :: _ when c.server -> Error ("a license server token is required (" ^ c.url ^ ")")
    | c :: _ when List.exists (fun l -> mentions l.prohibits "usage" usage) c.licenses -> Error "ai-input is prohibited"
    | c :: _ when List.exists license_allows c.licenses -> Ok ()
    | _ :: _ -> Error "no free license for commercial ai-input"
end

(* RFC 8288 Link header values naming an RSL license (RSL §4.5). *)
let link_licenses header =
  let re = Re.Perl.compile_pat {|<([^>]*)>([^,<]*)|} in
  List.filter_map
    (fun g ->
      let params = String.lowercase_ascii (Re.Group.get g 2) in
      let has p = Re.execp (Re.Perl.compile_pat p) params in
      if has {|rel\s*=\s*"?license"?|} && has {|type\s*=\s*"?application/rsl\+xml"?|} then Some (Re.Group.get g 1)
      else None)
    (Re.all re header)

(* <link rel="license" type="application/rsl+xml" href> (RSL §4.6). *)
let html_licenses html =
  List.filter_map
    (function
      | Html.Open ("link", a) ->
          let get k = String.lowercase_ascii (Option.value (List.assoc_opt k a) ~default:"") in
          if List.mem "license" (String.split_on_char ' ' (get "rel")) && get "type" = "application/rsl+xml" then
            List.assoc_opt "href" a
          else None
      | _ -> None)
    (Html.parse_html html)

type verdict = Allowed of string | Denied of string

let verdict_text = function Allowed why -> "allowed: " ^ why | Denied why -> "denied: " ^ why

(* [prefs]: each stated preference for our use and where it was found
   (aipref "ai-use" or Content Signals "ai-input"). [licenses]: (license
   URL, parsed document, or None if it could not be fetched or is not RSL). *)
let t4 ~prefs ~licenses ~url ~path =
  let stated = combine (List.map fst prefs) in
  let denied_by = List.filter_map (fun (p, where) -> if p = Disallow then Some where else None) prefs in
  match stated, licenses with
  | Disallow, _ -> Denied ("publisher opts out of AI use (" ^ String.concat ", " denied_by ^ ")")
  | _, [] -> Allowed (if stated = Allow then "AI use allowed, no RSL license" else "no stated preference, no RSL license")
  | _, _ -> (
      let problems =
        List.filter_map
          (fun (u, doc) ->
            match doc with
            | None -> Some ("RSL license unavailable or invalid: " ^ u)
            | Some d -> ( match Rsl.verdict d ~url ~path with Ok () -> None | Error e -> Some ("RSL " ^ u ^ ": " ^ e)))
          licenses
      in
      match problems with
      | [] -> Allowed "RSL license permits commercial ai-input"
      | p :: _ -> Denied p)
