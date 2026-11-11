let dot a b =
  let s = ref 0. in
  Array.iteri (fun i x -> s := !s +. (x *. b.(i))) a;
  !s

let cosine a b =
  let d = sqrt (dot a a *. dot b b) in
  if d = 0. then 0. else dot a b /. d

(* Model2Vec-style static embedding: sum of token vectors (cosine ignores the
   mean's scale). shortcut: whole-word lookup in an in-memory table; production
   uses the model's WordPiece tokens and a potion-* table exported to a flat
   float32 file, mmapped as a Bigarray. *)
let static_embedder table ~dim text =
  let v = Array.make dim 0. in
  Array.iter
    (fun tok ->
      Option.iter (Array.iteri (fun i x -> v.(i) <- v.(i) +. x)) (Hashtbl.find_opt table tok))
    (Text.tokens text);
  v
