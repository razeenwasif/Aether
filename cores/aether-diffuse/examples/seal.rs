//! Seal files the way Proton does, with a key read from a file of 32 bytes,
//! for making sealed fixtures to test against. Never point it at the key in
//! the person's keychain.
//!
//!     cargo run --example seal -- <key-file> <file>...
//!
//! Each file is written sealed beside itself as `<file>.sealed`; the plain
//! file is left where it is.

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some((key_file, files)) = args.split_first().filter(|(_, files)| !files.is_empty()) else {
        eprintln!("usage: seal <key-file> <file>...");
        std::process::exit(2);
    };
    let key = std::fs::read(key_file).unwrap_or_else(|e| panic!("{key_file}: {e}"));
    let key = aether_diffuse::SealKey::new(key).unwrap_or_else(|e| panic!("{e}"));
    for file in files {
        let bytes = std::fs::read(file).unwrap_or_else(|e| panic!("{file}: {e}"));
        let to = aether_diffuse::write_file(file.clone(), bytes, Some(key.clone())).unwrap_or_else(|e| panic!("{e}"));
        println!("{to}");
    }
}
