use anyhow::{Context, Result};
use std::fs;
use std::io::Write;
use std::path::Path;

// Threshold for considering an on-file EXIF date "clearly wrong" vs client-provided created_at (seconds)
const DATE_DRIFT_THRESHOLD_SECS: i64 = 48 * 3600; // 2 days

fn is_jpeg(bytes: &[u8]) -> bool {
    bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8
}

// Parse minimal JPEG segments; returns vector of (marker, start, end, payload_offset)
// start points at marker 0xFF, end is first byte after the segment (or SOS payload start for 0xDA case)
fn parse_segments(bytes: &[u8]) -> Vec<(u8, usize, usize, usize)> {
    let mut segs = Vec::new();
    if !is_jpeg(bytes) {
        return segs;
    }
    let mut i = 2; // skip SOI
    while i + 4 <= bytes.len() {
        if bytes[i] != 0xFF {
            break;
        }
        let mut j = i;
        while j < bytes.len() && bytes[j] == 0xFF {
            j += 1;
        }
        if j >= bytes.len() {
            break;
        }
        let marker = bytes[j];
        if marker == 0xD9 {
            // EOI
            segs.push((marker, i, j + 1, j + 1));
            break;
        }
        if marker == 0xDA {
            // SOS - read length then the rest is entropy-coded until next 0xFF 0xD9
            if j + 2 >= bytes.len() {
                break;
            }
            let len = u16::from_be_bytes([bytes[j + 1], bytes[j + 2]]) as usize; // includes length bytes
            let seg_end = j + 1 + len;
            segs.push((marker, i, seg_end, j + 3));
            // From SOS to EOI is scan data; stop parsing headers
            break;
        }
        if j + 2 >= bytes.len() {
            break;
        }
        let len = u16::from_be_bytes([bytes[j + 1], bytes[j + 2]]) as usize; // includes the 2 length bytes
        let seg_end = j + 1 + len;
        if seg_end > bytes.len() {
            break;
        }
        segs.push((marker, i, seg_end, j + 3));
        i = seg_end;
    }
    segs
}

fn be16(x: u16) -> [u8; 2] {
    x.to_be_bytes()
}
fn be32(x: u32) -> [u8; 4] {
    x.to_be_bytes()
}

fn build_exif_app1(dt_ascii: &str) -> Vec<u8> {
    // Build minimal TIFF with IFD0 (DateTime + ExifIFDPointer) and ExifIFD (DateTimeOriginal/DateTimeDigitized)
    let dt = format!("{}\0", dt_ascii);
    let dt_len = dt.as_bytes().len() as u32;

    // TIFF offset plan (relative to TIFF header start)
    let ifd0_off = 8u32;
    let ifd0_size = 2 + 2 * 12 + 4; // entries=2 -> 30 bytes
    let exif_ifd_off = ifd0_off + ifd0_size; // 38
    let exif_ifd_size = 2 + 2 * 12 + 4; // 30
    let data_off = exif_ifd_off + exif_ifd_size; // 68
    let dt1_off = data_off;
    let dt2_off = data_off + dt_len;
    let dt3_off = data_off + dt_len * 2;

    let mut tiff: Vec<u8> = Vec::new();
    // TIFF header (MM, 0x002A, first IFD offset=8)
    tiff.extend_from_slice(&[0x4D, 0x4D, 0x00, 0x2A]);
    tiff.extend_from_slice(&be32(ifd0_off));
    // IFD0
    tiff.extend_from_slice(&be16(2));
    // Tag 0x0132 DateTime (ASCII)
    tiff.extend_from_slice(&be16(0x0132)); // tag
    tiff.extend_from_slice(&be16(2)); // ASCII
    tiff.extend_from_slice(&be32(dt_len)); // count
    tiff.extend_from_slice(&be32(dt1_off)); // value offset
                                            // Tag 0x8769 ExifIFDPointer (LONG, count=1)
    tiff.extend_from_slice(&be16(0x8769));
    tiff.extend_from_slice(&be16(4)); // LONG
    tiff.extend_from_slice(&be32(1));
    tiff.extend_from_slice(&be32(exif_ifd_off));
    // next IFD
    tiff.extend_from_slice(&be32(0));
    // Exif IFD
    tiff.extend_from_slice(&be16(2));
    // 0x9003 DateTimeOriginal
    tiff.extend_from_slice(&be16(0x9003));
    tiff.extend_from_slice(&be16(2));
    tiff.extend_from_slice(&be32(dt_len));
    tiff.extend_from_slice(&be32(dt2_off));
    // 0x9004 DateTimeDigitized (CreateDate)
    tiff.extend_from_slice(&be16(0x9004));
    tiff.extend_from_slice(&be16(2));
    tiff.extend_from_slice(&be32(dt_len));
    tiff.extend_from_slice(&be32(dt3_off));
    // next
    tiff.extend_from_slice(&be32(0));
    // Data area: three copies of the dt string (simple and clear)
    tiff.extend_from_slice(dt.as_bytes());
    tiff.extend_from_slice(dt.as_bytes());
    tiff.extend_from_slice(dt.as_bytes());

    // Build APP1 Exif segment
    let mut payload: Vec<u8> = Vec::new();
    payload.extend_from_slice(b"Exif\0\0");
    payload.extend_from_slice(&tiff);
    let mut seg = Vec::new();
    seg.push(0xFF);
    seg.push(0xE1); // APP1
    let len = (payload.len() + 2) as u16; // length includes these two bytes
    seg.extend_from_slice(&be16(len));
    seg.extend_from_slice(&payload);
    seg
}

