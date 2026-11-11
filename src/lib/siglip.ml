(* SigLIP 2 (siglip2-base-patch16-naflex) image embeddings, from the C
   runtime in src/stubs/sig.c on ggml, and zero-shot against the taxonomy's
   text embeddings, precomputed by src/stubs/tools/siglip_prototypes.py. *)

type t

external load : string -> t = "ctx_sig_load"
external dim : t -> int = "ctx_sig_dim"
external logit : t -> float * float = "ctx_sig_logit"

(* An image's L2-normalised embedding; Error "undecodable" if the bytes are
   not a JPEG, PNG or WebP the decoders accept, Error "small" if a side is
   under [min_side] pixels. [max_patches] is NaFlex's budget (256 is the
   model's default; fewer is faster and coarser). Releases the runtime. *)
external embed : t -> string -> max_patches:int -> min_side:int -> threads:int -> (float array, string) result
  = "ctx_sig_embed"

(* The two halves of [embed], for the parity tests against Hugging Face. *)
external preprocess : string -> patch:int -> max_patches:int -> (int * int * float array) option = "ctx_sig_preprocess"
external encode : t -> float array -> int -> int -> threads:int -> float array = "ctx_sig_encode"
external read_prototypes : string -> string array * float array array = "ctx_sig_prototypes"

type prototypes = { ids : string array; vectors : float array array }

let prototypes path =
  let ids, vectors = read_prototypes path in
  { ids; vectors }

let dot a b =
  let s = ref 0. in
  Array.iteri (fun i x -> s := !s +. (x *. b.(i))) a;
  !s

(* SigLIP is trained with a sigmoid per (image, text) pair, so each node's
   probability stands alone: several can hold, or none. *)
let zero_shot t protos image =
  let scale, bias = logit t in
  let s = exp scale in
  Array.map (fun p -> 1. /. (1. +. exp (-.((s *. dot p image) +. bias)))) protos.vectors
