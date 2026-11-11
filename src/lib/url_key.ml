(* The URL normalisation pages are keyed by: DoubleVerify's IQC rules 1-3
   over Go 1.27's net/url.Parse, byte for byte, as a Go bidder applies them
   before hashing the URL into the Redis key it looks a page up by. A URL Go
   refuses is refused here too, so no profile is written under a key the
   bidder can never compute. Fixtures: src/test/url_key.tsv, written by a Go
   implementation (a package main that normalises one URL per stdin line;
   "!" when it returns an error). *)

exception Bad of string

let is_hex = function '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false
let unhex c = match c with '0' .. '9' -> Char.code c - 48 | 'a' .. 'f' -> Char.code c - 87 | _ -> Char.code c - 55

(* Bytes Go accepts unescaped in a host (encodeHost in net/url). *)
let host_byte c =
  Char.code c >= 0x80
  || match c with
     | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '!' | '"' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | '-' | '.'
     | ':' | ';' | '<' | '=' | '>' | '[' | ']' | '_' | '~' ->
         true
     | _ -> false

type mode = Plain | Host | Zone

let unescape mode s =
  let n = String.length s in
  let b = Buffer.create n in
  let rec go i =
    if i < n then
      if s.[i] = '%' then begin
        if i + 2 >= n || not (is_hex s.[i + 1] && is_hex s.[i + 2]) then raise (Bad "invalid URL escape");
        let v = (unhex s.[i + 1] lsl 4) lor unhex s.[i + 2] in
        let pct25 = String.sub s i 3 = "%25" in
        if mode = Host && unhex s.[i + 1] < 8 && not pct25 then raise (Bad "invalid URL escape");
        if mode = Zone && (not pct25) && v <> 0x20 && not (host_byte (Char.chr v)) then raise (Bad "invalid URL escape");
        Buffer.add_char b (Char.chr v);
        go (i + 3)
      end
      else begin
        if mode <> Plain && not (host_byte s.[i]) then raise (Bad "invalid character in host name");
        Buffer.add_char b s.[i];
        go (i + 1)
      end
  in
  go 0;
  Buffer.contents b

let cut s c = match String.index_opt s c with Some i -> (String.sub s 0 i, Some (String.sub s (i + 1) (String.length s - i - 1))) | None -> (s, None)
let from s i = String.sub s i (String.length s - i)
let starts p s = String.starts_with ~prefix:p s

let find s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = if i + m > n then None else if String.sub s i m = sub then Some i else go (i + 1) in
  go 0

let valid_port p = p = "" || (p.[0] = ':' && String.for_all (fun c -> c >= '0' && c <= '9') (from p 1))

let scheme_of raw =
  let n = String.length raw in
  let rec go i =
    if i = n then ("", raw)
    else
      match raw.[i] with
      | 'a' .. 'z' | 'A' .. 'Z' -> go (i + 1)
      | '0' .. '9' | '+' | '-' | '.' -> if i = 0 then ("", raw) else go (i + 1)
      | ':' -> if i = 0 then raise (Bad "missing protocol scheme") else (String.sub raw 0 i, from raw (i + 1))
      | _ -> ("", raw)
  in
  go 0

(* shortcut: an IP literal must be IPv6, which netip.ParseAddr checks fully;
   here only its alphabet is. Page URLs with IP literals do not occur in bid
   requests; port the parser if they ever matter. *)
let ip_literal host =
  let close = match String.rindex_opt host ']' with Some i -> i | None -> raise (Bad "missing ']' in host") in
  let port = from host (close + 1) in
  if not (valid_port port) then raise (Bad "invalid port after host");
  let name = String.sub host 1 (close - 1) in
  let name =
    match find name "%25" with
    | Some z -> unescape Host (String.sub name 0 z) ^ unescape Zone (from name z)
    | None -> unescape Host name
  in
  let addr = fst (cut name '%') in
  if not (String.contains addr ':' && String.for_all (fun c -> is_hex c || c = ':' || c = '.') addr) then
    raise (Bad "invalid IP-literal");
  "[" ^ name ^ "]" ^ unescape Host port

