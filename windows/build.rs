//! Gives snowdrift.exe its icon (assets/snowdrift.ico as icon group 1) without a resource compiler:
//! writes the COFF object windres would (one .rsrc section) and links it in.
use std::{env, fs, path::PathBuf};

fn u16le(v: &mut Vec<u8>, x: u16) { v.extend_from_slice(&x.to_le_bytes()); }
fn u32le(v: &mut Vec<u8>, x: u32) { v.extend_from_slice(&x.to_le_bytes()); }
fn align8(v: &mut Vec<u8>) { while v.len() % 8 != 0 { v.push(0); } }

fn main() {
    println!("cargo:rerun-if-changed=assets/snowdrift.ico");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") { return; }
    let ico = fs::read("assets/snowdrift.ico").expect("assets/snowdrift.ico");
    let rd16 = |o: usize| u16::from_le_bytes([ico[o], ico[o + 1]]);
    let rd32 = |o: usize| u32::from_le_bytes(ico[o..o + 4].try_into().unwrap());

    // .ico entries → RT_ICON resources 1..n, plus the RT_GROUP_ICON that lists them (same records,
    // with the resource id in place of the file offset).
    let n = rd16(4) as usize;
    let mut icons = Vec::new();
    let mut group = Vec::new();
    u16le(&mut group, 0); u16le(&mut group, 1); u16le(&mut group, n as u16);
    for i in 0..n {
        let e = 6 + 16 * i;
        let (len, at) = (rd32(e + 8) as usize, rd32(e + 12) as usize);
        icons.push(((i + 1) as u32, ico[at..at + len].to_vec()));
        group.extend_from_slice(&ico[e..e + 12]);
        u16le(&mut group, (i + 1) as u16);
    }
    let types: Vec<(u32, Vec<(u32, Vec<u8>)>)> = vec![(3, icons), (14, vec![(1, group)])];   // RT_ICON, RT_GROUP_ICON
    let leaves: Vec<&Vec<u8>> = types.iter().flat_map(|t| t.1.iter().map(|l| &l.1)).collect();

    // Resource tree: root → type → id → language → data entry → data. All sizes are multiples of 8.
    let mut s = Vec::new();
    let dir = |s: &mut Vec<u8>, count: usize| { s.extend_from_slice(&[0; 12]); u16le(s, 0); u16le(s, count as u16); };
    const SUB: u32 = 0x8000_0000;
    let root = 16 + 8 * types.len();
    let type_dirs: usize = types.iter().map(|t| 16 + 8 * t.1.len()).sum();
    let entries = root + type_dirs + 24 * leaves.len();
    dir(&mut s, types.len());
    let mut next = root;
    for t in &types { u32le(&mut s, t.0); u32le(&mut s, next as u32 | SUB); next += 16 + 8 * t.1.len(); }
    for t in &types {
        dir(&mut s, t.1.len());
        for (id, _) in &t.1 { u32le(&mut s, *id); u32le(&mut s, next as u32 | SUB); next += 24; }
    }
    for i in 0..leaves.len() { dir(&mut s, 1); u32le(&mut s, 0x0409); u32le(&mut s, (entries + 16 * i) as u32); }
    let mut relocs = Vec::new();
    let mut at = entries + 16 * leaves.len();
    for d in &leaves {
        relocs.push(s.len() as u32);          // OffsetToData is an RVA: the linker adds the section's
        u32le(&mut s, at as u32); u32le(&mut s, d.len() as u32); u32le(&mut s, 0); u32le(&mut s, 0);
        at = (at + d.len() + 7) / 8 * 8;
    }
    for d in &leaves { align8(&mut s); s.extend_from_slice(d); }

    // COFF: header, one section, its data, relocations (IMAGE_REL_AMD64_ADDR32NB to the section
    // symbol), a one-entry symbol table, an empty string table.
    let mut o = Vec::new();
    let raw = 20 + 40;
    let reloc_at = raw + s.len();
    let sym_at = reloc_at + 10 * relocs.len();
    u16le(&mut o, 0x8664); u16le(&mut o, 1); u32le(&mut o, 0); u32le(&mut o, sym_at as u32); u32le(&mut o, 1); u16le(&mut o, 0); u16le(&mut o, 0);
    o.extend_from_slice(b".rsrc\0\0\0"); u32le(&mut o, 0); u32le(&mut o, 0); u32le(&mut o, s.len() as u32); u32le(&mut o, raw as u32);
    u32le(&mut o, reloc_at as u32); u32le(&mut o, 0); u16le(&mut o, relocs.len() as u16); u16le(&mut o, 0); u32le(&mut o, 0x4000_0040);
    o.extend_from_slice(&s);
    for r in relocs { u32le(&mut o, r); u32le(&mut o, 0); u16le(&mut o, 3); }
    o.extend_from_slice(b".rsrc\0\0\0"); u32le(&mut o, 0); u16le(&mut o, 1); u16le(&mut o, 0); o.push(3); o.push(0);
    u32le(&mut o, 4);

    let path = PathBuf::from(env::var("OUT_DIR").unwrap()).join("icon.o");
    fs::write(&path, o).unwrap();
    println!("cargo:rustc-link-arg-bins={}", path.display());
}
