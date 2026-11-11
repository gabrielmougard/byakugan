(* Shared by both servers. Lwt owns the main domain (sockets, timers, curl);
   CPU work goes to a Domainslib pool through [detach] and comes
   back as a promise, so the event loop never stalls on classification. *)

open Lwt.Syntax
module Server = Cohttp_lwt_unix.Server

let headers content_type =
  Cohttp.Header.of_list [ ("content-type", content_type); ("access-control-allow-origin", "*") ]

let json ?(status = `OK) j =
  Server.respond_string ~status ~headers:(headers "application/json") ~body:(Yojson.Safe.to_string j) ()

let error status msg = json ~status (`Assoc [ ("error", `String msg) ])
let param req k = Uri.get_query_param (Cohttp.Request.uri req) k
let path req = Uri.path (Cohttp.Request.uri req)

let body_json body =
  let* s = Cohttp_lwt.Body.to_string body in
  Lwt.return (if s = "" then `Assoc [] else Yojson.Safe.from_string s)

let serve ~port callback =
  let callback _conn req body =
    Lwt.catch
      (fun () -> callback req body)
      (fun exn -> error `Bad_request (Printexc.to_string exn))
  in
  Printf.printf "listening on http://localhost:%d\n%!" port;
  Server.create ~mode:(`TCP (`Port port)) (Server.make ~callback ())

type pool = Domainslib.Task.pool

let setup_pool () = Domainslib.Task.setup_pool ~num_domains:(max 2 (Domain.recommended_domain_count () - 1)) ()

(* Lwt_domain.detach without its abstract pool type: jobs need the pool itself
   for nested parallel_for. The worker hands its result back through Lwt's
   notification pipe, the one thread-safe way into the event loop.

     main domain (Lwt)                         a pool domain (Domainslib)
     detach pool f x ──── Task.async ────────> Atomic.set result (f x)
       └ returns waiter, pending               send_notification note
     event loop reads the pipe <──── pipe ─────┘
       └ wakeup_result wakener (Atomic.get result): waiter resolves *)
let detach pool f x =
  let result = Atomic.make (Error (Failure "Web.detach")) in
  let waiter, wakener = Lwt.wait () in
  let note = Lwt_unix.make_notification ~once:true (fun () -> Lwt.wakeup_result wakener (Atomic.get result)) in
  ignore
    (Domainslib.Task.async pool (fun () ->
         Atomic.set result (try Ok (f x) with e -> Error e);
         Lwt_unix.send_notification note));
  waiter

(* Only valid inside a detached job: parallel_for needs a pool worker. *)
let parallel pool =
  { Contextual.Engine.map =
      (fun f a ->
        let n = Array.length a in
        if n = 0 then [||]
        else
          let out = Array.make n (f a.(0)) in
          Domainslib.Task.parallel_for pool ~start:1 ~finish:(n - 1) ~body:(fun i -> out.(i) <- f a.(i));
          out) }

let user_agent = "ContextBot/0.1 (contextual research prototype)"

(* [headers]: the final response's, names lower-cased. *)
type response = { status : int; content_type : string; body : string; headers : (string * string) list }

(* GET, or POST when [body] is given. *)
let fetch ?(max_bytes = 5_000_000) ?(timeout = 20) ?(headers = []) ?body url =
  let h = Curl.init () in
  let buf = Buffer.create 65536 and received = ref [] in
  Curl.set_url h url;
  Curl.set_followlocation h true;
  Curl.set_maxredirs h 5;
  Curl.set_connecttimeout h 10;
  Curl.set_timeout h timeout;
  Curl.set_useragent h user_agent;
  Curl.set_encoding h Curl.CURL_ENCODING_ANY;
  if headers <> [] then Curl.set_httpheader h headers;
  Curl.set_headerfunction h (fun line ->
      (if String.starts_with ~prefix:"HTTP/" line then received := []
       else
         match String.index_opt line ':' with
         | Some i ->
             let name = String.lowercase_ascii (String.trim (String.sub line 0 i)) in
             received := (name, String.trim (String.sub line (i + 1) (String.length line - i - 1))) :: !received
         | None -> ());
      String.length line);
  Option.iter
    (fun b ->
      Curl.set_post h true;
      Curl.set_postfields h b;
      Curl.set_postfieldsize h (String.length b))
    body;
  Curl.set_writefunction h (fun s ->
      if Buffer.length buf + String.length s > max_bytes then 0
      else (
        Buffer.add_string buf s;
        String.length s));
  let* code = Curl_lwt.perform h in
  let result =
    match code with
    | Curl.CURLE_OK ->
        Ok
          { status = Curl.get_responsecode h;
            content_type = (try Curl.get_contenttype h with _ -> "");
            body = Buffer.contents buf;
            headers = List.rev !received }
    | c -> Error (Curl.strerror c)
  in
  Curl.cleanup h;
  Lwt.return result

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* robots.txt for the one-off tools (metacov, image_bench), fetched once per
   origin per process; the crawler shares its copies through Valkey instead.
   RFC 9309: a missing file (4xx) allows everything, an unreachable one (5xx,
   network error) disallows everything. *)
let robots_cache = Hashtbl.create 64

let robots url =
  let u = Uri.of_string url in
  let origin = Printf.sprintf "%s://%s" (Option.value (Uri.scheme u) ~default:"https") (Option.value (Uri.host u) ~default:"") in
  match Hashtbl.find_opt robots_cache origin with
  | Some r -> Lwt.return r
  | None ->
      let+ r = fetch (origin ^ "/robots.txt") in
      let body =
        match r with
        | Ok { status = 200; body; _ } -> body
        | Ok { status; _ } when status < 500 -> ""
        | _ -> "User-agent: *\nDisallow: /"
      in
      let parsed = Contextual.Robots.parse ~agent:"ContextBot" body in
      Hashtbl.replace robots_cache origin parsed;
      parsed

let allowed url =
  let+ r = robots url in
  Contextual.Robots.allowed r url
