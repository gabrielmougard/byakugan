(* Raw pages for replay, as WARC (Contextual.Warc). Each crawler replica
   appends to its own files in [dir], "<replica>-<seq>.warc.gz", rolled at
   [roll] bytes; the oldest are deleted once the replica's files pass [cap].
   A page's latest record is indexed in Valkey (Lab):

     warc               hash  key -> {"replica","file","offset","length","at"}
     warcfile:<file>    set   keys indexed in that file, to unindex it on deletion

   A file is gzip members end to end, one WARC response record each, so
   (offset, length) reads one record without inflating the others:

     <replica>-000042.warc.gz
     ┌───────────────────┬───────────────────┬─────
     │ member: response  │ member: response  │ ...
     └───────────────────┴───────────────────┴─────
     offset 0            offset = bytes of the members before

   Whoever holds the file serves the record; the online server finds the
   replica through the index:

     crawl, page reclassified   append ─> HSET warc, SADD warcfile ─> enforce_cap
     online GET /replay?url=    HGET warc key ─> replica ─> its GET /record?url=
     crawler GET /record?url=   HGET warc key ─> read at offset, length ─> Warc.read
     crawler POST /replay       latest: this replica's files, last record per URL *)

open Lwt.Syntax

type t = {
  dir : string;
  replica : string; (* file-name safe *)
  roll : int;
  cap : int;
  mutable seq : int;
  mutable oc : out_channel option;
  mutable size : int;
}

let safe s = String.map (fun c -> match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> c | _ -> '_') s

let ours t f = String.starts_with ~prefix:(t.replica ^ "-") f && Filename.check_suffix f ".warc.gz"

let files t =
  if Sys.file_exists t.dir then List.sort compare (List.filter (ours t) (Array.to_list (Sys.readdir t.dir))) else []

let file_size t f = (Unix.stat (Filename.concat t.dir f)).st_size

(* A restart opens a new file after the last one: a record half-written by a
   killed process stays at the end of the old file, never in the middle. *)
let create ?(roll = 256 lsl 20) ?(cap = 8 lsl 30) ~dir ~replica () =
  if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
  let t = { dir; replica = safe replica; roll; cap; seq = 0; oc = None; size = 0 } in
  let last =
    List.fold_left
      (fun m f ->
        let n = String.length t.replica + 1 in
        match int_of_string_opt (String.sub f n (String.length f - n - String.length ".warc.gz")) with
        | Some s -> max m s
        | None -> m)
      0 (files t)
  in
  t.seq <- last;
  t

let name t seq = Printf.sprintf "%s-%06d.warc.gz" t.replica seq

let current t =
  match t.oc with
  | Some oc when t.size < t.roll -> oc
  | previous ->
      Option.iter close_out previous;
      t.seq <- t.seq + 1;
      let oc = open_out_gen [ Open_wronly; Open_creat; Open_append; Open_binary ] 0o644 (Filename.concat t.dir (name t t.seq)) in
      t.oc <- Some oc;
      t.size <- 0;
      oc

(* Oldest files first, never the one being written, until under the cap;
   their keys leave the index unless a newer record replaced them. *)
let enforce_cap t kv =
  let open_file = name t t.seq in
  let rec go = function
    | f :: rest when f <> open_file && List.fold_left (fun n f -> n + file_size t f) 0 (files t) > t.cap ->
        let* keys = Valkey.strings kv [ "SMEMBERS"; Lab.k ("warcfile:" ^ f) ] in
        let* () =
          Lwt_list.iter_s
            (fun key ->
              let* entry = Lab.warc_entry kv key in
              match entry with
              | Some (_, file, _, _) when file = f -> Valkey.run kv [ "HDEL"; Lab.k "warc"; key ]
              | _ -> Lwt.return_unit)
            (List.filter_map Fun.id keys)
        in
        let* () = Valkey.run kv [ "DEL"; Lab.k ("warcfile:" ^ f) ] in
        Sys.remove (Filename.concat t.dir f);
        go rest
    | _ -> Lwt.return_unit
  in
  go (files t)

(* Appends one record and indexes it. The write and the flush do not yield,
   so records from concurrent fetches never interleave. *)
let append t kv ~key ~url ~fetched_at (r : Web.response) =
  let member =
    Contextual.Warc.response ~uri:url ~date:(Contextual.Warc.iso_date fetched_at)
      ~http:(Contextual.Warc.http ~status:r.status ~headers:r.headers r.body)
  in
  let oc = current t in
  let offset = t.size and file = name t t.seq in
  output_string oc member;
  flush oc;
  t.size <- t.size + String.length member;
  let entry =
    `Assoc
      [ ("replica", `String t.replica); ("file", `String file); ("offset", `Int offset);
        ("length", `Int (String.length member)); ("at", `Float fetched_at) ]
  in
  let* () = Valkey.run kv [ "HSET"; Lab.k "warc"; key; Yojson.Safe.to_string entry ] in
  let* () = Valkey.run kv [ "SADD"; Lab.k ("warcfile:" ^ file); key ] in
  enforce_cap t kv

(* A record from a file of this directory: [file] is cut to its base name,
   so an index entry cannot point outside it. *)
let read t ~file ~offset ~length =
  let path = Filename.concat t.dir (Filename.basename file) in
  if not (Sys.file_exists path) then None
  else
    In_channel.with_open_bin path (fun ic ->
        In_channel.seek ic (Int64.of_int offset);
        match In_channel.really_input_string ic length with
        | Some member -> Contextual.Warc.read member
        | None -> None)

(* The latest record of each URL in this replica's files, oldest file first. *)
let latest t =
  let records = Hashtbl.create 1024 in
  List.iter
    (fun f ->
      Contextual.Warc.fold (Filename.concat t.dir f) (fun () (r : Contextual.Warc.record) -> Hashtbl.replace records r.uri r) ())
    (files t);
  Hashtbl.fold (fun _ r acc -> r :: acc) records []