let parse_host scheme host =
  match String.rindex_opt host '[' with
  | Some i when i > 0 -> raise (Bad "invalid IP-literal")
  | Some _ -> ip_literal host
  | None ->
      (match String.index_opt host ':' with
      | Some first ->
          (* Go 1.26+ (urlstrictcolons): http(s) hosts take the port at the first colon. *)
          let i = if scheme = "http" || scheme = "https" then first else String.rindex host ':' in
          if not (valid_port (from host i)) then raise (Bad "invalid port after host")
      | None -> ());
      unescape Host host

let userinfo_byte = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | ':' | '~' | '!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+'
  | ',' | ';' | '=' | '%' | '@' ->
      true
  | _ -> false

let parse_authority scheme authority =
  match String.rindex_opt authority '@' with
  | None -> parse_host scheme authority
  | Some i ->
      let host = parse_host scheme (from authority (i + 1)) in
      let user = String.sub authority 0 i in
      if not (String.for_all userinfo_byte user) then raise (Bad "invalid userinfo");
      let name, pass = cut user ':' in
      ignore (unescape Plain name);
      Option.iter (fun p -> ignore (unescape Plain p)) pass;
      host

(* Host, path and raw query, as net/url.Parse leaves them in a URL. *)
let parse raw =
  let u, frag = cut raw '#' in
  if String.exists (fun c -> c < ' ' || c = '\x7f') u then raise (Bad "invalid control character in URL");
  let parsed =
    if u = "*" then ("", "*", "")
    else
      let scheme, rest = scheme_of u in
      let scheme = String.lowercase_ascii scheme in
      let rest, query =
        let n = String.length rest in
        if n > 0 && rest.[n - 1] = '?' && String.index rest '?' = n - 1 then (String.sub rest 0 (n - 1), "")
        else match cut rest '?' with r, q -> (r, Option.value q ~default:"")
      in
      if (not (starts "/" rest)) && scheme <> "" then ("", "", query)
      else begin
        if (not (starts "/" rest)) && String.contains (fst (cut rest '/')) ':' then
          raise (Bad "first path segment in URL cannot contain colon");
        let host, rest =
          if (scheme <> "" || not (starts "///" rest)) && starts "//" rest then
            let authority, path = match String.index_from_opt rest 2 '/' with
              | Some i -> (String.sub rest 2 (i - 2), from rest i)
              | None -> (from rest 2, "")
            in
            (parse_authority scheme authority, path)
          else ("", rest)
        in
        (host, unescape Plain rest, query)
      end
  in
  Option.iter (fun f -> ignore (unescape Plain f)) frag;
  parsed

