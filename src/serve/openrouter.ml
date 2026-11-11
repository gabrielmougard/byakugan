(* T4 through OpenRouter. Publisher text leaves the building here, so requests
   only go to providers that do not retain prompts (data_collection: deny),
   and OpenRouter reports the billed cost of every call. *)

open Lwt.Syntax

type model = { id : string; prompt_price : float; completion_price : float; reasoning : Yojson.Safe.t option }
type t = { key : string; model : model }
type answer = { content : string; cost : float; prompt_tokens : int; completion_tokens : int; seconds : float }

let api = "https://openrouter.ai/api/v1"

let unquote s =
  let n = String.length s in
  if n >= 2 && (s.[0] = '"' || s.[0] = '\'') && s.[n - 1] = s.[0] then String.sub s 1 (n - 2) else s

let key ~env_file =
  let from_file () =
    In_channel.with_open_text env_file In_channel.input_all
    |> String.split_on_char '\n'
    |> List.find_map (fun line ->
           match String.index_opt line '=' with
           | Some i when String.trim (String.sub line 0 i) = "OPENROUTER_API_KEY" ->
               Some (unquote (String.trim (String.sub line (i + 1) (String.length line - i - 1))))
           | _ -> None)
  in
  match Sys.getenv_opt "OPENROUTER_API_KEY" with
  | Some k when k <> "" -> k
  | _ -> (
      match if Sys.file_exists env_file then from_file () else None with
      | Some k -> k
      | None -> failwith ("OPENROUTER_API_KEY not in the environment nor in " ^ env_file))

(* Reasoning tokens are billed as output and add latency, and picking from
   12 candidates with a verbatim quote does not need them: switch reasoning
   off, or to the lowest effort where it is mandatory. *)
let cheapest_reasoning (r : Yojson.Safe.t) =
  match r with
  | `Assoc kv ->
      let efforts =
        match List.assoc_opt "supported_efforts" kv with
        | Some (`List l) -> List.filter_map (function `String s -> Some s | _ -> None) l
        | _ -> []
      in
      let mandatory = List.assoc_opt "mandatory" kv = Some (`Bool true) in
      if List.mem "none" efforts then Some (`Assoc [ ("effort", `String "none") ])
      else if not mandatory then Some (`Assoc [ ("enabled", `Bool false) ])
      else
        Option.map (fun e -> `Assoc [ ("effort", `String e) ]) (List.find_opt (fun e -> List.mem e efforts) [ "minimal"; "low" ])
  | _ -> None

module J = Yojson.Safe.Util

let price j k = try float_of_string (J.to_string (J.member k (J.member "pricing" j))) *. 1e6 with _ -> 0.

(* [cheap] switches reasoning down; references keep the provider default. *)
let find_model ?(cheap = true) id =
  let* r = Web.fetch ~max_bytes:30_000_000 (api ^ "/models") in
  match r with
  | Ok { status = 200; body; _ } -> (
      let models = J.to_list (J.member "data" (Yojson.Safe.from_string body)) in
      match List.find_opt (fun m -> J.to_string (J.member "id" m) = id) models with
      | Some m ->
          Lwt.return
            { id;
              prompt_price = price m "prompt";
              completion_price = price m "completion";
              reasoning = (if cheap then cheapest_reasoning (J.member "reasoning" m) else None) }
      | None -> Lwt.fail_with ("unknown OpenRouter model " ^ id))
  | _ -> Lwt.fail_with "cannot list OpenRouter models"

(* Expected $ per call for a prompt of [prompt_tokens] and an answer of
   [answer_tokens], from the catalogue price (USD per million tokens). *)
let expected_cost m ~prompt_tokens ~answer_tokens =
  ((m.prompt_price *. float prompt_tokens) +. (m.completion_price *. float answer_tokens)) /. 1e6

let request ?(max_tokens = 2000) m prompt =
  `Assoc
    ([ ("model", `String m.id);
       ("messages", `List [ `Assoc [ ("role", `String "user"); ("content", `String prompt) ] ]);
       ("temperature", `Float 0.);
       ("max_tokens", `Int max_tokens);
       ("response_format", `Assoc [ ("type", `String "json_object") ]);
       ("provider", `Assoc [ ("data_collection", `String "deny") ]);
       ("usage", `Assoc [ ("include", `Bool true) ]) ]
    @ match m.reasoning with Some r -> [ ("reasoning", r) ] | None -> [])

let parse_reply body =
  let j = Yojson.Safe.from_string body in
  match J.member "error" j with
  | `Null ->
      let usage = J.member "usage" j in
      let int k = Option.value (J.to_int_option (J.member k usage)) ~default:0 in
      let content =
        match J.member "choices" j with
        | `List (c :: _) -> Option.value (J.to_string_option (J.member "content" (J.member "message" c))) ~default:""
        | _ -> ""
      in
      Ok (content, Option.value (J.to_number_option (J.member "cost" usage)) ~default:0., int "prompt_tokens", int "completion_tokens")
  | e -> Error (Option.value (J.to_string_option (J.member "message" e)) ~default:(Yojson.Safe.to_string e))

let complete ?max_tokens t prompt =
  let started = Unix.gettimeofday () in
  let+ r =
    Web.fetch ~timeout:120
      ~headers:[ "Authorization: Bearer " ^ t.key; "Content-Type: application/json"; "X-Title: contextual-lab" ]
      ~body:(Yojson.Safe.to_string (request ?max_tokens t.model prompt))
      (api ^ "/chat/completions")
  in
  let seconds = Unix.gettimeofday () -. started in
  match r with
  | Error e -> Error e
  | Ok { body; status; _ } -> (
      match parse_reply body with
      | Ok (content, cost, prompt_tokens, completion_tokens) ->
          Ok { content; cost; prompt_tokens; completion_tokens; seconds }
      | Error e -> Error (Printf.sprintf "HTTP %d: %s" status e)
      | exception Yojson.Json_error _ -> Error (Printf.sprintf "HTTP %d: not JSON" status))
