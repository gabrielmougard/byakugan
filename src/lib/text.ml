(* Words as BERT's normaliser sees them (src/stubs/m2v_text.c): Unicode
   lowercase, accents stripped, Unicode spaces and punctuation as separators.
   "l’ÉCONOMIE" gives "l economie" and "città" gives "citta", so Italian and
   French terms match their pages and accentless URL slugs. Joined by spaces. *)
external words : string -> string = "ctx_m2v_words"

let tokens s = match words s with "" -> [||] | w -> Array.of_list (String.split_on_char ' ' w)

(* " w1 w2 ... ": substring search on this form is whole-word and ignores case,
   accents and punctuation. normalize "L’Inter!" = " l inter ". *)
let normalize s = " " ^ words s ^ " "

let find s ~from sub =
  let n = String.length sub and m = String.length s in
  let rec matches i j = j = n || (s.[i + j] = sub.[j] && matches i (j + 1)) in
  let rec go i = if i + n > m then None else if matches i 0 then Some i else go (i + 1) in
  go from

let contains s sub = Option.is_some (find s ~from:0 sub)

let starts_at s i prefix =
  let n = String.length prefix in
  i + n <= String.length s && String.sub s i n = prefix

let squash s =
  String.map (function '\n' | '\t' | '\r' -> ' ' | c -> c) s
  |> String.split_on_char ' '
  |> List.filter (( <> ) "")
  |> String.concat " "

(* shortcut: splits on ". " / "! " / "? " only ("Mr. Smith" breaks); a
   sentence-boundary model is not worth it for evidence quotes.
   sentences "Mr. Smith left. He won!" = [ "Mr."; "Smith left."; "He won!" ] *)
let sentences s =
  let out = ref [] and start = ref 0 in
  String.iteri
    (fun i c ->
      if (c = '.' || c = '!' || c = '?') && (i + 1 = String.length s || s.[i + 1] = ' ')
      then (
        out := String.trim (String.sub s !start (i + 1 - !start)) :: !out;
        start := i + 1))
    s;
  let rest = String.trim (String.sub s !start (String.length s - !start)) in
  List.filter (( <> ) "") (List.rev (rest :: !out))

(* An evidence quote, at most 120 bytes: past that, the first 117 cut back
   to a UTF-8 character boundary, then "...". *)
let clip s =
  if String.length s <= 120 then s
  else
    let i = ref 117 in
    while !i > 0 && Char.code s.[!i] land 0xC0 = 0x80 do
      decr i
    done;
    String.sub s 0 !i ^ "..."
