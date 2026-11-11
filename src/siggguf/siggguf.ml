(* SigLIP 2's vision tower from a Hugging Face model.safetensors as one GGUF
   file, for src/stubs/sig.c. Tensor names and the fused Q/K/V follow
   hbd-siglip2.cpp's converter (scripts/convert_siglip2_to_gguf.py). Matrices
   are stored as --type (q8_0 by default); norms, biases, the position grid
   and the probe stay f32. The text tower is not converted: the taxonomy's
   text embeddings come precomputed (src/stubs/tools/siglip_prototypes.py).

   siggguf.exe --model M.safetensors [--heads 12] [--type q8_0|f16|f32] -o OUT.gguf *)

type writer
type matrix = (float, Bigarray.float32_elt, Bigarray.c_layout) Bigarray.Array2.t

external writer : unit -> writer = "ctx_gguf_new"
external set_str : writer -> string -> string -> unit = "ctx_gguf_str"
external set_u32 : writer -> string -> int -> unit = "ctx_gguf_u32"
external set_f32 : writer -> string -> float -> unit = "ctx_gguf_f32"
external add_table : writer -> string -> matrix -> string -> unit = "ctx_gguf_table"
external write : writer -> string -> unit = "ctx_gguf_write"

module J = Yojson.Safe.Util

let fail fmt = Printf.ksprintf failwith fmt

(* safetensors: u64 header length, JSON header, raw little-endian tensors.
   Every tensor comes back as a matrix: a vector of n as 1 x n. *)
