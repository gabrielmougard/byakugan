//! A C ABI over FastWARC, as narrow as the crawler and the lab need:
//! - `ctx_warc_response`: one WARC/1.1 `response` record (the HTTP status
//!   line, headers and body as fetched) serialised as one gzip member, so a
//!   record can later be read alone from its byte offset and length;
//! - `ctx_warc_read`: one record back from such a member;
//! - `ctx_warc_open` / `ctx_warc_next` / `ctx_warc_close`: every record of a
//!   file, for replaying an archive through the pipeline.
//! Buffers handed out are freed with `ctx_warc_free`. Every function returns
//! 0 on success and a negative value on failure; nothing panics across the ABI
//! (panic = "abort" in the profile).

use std::fs::File;
use std::io::{BufReader, Cursor, Read};
use std::slice;

use fastwarc::stream_io::gzip::{GzipReader, GzipWriter};
use fastwarc::stream_io::traits::WarcWrite;
use fastwarc::warc::iter::ArchiveIterator;
use fastwarc::warc::record::{WarcRecord, WarcRecordType};

/// A record as the C side sees it. Pointers are owned by the record and
/// released by `ctx_warc_record_free`.
#[repr(C)]
pub struct CtxRecord {
    pub uri: *mut u8,
    pub uri_len: usize,
    pub date: *mut u8,
    pub date_len: usize,
    pub status: i32,
    pub content_type: *mut u8,
    pub content_type_len: usize,
    /// HTTP headers, one "name: value" per line (LF).
    pub headers: *mut u8,
    pub headers_len: usize,
    pub body: *mut u8,
    pub body_len: usize,
}

unsafe fn bytes<'a>(p: *const u8, n: usize) -> &'a [u8] {
    if p.is_null() || n == 0 { &[] } else { unsafe { slice::from_raw_parts(p, n) } }
}

fn leak(v: Vec<u8>) -> (*mut u8, usize) {
    let b = v.into_boxed_slice();
    let n = b.len();
    (Box::into_raw(b) as *mut u8, n)
}

/// Frees a buffer from `ctx_warc_response`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ctx_warc_free(p: *mut u8, n: usize) {
    if !p.is_null() {
        drop(unsafe { Box::from_raw(slice::from_raw_parts_mut(p, n)) });
    }
}

/// Frees the buffers of a record filled by `ctx_warc_read` or `ctx_warc_next`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ctx_warc_record_free(r: *mut CtxRecord) {
    if r.is_null() {
        return;
    }
    let r = unsafe { &mut *r };
    unsafe {
        ctx_warc_free(r.uri, r.uri_len);
        ctx_warc_free(r.date, r.date_len);
        ctx_warc_free(r.content_type, r.content_type_len);
        ctx_warc_free(r.headers, r.headers_len);
        ctx_warc_free(r.body, r.body_len);
    }
    r.uri = std::ptr::null_mut();
    r.date = std::ptr::null_mut();
    r.content_type = std::ptr::null_mut();
    r.headers = std::ptr::null_mut();
    r.body = std::ptr::null_mut();
}

/// One `response` record for `uri`, fetched at `date` (ISO 8601, UTC), whose
/// block is `http`: the status line, headers and body. Written with SHA-1
/// block and payload digests, as one gzip member, into `*out`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ctx_warc_response(
    uri: *const u8,
    uri_len: usize,
    date: *const u8,
    date_len: usize,
    http: *const u8,
    http_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let (uri, date, http) = unsafe { (bytes(uri, uri_len), bytes(date, date_len), bytes(http, http_len)) };
    let mut record = WarcRecord::new();
    record.init_headers(WarcRecordType::Response, None);
    record.headers_mut().set_bytes("WARC-Date", date);
    record.headers_mut().append_bytes("WARC-Target-URI", uri);
    record.headers_mut().append_bytes("Content-Type", b"application/http; msgtype=response");
    record.set_bytes_payload(http.to_vec());
    record.set_is_http(true);
    let mut writer = GzipWriter::new(Vec::new());
    if record.write_with_checksum(&mut writer).is_err() || writer.finish().is_err() {
        return -1;
    }
    match writer.into_inner() {
        Ok(v) => {
            let (p, n) = leak(v);
            unsafe {
                *out = p;
                *out_len = n;
            }
            0
        }
        Err(_) => -1,
    }
}

