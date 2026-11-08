// Snowdrift for Windows: W0 placeholder. Proves the toolchain on the test laptop builds a native .exe.
fn main() {
    println!("snowdrift {} on {} ({})", env!("CARGO_PKG_VERSION"), std::env::consts::OS, std::env::consts::ARCH);
}
