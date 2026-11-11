(* A small Valkey client: RESP2 over one Lwt connection, commands serialised
   by a mutex (no pipelining; the lab's traffic does not need it).

   Endpoints:
     valkey://host:port                       one server
     sentinel://host:port[,host:port]/name    ask Sentinel for the primary of
                                              [name]; when the connection
                                              breaks or the server answers
                                              READONLY (it was demoted),
                                              ask again and retry.

   From the environment, for every connection, Sentinel's included:
     VALKEY_PASSWORD   sent with AUTH
     VALKEY_CA_CERT    PEM file: connect over TLS, verified against it *)

open Lwt.Syntax

type reply = Nil | Int of int | Str of string | Err of string | Arr of reply list

exception Error of string

type endpoint = Direct of string * int | Sentinel of (string * int) list * string

type t = {
  endpoint : endpoint;
  password : string option;
  tls : Tls.Config.client option;
  lock : Lwt_mutex.t;
  mutable conn : (Lwt_io.input_channel * Lwt_io.output_channel) option;
}

let host_port s =
  match String.rindex_opt s ':' with
  | Some i -> (String.sub s 0 i, int_of_string (String.sub s (i + 1) (String.length s - i - 1)))
  | None -> invalid_arg ("Valkey: expected host:port in " ^ s)

let endpoint_of_uri uri =
  let after prefix = String.sub uri (String.length prefix) (String.length uri - String.length prefix) in
  if String.starts_with ~prefix:"valkey://" uri then
    let h, p = host_port (after "valkey://") in
    Direct (h, p)
  else if String.starts_with ~prefix:"sentinel://" uri then
    match String.split_on_char '/' (after "sentinel://") with
    | [ hosts; name ] when name <> "" -> Sentinel (List.map host_port (String.split_on_char ',' hosts), name)
    | _ -> invalid_arg ("Valkey: expected sentinel://host:port/name, got " ^ uri)
  else invalid_arg ("Valkey: unknown endpoint " ^ uri)

let encode args =
  let b = Buffer.create 64 in
  Printf.bprintf b "*%d\r\n" (List.length args);
  List.iter (fun a -> Printf.bprintf b "$%d\r\n%s\r\n" (String.length a) a) args;
  Buffer.contents b

let rec read ic =
  let* line = Lwt_io.read_line ic in
  let body = String.sub line 1 (String.length line - 1) in
  match line.[0] with
  | '+' -> Lwt.return (Str body)
  | '-' -> Lwt.return (Err body)
  | ':' -> Lwt.return (Int (int_of_string body))
  | '$' ->
      let n = int_of_string body in
      if n < 0 then Lwt.return Nil
      else
        let buf = Bytes.create n in
        let* () = Lwt_io.read_into_exactly ic buf 0 n in
        let+ _crlf = Lwt_io.read_line ic in
        Str (Bytes.to_string buf)
  | '*' ->
      let n = int_of_string body in
      if n < 0 then Lwt.return Nil
      else
        let rec items k acc = if k = 0 then Lwt.return (Arr (List.rev acc)) else let* r = read ic in items (k - 1) (r :: acc) in
        items n []
  | c -> Lwt.fail (Error (Printf.sprintf "unexpected RESP type %C" c))

let request (ic, oc) args =
  let* () = Lwt_io.write oc (encode args) in
  let* () = Lwt_io.flush oc in
  read ic

let close (ic, oc) = Lwt.catch (fun () -> let* () = Lwt_io.close oc in Lwt_io.close ic) (fun _ -> Lwt.return_unit)

let channels t host fd =
  match t.tls with
  | None -> Lwt.return (Lwt_io.of_fd ~mode:Lwt_io.Input fd, Lwt_io.of_fd ~mode:Lwt_io.Output fd)
  | Some config ->
      let host = Result.to_option (Result.bind (Domain_name.of_string host) Domain_name.host) in
      let+ session = Tls_lwt.Unix.client_of_fd config ?host fd in
      Tls_lwt.of_t session

let authenticate t c =
  match t.password with
  | None -> Lwt.return c
  | Some password -> (
      let* r = request c [ "AUTH"; password ] in
      match r with
      | Str "OK" -> Lwt.return c
      | r ->
          let* () = close c in
          Lwt.fail (Error (match r with Err e -> e | _ -> "AUTH refused")))

let connect t (host, port) =
  Lwt_unix.with_timeout 5. (fun () ->
      let* addrs = Lwt_unix.getaddrinfo host (string_of_int port) [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ] in
      match addrs with
      | [] -> Lwt.fail (Error ("cannot resolve " ^ host))
      | a :: _ ->
          let fd = Lwt_unix.socket a.ai_family Unix.SOCK_STREAM 0 in
          Lwt_unix.setsockopt fd Unix.TCP_NODELAY true;
          let* c =
            Lwt.catch
              (fun () ->
                let* () = Lwt_unix.connect fd a.ai_addr in
                channels t host fd)
              (fun e -> let* () = Lwt_unix.close fd in Lwt.fail e)
          in
          authenticate t c)

(* The first Sentinel that knows the primary, which must also say "master"
   when asked its ROLE (Sentinel can lag a failover by a moment). *)
let primary t sentinels name =
  let ask s =
    Lwt.catch
      (fun () ->
        let* c = connect t s in
        let* r = request c [ "SENTINEL"; "get-master-addr-by-name"; name ] in
        let+ () = close c in
        match r with Arr [ Str h; Str p ] -> Some (h, int_of_string p) | _ -> None)
      (fun _ -> Lwt.return_none)
  in
  let rec first = function
    | [] -> Lwt.fail (Error ("no Sentinel knows the primary of " ^ name))
    | s :: rest -> ( let* a = ask s in match a with Some a -> Lwt.return a | None -> first rest)
  in
  let* addr = first sentinels in
  let* c = connect t addr in
  let* role = request c [ "ROLE" ] in
  match role with
  | Arr (Str "master" :: _) -> Lwt.return c
  | _ ->
      let* () = close c in
      Lwt.fail (Error (fst addr ^ " is not the primary yet"))

let open_connection t =
  match t.endpoint with Direct (h, p) -> connect t (h, p) | Sentinel (ss, name) -> primary t ss name

let tls_of_ca_file file =
  Mirage_crypto_rng_unix.use_default ();
  let cas =
    match X509.Certificate.decode_pem_multiple (In_channel.with_open_bin file In_channel.input_all) with
    | Ok cas -> cas
    | Error (`Msg m) -> invalid_arg (Printf.sprintf "Valkey: %s: %s" file m)
  in
  let authenticator = X509.Authenticator.chain_of_trust ~time:(fun () -> Some (Ptime_clock.now ())) cas in
  match Tls.Config.client ~authenticator () with Ok c -> c | Error (`Msg m) -> invalid_arg ("Valkey: " ^ m)

let create uri =
  { endpoint = endpoint_of_uri uri;
    password = Sys.getenv_opt "VALKEY_PASSWORD";
    tls = Option.map tls_of_ca_file (Sys.getenv_opt "VALKEY_CA_CERT");
    lock = Lwt_mutex.create ();
    conn = None }

let drop t =
  let c = t.conn in
  t.conn <- None;
  match c with Some c -> close c | None -> Lwt.return_unit

(* Retries ride out a failover: about 10 s with these settings. *)
let rec command ?(attempts = 20) t args =
  let once () =
    Lwt_mutex.with_lock t.lock (fun () ->
        let* c = match t.conn with Some c -> Lwt.return c | None -> open_connection t in
        t.conn <- Some c;
        Lwt.catch (fun () -> request c args) (fun e -> let* () = drop t in Lwt.fail e))
  in
  let retry e =
    if attempts <= 1 then Lwt.fail e
    else
      let* () = Lwt_unix.sleep 0.5 in
      command ~attempts:(attempts - 1) t args
  in
  Lwt.try_bind once
    (function
      | Err e when String.starts_with ~prefix:"READONLY" e || String.starts_with ~prefix:"LOADING" e ->
          let* () = Lwt_mutex.with_lock t.lock (fun () -> drop t) in
          retry (Error e)
      | Err e -> Lwt.fail (Error e)
      | r -> Lwt.return r)
    (function
      | (Unix.Unix_error _ | End_of_file | Lwt_unix.Timeout | Error _ | Tls_lwt.Tls_alert _ | Tls_lwt.Tls_failure _) as e ->
          retry e
      | e -> Lwt.fail e)

let unexpected r what =
  let rec show = function
    | Nil -> "nil" | Int i -> string_of_int i | Str s -> Printf.sprintf "%S" s | Err e -> "error " ^ e
    | Arr l -> "[" ^ String.concat "; " (List.map show l) ^ "]"
  in
  Lwt.fail (Error (Printf.sprintf "expected %s, got %s" what (show r)))

let run t args = let* r = command t args in match r with Err e -> Lwt.fail (Error e) | _ -> Lwt.return_unit
let int t args = let* r = command t args in match r with Int i -> Lwt.return i | r -> unexpected r "an integer"
let string_opt t args = let* r = command t args in match r with Str s -> Lwt.return_some s | Nil -> Lwt.return_none | r -> unexpected r "a string"

let strings t args =
  let* r = command t args in
  match r with
  | Arr l -> Lwt.return (List.map (function Str s -> Some s | _ -> None) l)
  | Nil -> Lwt.return []
  | r -> unexpected r "an array"