/// The parts of `record` the pipeline uses, the HTTP body as archived.
fn export(record: &mut WarcRecord, out: &mut CtxRecord) -> i32 {
    if record.parse_http().is_err() {
        return -2;
    }
    let header = |name: &str, h: &fastwarc::warc::header::HeaderMap| {
        h.get(name).map(|v| v.as_bytes().to_vec()).unwrap_or_default()
    };
    let uri = header("WARC-Target-URI", record.headers());
    let date = header("WARC-Date", record.headers());
    let (status, content_type, headers) = match record.http_headers() {
        Some(h) => {
            let mut lines = Vec::new();
            for (k, v) in h.items_bytes() {
                lines.extend_from_slice(&k);
                lines.extend_from_slice(b": ");
                lines.extend_from_slice(&v);
                lines.push(b'\n');
            }
            (h.status_code().map(i32::from).unwrap_or(0), header("Content-Type", h), lines)
        }
        None => (0, Vec::new(), Vec::new()),
    };
    let mut body = Vec::new();
    match record.reader_mut() {
        Some(r) => {
            if r.read_to_end(&mut body).is_err() {
                return -3;
            }
        }
        None => return -3,
    }
    (out.uri, out.uri_len) = leak(uri);
    (out.date, out.date_len) = leak(date);
    out.status = status;
    (out.content_type, out.content_type_len) = leak(content_type);
    (out.headers, out.headers_len) = leak(headers);
    (out.body, out.body_len) = leak(body);
    0
}

/// The first record in `buf`: one gzip member as `ctx_warc_response` wrote
/// it, read from its offset in a WARC file.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ctx_warc_read(buf: *const u8, len: usize, out: *mut CtxRecord) -> i32 {
    let data = unsafe { bytes(buf, len) }.to_vec();
    let mut it = ArchiveIterator::new(GzipReader::new(Cursor::new(data))).with_parse_http(false);
    match it.next() {
        Some(Ok(rec)) => export(&mut rec.borrow_mut(), unsafe { &mut *out }),
        _ => -1,
    }
}

/// Every record of a (multi-member gzip) WARC file, `response` records only.
pub struct CtxReader {
    it: ArchiveIterator,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ctx_warc_open(path: *const u8, path_len: usize) -> *mut CtxReader {
    let path = match std::str::from_utf8(unsafe { bytes(path, path_len) }) {
        Ok(p) => p,
        Err(_) => return std::ptr::null_mut(),
    };
    match File::open(path) {
        Ok(f) => {
            let it = ArchiveIterator::new(GzipReader::new(BufReader::with_capacity(1 << 20, f)))
                .with_parse_http(false);
            Box::into_raw(Box::new(CtxReader { it }))
        }
        Err(_) => std::ptr::null_mut(),
    }
}

/// 1 and `*out` filled with the next record, 0 at the end, negative on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ctx_warc_next(r: *mut CtxReader, out: *mut CtxRecord) -> i32 {
    let r = unsafe { &mut *r };
    loop {
        match r.it.next() {
            None => return 0,
            Some(Err(_)) => return -1,
            Some(Ok(rec)) => {
                let mut rec = rec.borrow_mut();
                if rec.record_type() != WarcRecordType::Response {
                    continue;
                }
                return match export(&mut rec, unsafe { &mut *out }) {
                    0 => 1,
                    e => e,
                };
            }
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ctx_warc_close(r: *mut CtxReader) {
    if !r.is_null() {
        drop(unsafe { Box::from_raw(r) });
    }
}