fn build_xmp_app1(dt_iso8601: &str) -> Vec<u8> {
    let header = b"http://ns.adobe.com/xap/1.0/\0";
    let xml = format!(
        r#"<?xpacket begin='﻿' id='W5M0MpCehiHzreSzNTczkc9d'?>
<x:xmpmeta xmlns:x='adobe:ns:meta/'>
 <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>
  <rdf:Description xmlns:xmp='http://ns.adobe.com/xap/1.0/' xmlns:photoshop='http://ns.adobe.com/photoshop/1.0/'>
   <xmp:CreateDate>{}</xmp:CreateDate>
   <photoshop:DateCreated>{}</photoshop:DateCreated>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end='w'?>"#,
        dt_iso8601, dt_iso8601
    );
    let mut payload = Vec::new();
    payload.extend_from_slice(header);
    payload.extend_from_slice(xml.as_bytes());
    let mut seg = Vec::new();
    seg.push(0xFF);
    seg.push(0xE1);
    let len = (payload.len() + 2) as u16;
    seg.extend_from_slice(&be16(len));
    seg.extend_from_slice(&payload);
    seg
}

fn read_exif_dt_epoch(path: &Path) -> Option<i64> {
    use exif::{In, Tag};
    let file = fs::File::open(path).ok()?;
    let mut br = std::io::BufReader::new(file);
    let ex = exif::Reader::new().read_from_container(&mut br).ok()?;
    let val = ex
        .get_field(Tag::DateTimeOriginal, In::PRIMARY)
        .or_else(|| ex.get_field(Tag::DateTime, In::PRIMARY))
        .map(|f| f.display_value().to_string())?;
    // Try parse "YYYY:MM:DD HH:MM:SS"
    let s = val.trim_matches('"');
    use chrono::{Local, NaiveDateTime, TimeZone};
    if let Ok(naive) = NaiveDateTime::parse_from_str(s, "%Y:%m:%d %H:%M:%S") {
        if let Some(ldt) = Local.from_local_datetime(&naive).single() {
            return Some(ldt.timestamp());
        }
        return Some(naive.and_utc().timestamp());
    }
    None
}

