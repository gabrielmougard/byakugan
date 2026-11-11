(* When to fetch a stored page again, and whether what came back is worth
   reclassifying (study/architecture.md §3).

     fetch, the last ETag and Last-Modified sent back as If-None-Match
     and If-Modified-Since
       ├─ 304 ─▶ unchanged, free
       └─ 200 ─▶ main text's SimHash within 3 bits of the last one,
                 and the same pipeline version?
                   ├─ yes ─▶ unchanged
                   └─ no ──▶ reclassify

     next fetch in ([interval])
       hub                              1 d
       under 48 h since publication     2 h
       then                             1 d ─▶ 2 d ─▶ 4 d ─▶ 8 d ─▶ 14 d (cap)
                                        doubling with each unchanged fetch; a
                                        change goes back to 1 d

   - The SimHash is 64-bit over the text's words (Manku et al. 2007). A
     classification is a function of the main text and the pipeline
     version, so it is not paid for twice.
   - 14 days stays under the serving key's 30-day expiry.
   - Hubs (home pages, live blogs, section fronts, anything that moved on
     each of its last 3 fetches) change on every fetch: they are not chased.
     The bidder backs off to their section or site; they are fetched daily
     to keep counting in those. *)

type state = {
  url : string;
  etag : string;
  last_modified : string;
  simhash : int64;
  version : string; (* the pipeline version that classified it *)
  published : float; (* publication time, else first fetch, Unix seconds *)
  unchanged : int; (* unchanged fetches in a row *)
  moved : int; (* changed fetches in a row *)
  hub : bool;
}

let fnv1a s =
  String.fold_left (fun h c -> Int64.mul (Int64.logxor h (Int64.of_int (Char.code c))) 0x100000001b3L) 0xcbf29ce484222325L s

(* Over the text's words, as Text.tokens sees them (case and accents ignored),
   each hashed with 64-bit FNV-1a. sdks/prebid computes the same in the
   browser (fixtures from src/sdkfixtures). *)
let simhash text =
  let v = Array.make 64 0 in
  Array.iter
    (fun w ->
      let h = fnv1a w in
      for i = 0 to 63 do
        v.(i) <- (if Int64.logand (Int64.shift_right_logical h i) 1L = 1L then v.(i) + 1 else v.(i) - 1)
      done)
    (Text.tokens text);
  let r = ref 0L in
  Array.iteri (fun i x -> if x > 0 then r := Int64.logor !r (Int64.shift_left 1L i)) v;
  !r

let distance a b =
  let rec count x n = if x = 0L then n else count (Int64.logand x (Int64.pred x)) (n + 1) in
  count (Int64.logxor a b) 0

let moved a b = distance a b > 3

(* ISO 8601 as publishers write it: RFC 3339, a bare date, or an offset
   without its colon (+0100). *)
(* time_of "2026-11-04T10:00:00+0100" = time_of "2026-11-04T09:00:00Z" *)
let time_of s =
  let s = String.trim s in
  let n = String.length s in
  let candidates =
    [ s; s ^ "T00:00:00Z"; s ^ "Z" ]
    @ if n > 5 && (s.[n - 5] = '+' || s.[n - 5] = '-') then [ String.sub s 0 (n - 2) ^ ":" ^ String.sub s (n - 2) 2 ] else []
  in
  List.find_map (fun c -> match Ptime.of_rfc3339 c with Ok (t, _, _) -> Some (Ptime.to_float_s t) | Error _ -> None) candidates

let path_segments url =
  match Url_key.normalize url with
  | Error _ -> 0
  | Ok n -> List.length (List.filter (( <> ) "") (List.tl (String.split_on_char '/' (List.hd (String.split_on_char '?' n)))))

(* Live, moved on each of its last 3 fetches, a site's top page, or one
   path segment without a publication date: example.com/ and an undated
   example.com/football are hubs, example.com/football/derby-report is not. *)
let is_hub ~url ~live ~dated ~moved =
  live || moved >= 3 || match path_segments url with 0 -> true | 1 -> not dated | _ -> false

let hour = 3600.
let day = 86400.

let interval ~now s =
  if s.hub then day
  else if now -. s.published < 48. *. hour then 2. *. hour
  else Float.min (14. *. day) (day *. (2. ** float s.unchanged))

let to_json s =
  `Assoc
    [ ("url", `String s.url); ("etag", `String s.etag); ("last_modified", `String s.last_modified);
      ("simhash", `String (Printf.sprintf "%016Lx" s.simhash)); ("version", `String s.version);
      ("published", `Float s.published); ("unchanged", `Int s.unchanged); ("moved", `Int s.moved); ("hub", `Bool s.hub) ]

let of_json j =
  let module J = Yojson.Safe.Util in
  let str k = Option.value (J.to_string_option (J.member k j)) ~default:"" in
  let int k = Option.value (J.to_int_option (J.member k j)) ~default:0 in
  { url = str "url"; etag = str "etag"; last_modified = str "last_modified";
    simhash = Option.value (Int64.of_string_opt ("0x" ^ str "simhash")) ~default:0L; version = str "version";
    published = Option.value (J.to_number_option (J.member "published" j)) ~default:0.; unchanged = int "unchanged";
    moved = int "moved"; hub = Option.value (J.to_bool_option (J.member "hub" j)) ~default:false }
