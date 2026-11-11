(* The C SigLIP 2 runtime against Hugging Face: on each test image (three CC0
   photos from Wikimedia Commons and formats derived from them), the same
   NaFlex grid and an embedding within Q8_0's error (cosine >= 0.995). The
   expectations are written by src/stubs/tools/siglip_fixtures.py. Then the
   zero-shot sanity: each photo's best node is under the right tier-1, and
   the image tier's calibrated labels keep only clear hits. Needs the models
   in src/data (fetch-data.sh, convert-models.sh); without them it says so
   and passes. *)

open Contextual

let data = Filename.concat (Filename.concat (Filename.concat Filename.parent_dir_name Filename.parent_dir_name) Filename.parent_dir_name) "data"
let read path = In_channel.with_open_bin path In_channel.input_all
let image name = read (Filename.concat "images" name)

let () =
  if not (Sys.file_exists (Filename.concat data "siglip2-base-patch16-naflex.gguf")) then print_endline "siglip: no model in data, skipped"
  else begin
    let e = Engine.load data in
    let v = Option.get e.vision in
    List.iter
      (fun line ->
        match String.split_on_char '\t' line with
        | [ name; n_h; n_w; values ] ->
            let want = Array.of_list (List.map float_of_string (String.split_on_char ',' values)) in
            let h, w, _ = Option.get (Siglip.preprocess (image name) ~patch:16 ~max_patches:256) in
            if (h, w) <> (int_of_string n_h, int_of_string n_w) then failwith (Printf.sprintf "%s: grid %dx%d, want %sx%s" name h w n_h n_w);
            let got = Result.get_ok (Siglip.embed v.model (image name) ~max_patches:256 ~min_side:1 ~threads:2) in
            let cos = Siglip.dot got want in
            Printf.printf "%s: %dx%d patches, cosine %.5f with Hugging Face\n" name h w cos;
            assert (cos >= 0.995)
        | _ -> ())
      (In_channel.input_lines (open_in "siglip_fixtures.tsv"));
    assert (Siglip.embed v.model (image "tiny.jpg") ~max_patches:256 ~min_side:v.min_side ~threads:1 = Error "small");
    assert (Siglip.embed v.model "not an image" ~max_patches:256 ~min_side:1 ~threads:1 = Error "undecodable");
    let embedding name = Result.get_ok (Siglip.embed v.model (image name) ~max_patches:256 ~min_side:1 ~threads:2) in
    let root id = List.nth (List.rev (Ontology.ancestors e.onto id)) 0 in
    let best name =
      let p = Siglip.zero_shot v.model v.protos (embedding name) in
      let j = ref 0 in
      Array.iteri (fun i x -> if x > p.(!j) then j := i) p;
      v.protos.ids.(!j)
    in
    List.iter
      (fun (name, tier1) ->
        let id = best name in
        Printf.printf "%s: best node %s\n" name (Ontology.path e.onto id);
        assert (Ontology.name e.onto (root id) = tier1))
      [ ("soccer.jpg", "Sports"); ("car.jpg", "Automotive"); ("pasta.jpg", "Food & Drink") ];
    (* An EV at a charging point is a clear hit; a beach soccer photo
       (SigLIP p 0.01) is not, and stays out. *)
    let labels name = List.map (fun (id, _, _) -> Ontology.path e.onto id) (Engine.image_labels e v (embedding name)) in
    assert (List.mem "Automotive > Auto Type > Green Vehicles" (labels "car.jpg"));
    assert (labels "soccer.jpg" = []);
    print_endline "siglip: all checks passed"
  end
