type attrs = (string * string) list

type token =
  | Open of string * attrs
  | Close of string
  | Text of string
  | Script of attrs * string

let entity = Re.Perl.compile_pat {|&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});|}

let utf8 code =
  if not (Uchar.is_valid code) then ""
  else
    let b = Buffer.create 4 in
    Buffer.add_utf_8_uchar b (Uchar.of_int code);
    Buffer.contents b

(* Pages that are not UTF-8 are, for the languages served, Windows-1252
   (a superset of ISO-8859-1): each byte is one code point, 0x80-0x9f the
   typographic ones. to_utf8 "c'\xe8" = "c'è"; valid UTF-8 is returned as is. *)
let cp1252 =
  [| 0x20ac; 0x81; 0x201a; 0x192; 0x201e; 0x2026; 0x2020; 0x2021; 0x2c6; 0x2030; 0x160; 0x2039; 0x152; 0x8d; 0x17d; 0x8f;
     0x90; 0x2018; 0x2019; 0x201c; 0x201d; 0x2022; 0x2013; 0x2014; 0x2dc; 0x2122; 0x161; 0x203a; 0x153; 0x9d; 0x17e; 0x178 |]

let to_utf8 s =
  if String.is_valid_utf_8 s then s
  else begin
    let b = Buffer.create (String.length s + (String.length s / 8)) in
    String.iter
      (fun ch ->
        let c = Char.code ch in
        Buffer.add_utf_8_uchar b (Uchar.of_int (if c >= 0x80 && c < 0xa0 then cp1252.(c - 0x80) else c)))
      s;
    Buffer.contents b
  end

let decode_entity e =
  match e with
  | "amp" -> "&"
  | "lt" -> "<"
  | "gt" -> ">"
  | "quot" -> "\""
  | "apos" -> "'"
  | "nbsp" -> " "
  | _ when e.[0] = '#' && (e.[1] = 'x' || e.[1] = 'X') ->
      utf8 (int_of_string ("0x" ^ String.sub e 2 (String.length e - 2)))
  | _ when e.[0] = '#' -> utf8 (int_of_string (String.sub e 1 (String.length e - 1)))
  | _ -> "&" ^ e ^ ";"

(* The five XML entities, &nbsp; and numeric references; other named ones
   stay as they are: decode "A &amp; B &#233; &eacute;" = "A & B é &eacute;". *)
let decode s = Re.replace entity ~f:(fun g -> decode_entity (Re.Group.get g 1)) s

let attr =
  Re.Perl.compile_pat {|([a-zA-Z_:][-a-zA-Z0-9_:.]*)[ \t\n\r]*=[ \t\n\r]*("[^"]*"|'[^']*'|[^ \t\n\r"'>]+)|}

let unquote v =
  let n = String.length v in
  if n >= 2 && (v.[0] = '"' || v.[0] = '\'') then String.sub v 1 (n - 2) else v

let parse_attrs s =
  List.map
    (fun g -> (String.lowercase_ascii (Re.Group.get g 1), decode (unquote (Re.Group.get g 2))))
    (Re.all attr s)

let is_name_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | ':' | '-' | '_' -> true
  | _ -> false

let split_name s =
  let k = ref 0 in
  while !k < String.length s && is_name_char s.[!k] do
    incr k
  done;
  (String.lowercase_ascii (String.sub s 0 !k), String.sub s !k (String.length s - !k))

(* Tolerant tag scanner for XML (sitemaps, RSL documents); HTML pages go
   through [parse_html]. Never raises on malformed input. *)
let tokenize html =
  let lower = String.lowercase_ascii html and len = String.length html in
  let index_or_end from sub = Option.value (Text.find lower ~from sub) ~default:len in
  let rec go i acc =
    if i >= len then List.rev acc
    else if html.[i] <> '<' then
      let j = Option.value (String.index_from_opt html i '<') ~default:len in
      go j (Text (decode (String.sub html i (j - i))) :: acc)
    else if Text.starts_at lower i "<!--" then go (index_or_end i "-->" + 3) acc
    else if Text.starts_at lower i "<![cdata[" then
      let j = index_or_end (i + 9) "]]>" in
      go (j + 3) (Text (String.sub html (i + 9) (j - i - 9)) :: acc)
    else
      let j = index_or_end i ">" in
      let inner = String.sub html (i + 1) (max 0 (j - i - 1)) in
      if inner <> "" && inner.[0] = '/' then
        go (j + 1) (Close (fst (split_name (String.sub inner 1 (String.length inner - 1)))) :: acc)
      else
        let name, rest = split_name inner in
        if name = "" then go (j + 1) acc
        else if name = "script" || name = "style" then
          let k = index_or_end (j + 1) ("</" ^ name) in
          let body = String.sub html (min len (j + 1)) (max 0 (k - j - 1)) in
          let acc = if name = "script" then Script (parse_attrs rest, body) :: acc else acc in
          go (index_or_end k ">" + 1) acc
        else
          let acc = Open (name, parse_attrs rest) :: acc in
          let self_closing = String.ends_with ~suffix:"/" (String.trim rest) in
          go (j + 1) (if self_closing then Close name :: acc else acc)
  in
  go 0 []

external flatten : string -> string = "ctx_lexbor_flatten"

(* HTML pages, parsed as a browser would (lexbor, src/stubs/lexbor_stubs.c):
   the same tokens as [tokenize], from the HTML5 tree, so implied end tags
   close and every character reference is decoded. Attributes are only those
   the extractor reads; style elements are dropped.
   [flatten] returns the tree walk as events, each a kind byte then its
   fields; a string is a u32 little-endian length then its bytes, attributes
   a u32 count then that many name and value strings:
     'o' name attrs    open
     'c'               close the innermost open element
     't' text          text
     's' attrs body    script *)
let parse_html html =
  let b = flatten html in
  let n = String.length b and pos = ref 0 in
  let u32 () =
    let v = Int32.to_int (String.get_int32_le b !pos) land 0xffffffff in
    pos := !pos + 4;
    v
  in
  let str () =
    let len = u32 () in
    let s = String.sub b !pos len in
    pos := !pos + len;
    s
  in
  let attrs () =
    let rec go k acc = if k = 0 then List.rev acc else let name = str () in go (k - 1) ((name, str ()) :: acc) in
    go (u32 ()) []
  in
  let rec go open_tags acc =
    if !pos >= n then List.rev acc
    else
      let kind = b.[!pos] in
      incr pos;
      match (kind, open_tags) with
      | 'o', _ ->
          let name = str () in
          let a = attrs () in
          go (name :: open_tags) (Open (name, a) :: acc)
      | 'c', name :: rest -> go rest (Close name :: acc)
      | 't', _ -> go open_tags (Text (str ()) :: acc)
      | 's', _ ->
          let a = attrs () in
          go open_tags (Script (a, str ()) :: acc)
      | _ -> invalid_arg "Html.parse_html: corrupt event buffer"
  in
  go [] []
