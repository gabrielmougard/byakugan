(* Model2Vec static embeddings through the C runtime (src/stubs/m2v_*.c, on
   vendored ggml). One GGUF file per model holds the token table (Q8_0) and
   the whole tokenizer; token ids are those of Hugging Face tokenizers.
   A model is read-only once loaded, so any domain may use it, and the
   batch calls release the OCaml runtime while they work. *)

type t
type matrix = (float, Bigarray.float32_elt, Bigarray.c_layout) Bigarray.Array2.t

(* A GGUF file written by src/m2vgguf. *)
external load : string -> t = "ctx_m2v_load"
external dim : t -> int = "ctx_m2v_dim"
external token_ids : t -> string -> int array = "ctx_m2v_tokenize"

(* One row per text: mean of its token rows, L2-normalised. *)
external embed_batch : t -> string array -> matrix = "ctx_m2v_embed_batch"
external dots_into : matrix -> matrix -> matrix -> unit = "ctx_m2v_dots"

let embed t text =
  let m = embed_batch t [| text |] in
  Array.init (dim t) (fun j -> m.{0, j})

(* rows.(i) as one matrix. *)
let matrix rows =
  let n = Array.length rows in
  let d = if n = 0 then 0 else Array.length rows.(0) in
  let m = Bigarray.Array2.create Bigarray.float32 Bigarray.c_layout n d in
  Array.iteri (fun i r -> Array.iteri (fun j x -> m.{i, j} <- x) r) rows;
  m

(* scores.{i, j} = dot (vecs row i) (protos row j), one matrix multiply. *)
let dots ~protos vecs =
  let out = Bigarray.Array2.create Bigarray.float32 Bigarray.c_layout (Bigarray.Array2.dim1 vecs) (Bigarray.Array2.dim1 protos) in
  dots_into protos vecs out;
  out