(* DV Rule 2, as the bidder's regexp:
     {|(?i)(\?|&|%3F|%26|;)(?:utm_campaign|...|cmp)=[^&]*|}
   Go's (?i) also folds U+212A (Kelvin sign) to k and U+017F (long s) to s. *)
let tracking_keys =
  [ "utm_campaign"; "utm_source"; "utm_content"; "utm_term"; "utm_viral"; "utm_medium"; "utm_identifier"; "utm_key";
    "fb_source"; "referrer"; "referer"; "ref"; "rand"; "rnd"; "randid"; ".rand"; ".partner"; "partner"; "cb"; "count";
    "adid"; "session"; "sessionid"; "session_redirect"; "userinfo"; "uid"; "refresh"; "ocid"; "ncid"; "clickenc";
    "fbclid"; "amp_js_v"; "amp_gsa"; "ns_source"; "ns_campaign"; "ns_mchanel"; "ns_mchannel"; "ns_linkname"; "ns_fee";
    "src"; "ex_cid"; "usqp"; "source"; "xid"; "trkid"; "utm_social-type"; "mbid"; "utm_brand"; "__twitter_impression";
    "utm_referrer"; "cmp"; "param#" ]

(* Where the match ends when [key] (lowercase; '#' = one ASCII digit)
   starts at [i]: match_key "?param12=a" 1 "param#" = Some 7. *)
let match_key s i key =
  let n = String.length s in
  let rec go i k =
    if k = String.length key then Some i
    else if i >= n then None
    else
      let c = key.[k] and d = s.[i] in
      if c = '#' then (if d >= '0' && d <= '9' then go (i + 1) (k + 1) else None)
      else if Char.lowercase_ascii d = c then go (i + 1) (k + 1)
      else if c = 'k' && i + 2 < n && String.sub s i 3 = "\xe2\x84\xaa" then go (i + 3) (k + 1)
      else if c = 's' && i + 1 < n && String.sub s i 2 = "\xc5\xbf" then go (i + 2) (k + 1)
      else None
  in
  go i 0

let delimiter s i =
  match s.[i] with
  | '?' | '&' | ';' -> Some 1
  | '%' when i + 2 < String.length s ->
      (match String.lowercase_ascii (String.sub s i 3) with "%3f" | "%26" -> Some 3 | _ -> None)
  | _ -> None

let tracking_param s i =
  match delimiter s i with
  | None -> None
  | Some d ->
      let n = String.length s in
      let keyed = List.exists (fun k -> match match_key s (i + d) k with Some e -> e < n && s.[e] = '=' | None -> false) tracking_keys in
      if keyed then Some (match String.index_from_opt s (i + d) '&' with Some e -> e | None -> n) else None

(* A tracking parameter goes with the delimiter before it, except a leading
   ?, which stays: strip_tracking "utm_source=x&keep=1" = "&keep=1", so
   https://example.com/page?utm_source=x&keep=1 keys as example.com/page?&keep=1. *)
let strip_tracking raw_query =
  let s = "?" ^ raw_query in
  let n = String.length s in
  let b = Buffer.create n in
  let rec go i =
    if i < n then
      match tracking_param s i with
      | Some e -> if s.[i] = '?' then Buffer.add_char b '?'; go e
      | None -> Buffer.add_char b s.[i]; go (i + 1)
  in
  go 0;
  let out = Buffer.contents b in
  if starts "?" out then from out 1 else out

(* DV Rule 3: {|(?i)/amp(?:/[?&]*)?$|}
   strip_trailing_amp "example.com/page/amp/" = "example.com/page" *)
let strip_trailing_amp s =
  let n = String.length s in
  let amp_at i =
    s.[i] = '/' && i + 4 <= n
    && String.lowercase_ascii (String.sub s (i + 1) 3) = "amp"
    && (i + 4 = n || (s.[i + 4] = '/' && String.for_all (fun c -> c = '?' || c = '&') (from s (i + 5))))
  in
  let rec go i = if i >= n then s else if amp_at i then String.sub s 0 i else go (i + 1) in
  go 0

(* The key, in steps (src/test/url_key.tsv has the edge cases):

     https://www.example.com/news/article/amp?utm_source=x&fbclid=y#top
       │ net/url.Parse: fragment, scheme and userinfo dropped, path
       │ unescaped, query kept raw; a URL Go refuses is an Error
       ▼
     host www.example.com   path /news/article/amp   query utm_source=x&fbclid=y
       │ host without a leading "www.", path without one trailing "/"
       │ tracking parameters out of the query (DV rule 2, strip_tracking)
       ▼
     example.com /news/article/amp ""
       │ host ^ path, then "?" ^ query unless the query is empty
       │ a trailing /amp out (DV rule 3, strip_trailing_amp)
       ▼
     example.com/news/article

   Host case and port are kept: "https://example.com:8080/a/" gives
   "example.com:8080/a". *)
let normalize raw =
  if raw = "" then Ok ""
  else
    match parse raw with
    | exception Bad e -> Error e
    | host, path, query ->
        let host = if starts "www." host then from host 4 else host in
        let path = if String.ends_with ~suffix:"/" path then String.sub path 0 (String.length path - 1) else path in
        let query = strip_tracking query in
        Ok (strip_trailing_amp (host ^ path ^ if query = "" then "" else "?" ^ query))

(* The Redis key the bidder reads a page's profile from. *)
let serving_key raw =
  Result.map (fun n -> "contextual:" ^ Digestif.SHA256.(to_hex (digest_string n))) (normalize raw)
