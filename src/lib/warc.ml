(* Raw pages kept as WARC/1.1 (ISO 28500) through FastWARC (src/stubs/
   warc_ffi, vendored Rust): one `response` record per fetch, one gzip member
   per record, so any record reads back alone from its offset and length;
   files stay readable by every WARC tool (warcio, pywb, FastWARC). *)

type record = {
  uri : string;
  date : string;
  status : int;
  content_type : string;
  headers : string; (* HTTP headers, "name: value" per line *)
  body : string;
}

(* The HTTP headers as (lower-cased name, value), as Web.response has them. *)
let header_list r =
  List.filter_map
    (fun l -> match String.index_opt l ':' with
      | Some i -> Some (String.lowercase_ascii (String.trim (String.sub l 0 i)), String.trim (String.sub l (i + 1) (String.length l - i - 1)))
      | None -> None)
    (String.split_on_char '\n' r.headers)

(* One record: the target URI, the fetch time (ISO 8601, UTC) and the HTTP
   exchange as fetched (status line, headers, blank line, body). *)
external response : uri:string -> date:string -> http:string -> string = "ctx_warc_response_ml"

(* The record in one gzip member, as [response] wrote it. *)
external read : string -> record option = "ctx_warc_read_ml"

type reader

external open_in : string -> reader = "ctx_warc_open_ml"
external next : reader -> record option = "ctx_warc_next_ml"
external close_in : reader -> unit = "ctx_warc_close_ml"

(* Every response record of a file, in order. *)
let fold path f init =
  let r = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in r)
    (fun () ->
      let rec go acc = match next r with Some x -> go (f acc x) | None -> acc in
      go init)

(* The HTTP exchange as the crawler got it. The body is already decoded
   (curl), so Content-Encoding and Transfer-Encoding go, and Content-Length
   is the decoded length: replaying the record must not decode it twice. *)
let http ~status ~headers body =
  let keep (k, _) = not (List.mem k [ "content-encoding"; "transfer-encoding"; "content-length" ]) in
  let lines = List.map (fun (k, v) -> k ^ ": " ^ v) (List.filter keep headers) in
  String.concat "\r\n"
    ((Printf.sprintf "HTTP/1.1 %d %s" status (if status = 200 then "OK" else "-"))
     :: lines @ [ Printf.sprintf "content-length: %d" (String.length body); ""; body ])

(* iso_date 1794400000. = "2026-11-11T12:26:40Z" *)
let iso_date t =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min
    tm.tm_sec
