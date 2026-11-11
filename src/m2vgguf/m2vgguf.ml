(* A Model2Vec model from Hugging Face (tokenizer.json, model.safetensors,
   config.json) as one GGUF file: the token table, quantized if asked, and
   the tokenizer, for src/stubs/m2v_model.c.

   Only the tokenizer pipelines the C runtime reproduces exactly are
   accepted; anything else stops here rather than tokenizing differently:
     - WordPiece: BertNormalizer (clean_text, handle_chinese_chars,
       strip_accents, lowercase all on) + BertPreTokenizer;
     - Unigram: Precompiled charsmap, Replace " {2,}", Replace of single ASCII
       characters by " c ", Replace "\s+", Strip, then Metaspace (U+2581,
       prepended always, no split), without byte fallback.

   m2vgguf.exe --tokenizer T.json --model M.safetensors --config C.json
              [--type q8_0|f16|f32] [--name NAME] -o OUT.gguf *)

type writer

external writer : unit -> writer = "ctx_gguf_new"
external set_str : writer -> string -> string -> unit = "ctx_gguf_str"
external set_u32 : writer -> string -> int -> unit = "ctx_gguf_u32"
external set_bool : writer -> string -> bool -> unit = "ctx_gguf_bool"
external set_strs : writer -> string -> string array -> unit = "ctx_gguf_strs"
external set_i32s : writer -> string -> int array -> unit = "ctx_gguf_i32s"
external set_f64s : writer -> string -> float array -> unit = "ctx_gguf_f64s"
external set_bytes : writer -> string -> string -> unit = "ctx_gguf_bytes"

external add_table :
  writer -> string -> (float, Bigarray.float32_elt, Bigarray.c_layout) Bigarray.Array2.t -> string -> unit
  = "ctx_gguf_table"

external write : writer -> string -> unit = "ctx_gguf_write"

module J = Yojson.Safe.Util

let fail fmt = Printf.ksprintf failwith fmt
let read_file path = In_channel.with_open_bin path In_channel.input_all

let base64 s =
  let value c =
    match c with
    | 'A' .. 'Z' -> Char.code c - 65
    | 'a' .. 'z' -> Char.code c - 71
    | '0' .. '9' -> Char.code c + 4
    | '+' -> 62
    | '/' -> 63
    | _ -> -1
  in
  let b = Buffer.create (String.length s * 3 / 4) and acc = ref 0 and bits = ref 0 in
  String.iter
    (fun c ->
      let v = value c in
      if v >= 0 then begin
        acc := (!acc lsl 6) lor v;
        bits := !bits + 6;
        if !bits >= 8 then begin
          bits := !bits - 8;
          Buffer.add_char b (Char.chr ((!acc lsr !bits) land 0xFF))
        end
      end)
    s;
  Buffer.contents b

(* safetensors: u64 header length, JSON header, raw little-endian tensors. *)
let load_table path =
  let ic = open_in_bin path in
  let header_len = Int64.to_int (String.get_int64_le (really_input_string ic 8) 0) in
  let header = really_input_string ic header_len in
  close_in ic;
  let e = J.member "embeddings" (Yojson.Safe.from_string header) in
  match (J.member "dtype" e, J.member "shape" e, J.member "data_offsets" e) with
  | `String "F32", `List [ `Int rows; `Int cols ], `List [ `Int start; _ ] ->
      let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      let pos = Int64.of_int (8 + header_len + start) in
      let t = Unix.map_file fd ~pos Bigarray.float32 Bigarray.c_layout false [| rows; cols |] in
      Unix.close fd;
      Bigarray.array2_of_genarray t
  | _ -> fail "%s: expected an F32 [vocab, dim] \"embeddings\" tensor" path

