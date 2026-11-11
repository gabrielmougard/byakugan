(* The C Model2Vec runtime against Hugging Face tokenizers: every text of
   the fixtures (written by src/stubs/tools/m2v_fixtures.py) must give the
   same token ids. Needs the GGUF models in src/data (fetch-data.sh, then
   convert-models.sh); without them it says so and passes. *)

open Contextual

let unhex h = String.init (String.length h / 2) (fun i -> Char.chr (int_of_string ("0x" ^ String.sub h (2 * i) 2)))
let data = Filename.concat (Filename.concat (Filename.concat Filename.parent_dir_name Filename.parent_dir_name) Filename.parent_dir_name) "data"

let check model =
  let gguf = Filename.concat data (model ^ ".gguf") in
  if not (Sys.file_exists gguf) then Printf.printf "%s: no %s, skipped\n" model gguf
  else begin
    let m = Model2vec.load gguf in
    let lines = In_channel.with_open_bin ("m2v_" ^ model ^ ".tsv") In_channel.input_lines in
    let bad = ref 0 in
    List.iter
      (fun line ->
        match String.split_on_char '\t' line with
        | [ _; hex; ids ] ->
            let want = if ids = "" then [||] else Array.of_list (List.map int_of_string (String.split_on_char ',' ids)) in
            if Model2vec.token_ids m (unhex hex) <> want then begin
              incr bad;
              Printf.printf "%s: token ids differ for %S\n" model (unhex hex)
            end
        | _ -> ())
      lines;
    assert (!bad = 0);
    let v = Model2vec.embed m "Les élèves ont étudié l'histoire de la Révolution française." in
    let norm = sqrt (Array.fold_left (fun a x -> a +. (x *. x)) 0. v) in
    assert (Float.abs (norm -. 1.) < 1e-4);
    assert (Array.for_all (fun x -> x = 0.) (Model2vec.embed m "[UNK]"));
    Printf.printf "%s: %d texts tokenized as Hugging Face does\n" model (List.length lines)
  end

let () = List.iter check [ "potion-base-32M"; "potion-multilingual-128M" ]