pub fn should_update_jpeg_created(path: &Path, client_created: i64) -> bool {
    if client_created <= 0 {
        return false;
    }
    if let Some(existing) = read_exif_dt_epoch(path) {
        (existing - client_created).abs() > DATE_DRIFT_THRESHOLD_SECS
    } else {
        true
    }
}

pub fn write_jpeg_created_inplace(path: &Path, client_created: i64) -> Result<bool> {
    let bytes = fs::read(path).with_context(|| format!("read jpeg: {}", path.display()))?;
    if !is_jpeg(&bytes) {
        return Ok(false);
    }

    // Remember times to restore after write (cross-platform)
    let (atf_before, mtf_before) = if let Ok(meta) = fs::metadata(path) {
        use filetime::FileTime;
        (
            FileTime::from_last_access_time(&meta),
            FileTime::from_last_modification_time(&meta),
        )
    } else {
        (filetime::FileTime::now(), filetime::FileTime::now())
    };

    // Build time strings
    use chrono::{Local, TimeZone};
    let ldt = Local
        .timestamp_opt(client_created, 0)
        .single()
        .unwrap_or_else(|| Local::now());
    let dt_ascii = ldt.format("%Y:%m:%d %H:%M:%S").to_string();
    let tz_secs = ldt.offset().local_minus_utc();
    let sign = if tz_secs >= 0 { '+' } else { '-' };
    let abs = tz_secs.abs();
    let tz_h = abs / 3600;
    let tz_m = (abs % 3600) / 60;
    let dt_iso = format!(
        "{}{}{:02}:{:02}",
        ldt.format("%Y-%m-%dT%H:%M:%S"),
        sign,
        tz_h,
        tz_m
    );

    let exif_seg = build_exif_app1(&dt_ascii);
    let xmp_seg = build_xmp_app1(&dt_iso);

    // Locate insertion point: after APP0 JFIF if present, else directly after SOI
    let segs = parse_segments(&bytes);
    let mut insert_after = 2usize; // default after SOI
    let mut sos_start = None;
    let mut skip_ranges: Vec<(usize, usize)> = Vec::new();
    for (marker, start, end, payload) in &segs {
        if *marker == 0xDA {
            sos_start = Some(*start);
            break;
        }
        if *marker == 0xE0 {
            // APP0
            // Heuristic: if payload starts with "JFIF\0"
            if *payload + 5 <= bytes.len() && &bytes[*payload..*payload + 5] == b"JFIF\0" {
                insert_after = *end;
            }
        }
        if *marker == 0xE1 {
            // Skip existing Exif or XMP APP1s
            if *payload + 6 <= bytes.len() && &bytes[*payload..*payload + 6] == b"Exif\0\0" {
                skip_ranges.push((*start, *end));
            } else if *payload + 29 <= bytes.len()
                && &bytes[*payload..*payload + 29] == b"http://ns.adobe.com/xap/1.0/\0"
            {
                skip_ranges.push((*start, *end));
            }
        }
    }

    let mut out = Vec::with_capacity(bytes.len() + exif_seg.len() + xmp_seg.len() + 16);
    // SOI
    out.extend_from_slice(&bytes[0..2]);
    let mut pos = 2usize;
    if insert_after > 2 {
        out.extend_from_slice(&bytes[pos..insert_after]);
        pos = insert_after;
    }
    // Insert our EXIF + XMP
    out.extend_from_slice(&exif_seg);
    out.extend_from_slice(&xmp_seg);
    // Copy the rest, skipping previous Exif/XMP APP1s
    let mut i = pos;
    for (start, end) in skip_ranges.into_iter() {
        if i < start {
            out.extend_from_slice(&bytes[i..start]);
        }
        i = end;
    }
    if i < bytes.len() {
        out.extend_from_slice(&bytes[i..]);
    }

    fs::write(path, &out).with_context(|| format!("write jpeg: {}", path.display()))?;

    // Restore times (best-effort)
    let _ = filetime::set_file_times(path, atf_before, mtf_before);

    Ok(true)
}