let added_tokens w tok =
  let added = J.to_list (J.member "added_tokens" tok) in
  List.iter
    (fun a ->
      List.iter
        (fun flag -> if J.member flag a = `Bool true then fail "added token with %s is not supported" flag)
        [ "normalized"; "single_word"; "lstrip"; "rstrip" ])
    added;
  set_strs w "m2v.added_tokens" (Array.of_list (List.map (fun a -> J.to_string (J.member "content" a)) added));
  set_i32s w "m2v.added_ids" (Array.of_list (List.map (fun a -> J.to_int (J.member "id" a)) added))

let wordpiece w tok model =
  let norm = J.member "normalizer" tok in
  let flag k = J.member k norm = `Bool true in
  let strip = match J.member "strip_accents" norm with `Null -> flag "lowercase" | `Bool b -> b | _ -> false in
  if not (J.member "type" norm = `String "BertNormalizer" && flag "clean_text" && flag "handle_chinese_chars" && strip
          && flag "lowercase" && J.member "type" (J.member "pre_tokenizer" tok) = `String "BertPreTokenizer")
  then fail "WordPiece: only BertNormalizer (all options on) + BertPreTokenizer is supported";
  let vocab = J.to_assoc (J.member "vocab" model) in
  let tokens = Array.make (List.length vocab) "" in
  List.iter (fun (piece, id) -> tokens.(J.to_int id) <- piece) vocab;
  let unk = J.to_string (J.member "unk_token" model) in
  set_str w "m2v.tokenizer" "wordpiece";
  set_strs w "m2v.tokens" tokens;
  set_u32 w "m2v.unk_id" (J.to_int (List.assoc unk vocab));
  set_str w "m2v.wordpiece.prefix" (J.to_string (J.member "continuing_subword_prefix" model));
  set_u32 w "m2v.wordpiece.max_chars" (J.to_int (J.member "max_input_chars_per_word" model))

(* The normalizer as a flat list, nested Sequences expanded. *)
let rec steps n = match J.member "type" n with `String "Sequence" -> List.concat_map steps (J.to_list (J.member "normalizers" n)) | _ -> [ n ]

let unigram w tok model =
  let replace pattern kind n =
    J.member "type" n = `String "Replace" && J.member kind (J.member "pattern" n) = `String pattern
  in
  let isolated n =
    match (J.member "type" n, J.member "String" (J.member "pattern" n), J.member "content" n) with
    | `String "Replace", `String c, `String r when String.length c = 1 && Char.code c.[0] < 128 && r = " " ^ c ^ " " -> Some c
    | _ -> None
  in
  let charsmap, isolate =
    match steps (J.member "normalizer" tok) with
    | pre :: spaces :: rest when J.member "type" pre = `String "Precompiled" && replace " {2,}" "Regex" spaces -> (
        match List.rev rest with
        | strip :: ws :: punct
          when J.member "type" strip = `String "Strip" && J.member "strip_left" strip = `Bool true
               && J.member "strip_right" strip = `Bool true && replace "\\s+" "Regex" ws
               && J.member "content" ws = `String " " && List.for_all (fun n -> isolated n <> None) punct ->
            ( base64 (J.to_string (J.member "precompiled_charsmap" pre)),
              String.concat "" (List.rev_map (fun n -> Option.get (isolated n)) punct) )
        | _ -> fail "Unigram: unsupported normalizer")
    | _ -> fail "Unigram: unsupported normalizer"
  in
  let pre = J.member "pre_tokenizer" tok in
  if not (J.member "type" pre = `String "Metaspace" && J.member "replacement" pre = `String "\xe2\x96\x81"
          && J.member "prepend_scheme" pre = `String "always" && J.member "split" pre = `Bool false)
  then fail "Unigram: only Metaspace (U+2581, prepend always, no split) is supported";
  if J.member "byte_fallback" model = `Bool true then fail "Unigram: byte fallback is not supported";
  let vocab = Array.of_list (J.to_list (J.member "vocab" model)) in
  let piece i = J.to_list vocab.(i) in
  set_str w "m2v.tokenizer" "unigram";
  set_strs w "m2v.tokens" (Array.init (Array.length vocab) (fun i -> J.to_string (List.nth (piece i) 0)));
  set_f64s w "m2v.unigram.scores" (Array.init (Array.length vocab) (fun i -> J.to_number (List.nth (piece i) 1)));
  set_u32 w "m2v.unk_id" (J.to_int (J.member "unk_id" model));
  set_bytes w "m2v.unigram.charsmap" charsmap;
  set_str w "m2v.unigram.isolate" isolate

let () =
  let tokenizer = ref "" and model = ref "" and config = ref "" and out = ref "" and kind = ref "q8_0" and name = ref "" in
  Arg.parse
    [ ("--tokenizer", Arg.Set_string tokenizer, "FILE tokenizer.json");
      ("--model", Arg.Set_string model, "FILE model.safetensors");
      ("--config", Arg.Set_string config, "FILE config.json");
      ("--type", Arg.Set_string kind, "TYPE table storage: q8_0 (default), f16 or f32");
      ("--name", Arg.Set_string name, "NAME model name stored in the file");
      ("-o", Arg.Set_string out, "FILE output .gguf") ]
    (fun _ -> ())
    "m2vgguf --tokenizer T.json --model M.safetensors --config C.json -o OUT.gguf";
  if !tokenizer = "" || !model = "" || !config = "" || !out = "" then fail "--tokenizer, --model, --config and -o are required";
  let tok = Yojson.Safe.from_string (read_file !tokenizer) in
  let cfg = Yojson.Safe.from_string (read_file !config) in
  let m = J.member "model" tok in
  let w = writer () in
  set_str w "general.architecture" "model2vec";
  set_str w "general.name" (if !name = "" then Filename.remove_extension (Filename.basename !model) else !name);
  set_bool w "m2v.normalize" (J.member "normalize" cfg = `Bool true);
  added_tokens w tok;
  (match J.member "type" m with
  | `String "WordPiece" -> wordpiece w tok m
  | `String "Unigram" -> unigram w tok m
  | _ -> fail "%s: only WordPiece and Unigram models are supported" !tokenizer);
  let table = load_table !model in
  add_table w "embeddings" table !kind;
  write w !out;
  Printf.printf "%s: %d tokens x %d, %s\n" !out (Bigarray.Array2.dim1 table) (Bigarray.Array2.dim2 table) !kind