let open_safetensors path =
  let ic = open_in_bin path in
  let header_len = Int64.to_int (String.get_int64_le (really_input_string ic 8) 0) in
  let header = J.to_assoc (Yojson.Safe.from_string (really_input_string ic header_len)) in
  close_in ic;
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  let get name =
    match List.assoc_opt name header with
    | None -> fail "%s: no tensor %s" path name
    | Some t -> (
        let shape = List.map J.to_int (J.to_list (J.member "shape" t)) in
        let start = J.to_int (List.hd (J.to_list (J.member "data_offsets" t))) in
        if J.member "dtype" t <> `String "F32" then fail "%s: %s is not F32" path name;
        let rows, cols =
          match List.filter (fun d -> d <> 1) shape with
          | [] -> (1, 1)
          | [ n ] -> (1, n)
          | [ r; c ] -> (r, c)
          | _ -> fail "%s: %s has more than two non-unit dimensions" path name
        in
        let pos = Int64.of_int (8 + header_len + start) in
        Bigarray.array2_of_genarray (Unix.map_file fd ~pos Bigarray.float32 Bigarray.c_layout false [| rows; cols |]))
  in
  let names = List.map fst header in
  (get, names)

let rows (m : matrix) first n = Bigarray.Array2.sub_left m first n

(* A vector's slice, as 1 x n. *)
let span (m : matrix) first n =
  Bigarray.reshape_2 (Bigarray.genarray_of_array1 (Bigarray.Array1.sub (Bigarray.reshape_1 (Bigarray.genarray_of_array2 m) (Bigarray.Array2.dim2 m)) first n)) 1 n

let stack (parts : matrix list) =
  let cols = Bigarray.Array2.dim2 (List.hd parts) in
  let total = List.fold_left (fun a p -> a + Bigarray.Array2.dim1 p) 0 parts in
  let out = Bigarray.Array2.create Bigarray.float32 Bigarray.c_layout total cols in
  ignore
    (List.fold_left
       (fun r p ->
         let n = Bigarray.Array2.dim1 p in
         Bigarray.Array2.blit p (rows out r n);
         r + n)
       0 parts);
  out

(* Biases concatenate along their single row. *)
let concat (parts : matrix list) =
  let total = List.fold_left (fun a p -> a + Bigarray.Array2.dim2 p) 0 parts in
  let out = Bigarray.Array2.create Bigarray.float32 Bigarray.c_layout 1 total in
  ignore
    (List.fold_left
       (fun c p ->
         let n = Bigarray.Array2.dim2 p in
         for j = 0 to n - 1 do
           out.{0, c + j} <- p.{0, j}
         done;
         c + n)
       0 parts);
  out

let () =
  let model = ref "" and out = ref "" and kind = ref "q8_0" and heads = ref 12 in
  Arg.parse
    [ ("--model", Arg.Set_string model, "FILE model.safetensors");
      ("--heads", Arg.Set_int heads, "N vision attention heads (12 for base, 16 for so400m)");
      ("--type", Arg.Set_string kind, "TYPE matrix storage: q8_0 (default), f16 or f32");
      ("-o", Arg.Set_string out, "FILE output .gguf") ]
    (fun _ -> ())
    "siggguf --model M.safetensors -o OUT.gguf";
  if !model = "" || !out = "" then fail "--model and -o are required";
  let get, names = open_safetensors !model in
  let w = writer () in
  let matrix name m = add_table w name m !kind and vector name m = add_table w name m "f32" in
  let v = "vision_model." in
  let patch_w = get (v ^ "embeddings.patch_embedding.weight") in
  let hidden = Bigarray.Array2.dim1 patch_w in
  let pos = get (v ^ "embeddings.position_embedding.weight") in
  let layers = List.length (List.filter (fun n -> String.ends_with ~suffix:".layer_norm1.weight" n && String.starts_with ~prefix:(v ^ "encoder.layers.") n) names) in
  let patch = int_of_float (Float.round (sqrt (float (Bigarray.Array2.dim2 patch_w / 3)))) in
  set_str w "general.architecture" "siglip2";
  set_str w "general.name" "siglip2-base-patch16-naflex";
  set_u32 w "siglip2.vision.embedding_length" hidden;
  set_u32 w "siglip2.vision.attention.head_count" !heads;
  set_u32 w "siglip2.vision.block_count" layers;
  set_u32 w "siglip2.vision.patch_size" patch;
  set_u32 w "siglip2.vision.num_patches" (Bigarray.Array2.dim1 pos);
  set_f32 w "siglip2.vision.layer_norm_eps" 1e-6;
  set_f32 w "siglip2.logit_scale" (get "logit_scale").{0, 0};
  set_f32 w "siglip2.logit_bias" (get "logit_bias").{0, 0};
  matrix "v.patch_embd.weight" patch_w;
  vector "v.patch_embd.bias" (get (v ^ "embeddings.patch_embedding.bias"));
  vector "v.position_embd.weight" pos;
  for l = 0 to layers - 1 do
    let hf s = get (Printf.sprintf "%sencoder.layers.%d.%s" v l s) and ours s = Printf.sprintf "v.blk.%d.%s" l s in
    vector (ours "ln1.weight") (hf "layer_norm1.weight");
    vector (ours "ln1.bias") (hf "layer_norm1.bias");
    matrix (ours "attn_qkv.weight") (stack (List.map (fun p -> hf ("self_attn." ^ p ^ "_proj.weight")) [ "q"; "k"; "v" ]));
    vector (ours "attn_qkv.bias") (concat (List.map (fun p -> hf ("self_attn." ^ p ^ "_proj.bias")) [ "q"; "k"; "v" ]));
    matrix (ours "attn_o.weight") (hf "self_attn.out_proj.weight");
    vector (ours "attn_o.bias") (hf "self_attn.out_proj.bias");
    vector (ours "ln2.weight") (hf "layer_norm2.weight");
    vector (ours "ln2.bias") (hf "layer_norm2.bias");
    matrix (ours "ffn_up.weight") (hf "mlp.fc1.weight");
    vector (ours "ffn_up.bias") (hf "mlp.fc1.bias");
    matrix (ours "ffn_down.weight") (hf "mlp.fc2.weight");
    vector (ours "ffn_down.bias") (hf "mlp.fc2.bias")
  done;
  vector "v.post_ln.weight" (get (v ^ "post_layernorm.weight"));
  vector "v.post_ln.bias" (get (v ^ "post_layernorm.bias"));
  let head s = get (v ^ "head." ^ s) in
  vector "v.head.probe" (head "probe");
  let in_w = head "attention.in_proj_weight" and in_b = head "attention.in_proj_bias" in
  List.iteri
    (fun i p ->
      matrix ("v.head.attn_" ^ p ^ ".weight") (rows in_w (i * hidden) hidden);
      vector ("v.head.attn_" ^ p ^ ".bias") (span in_b (i * hidden) hidden))
    [ "q"; "k"; "v" ];
  matrix "v.head.attn_o.weight" (head "attention.out_proj.weight");
  vector "v.head.attn_o.bias" (head "attention.out_proj.bias");
  vector "v.head.ln.weight" (head "layernorm.weight");
  vector "v.head.ln.bias" (head "layernorm.bias");
  matrix "v.head.ffn_up.weight" (head "mlp.fc1.weight");
  vector "v.head.ffn_up.bias" (head "mlp.fc1.bias");
  matrix "v.head.ffn_down.weight" (head "mlp.fc2.weight");
  vector "v.head.ffn_down.bias" (head "mlp.fc2.bias");
  write w !out;
  Printf.printf "%s: %d layers, hidden %d, patch %d, %s\n" !out layers hidden patch !kind
