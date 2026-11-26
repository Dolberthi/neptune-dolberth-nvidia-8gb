//! Exports the two symbols by which `d3d12.dll` finds the redistributable
//! Agility SDK runtime (`D3D12\D3D12Core.dll` 1.620.2) beside `victory.exe`.
//! Needed on Windows 10 (whose inbox D3D12 stops at SM 6.5, rejecting all
//! SM 6.6 root signatures) in release builds as well as diagnostics builds.
//!
//! (Neptune) It also puts that runtime there: the repository keeps Microsoft's
//! redistributable `redist/D3D12/D3D12Core.dll` (1.620.2, unmodified; see
//! `redist/D3D12/README.txt`), and each build copies it to
//! `target/<profile>/D3D12/` (or `target/<triple>/<profile>/D3D12/`) unless an
//! identical file is already there. Without it the exports above make D3D12
//! fail on Windows 10 and 11 with 0x887E0003.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        println!("cargo:rustc-link-arg-bins=/EXPORT:D3D12SDKVersion,DATA");
        println!("cargo:rustc-link-arg-bins=/EXPORT:D3D12SDKPath,DATA");
        place_agility_runtime();
    }
}

/// Copies the repository's `D3D12Core.dll` beside the executable cargo is
/// building. A failure only warns: the build itself does not need the file.
fn place_agility_runtime() {
    let Ok(manifest) = std::env::var("CARGO_MANIFEST_DIR") else { return };
    let source = std::path::Path::new(&manifest).join("../../redist/D3D12/D3D12Core.dll");
    println!("cargo:rerun-if-changed={}", source.display());
    let Ok(out) = std::env::var("OUT_DIR") else { return };
    // OUT_DIR is <profile dir>/build/<package>-<hash>/out.
    let Some(profile) = std::path::Path::new(&out).ancestors().nth(3) else { return };
    let dir = profile.join("D3D12");
    let target = dir.join("D3D12Core.dll");
    let Ok(bytes) = std::fs::read(&source) else {
        println!("cargo:warning=redist/D3D12/D3D12Core.dll is missing: run tools\\get-agility-sdk.ps1 after the build");
        return;
    };
    if std::fs::read(&target).is_ok_and(|have| have == bytes) {
        return;
    }
    if std::fs::create_dir_all(&dir).and_then(|()| std::fs::write(&target, &bytes)).is_err() {
        println!("cargo:warning=could not write {}: copy redist/D3D12/D3D12Core.dll there by hand", target.display());
    }
}
