(* An archived page made viewable in the lab, as the reader saw it, minus
   anything that runs: served with scripts, objects and frames forbidden
   (headers), its relative URLs resolved against the original page (<base>),
   no meta refresh, and the images that lazy-loading scripts would have
   swapped in put in place (data-src, data-srcset). *)

let headers =
  [ ("content-security-policy", "script-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'");
    ("referrer-policy", "no-referrer"); ("x-frame-options", "SAMEORIGIN"); ("cache-control", "private, max-age=300") ]

let ci = Re.Perl.compile_pat ~opts:[ `Caseless ]
let head = ci {|<head\b[^>]*>|}
let refresh = ci {|<meta\b[^>]*http-equiv\s*=\s*["']?refresh[^>]*>|}
let img = ci {|<img\b[^>]*>|}
let attr name = ci (Printf.sprintf {|\s%s\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)|} name)

let escape_attr s = String.concat "&quot;" (String.split_on_char '"' s)

(* <img data-src="a.jpg" src="placeholder.gif"> -> <img src="a.jpg" ...>. *)
let unlazy tag =
  let value re = Option.map (fun g -> Re.Group.get g 1) (Re.exec_opt re tag) in
  let set name lazy_names tag =
    match List.find_map (fun n -> value (attr n)) lazy_names with
    | None -> tag
    | Some v ->
        let without = Re.replace (attr name) ~f:(fun _ -> "") tag in
        String.sub without 0 4 ^ Printf.sprintf " %s=%s" name v ^ String.sub without 4 (String.length without - 4)
  in
  tag
  |> set "src" [ "data-src"; "data-lazy-src"; "data-original"; "data-lazy" ]
  |> set "srcset" [ "data-srcset"; "data-lazy-srcset" ]

let prepare ~url html =
  let html = Re.replace refresh ~f:(fun _ -> "") html in
  let html = Re.replace img ~f:(fun g -> unlazy (Re.Group.get g 0)) html in
  let base = Printf.sprintf {|<base href="%s">|} (escape_attr url) in
  match Re.exec_opt head html with
  | Some g ->
      let stop = Re.Group.stop g 0 in
      String.sub html 0 stop ^ base ^ String.sub html stop (String.length html - stop)
  | None -> base ^ html
