external compress : string -> string = "ctx_zstd_compress"
external decompress : string -> string = "ctx_zstd_decompress"

let magic = "\x28\xb5\x2f\xfd"

(* A value without the zstd magic number was stored uncompressed: returned as is. *)
let decompress_if_framed s = if String.starts_with ~prefix:magic s then decompress s else s
