use ethers::contract::Abigen;

// TODO: Figure out how to write the rerun-if-changed script properly
fn main() {
    // Only re-run the builder script if the contract changes
    println!("cargo:rerun-if-changed=./abis/*.json");
    bindgen("Cauldron");
    bindgen("Witch");
    bindgen("FlashLiquidator");
    bindgen("IMulticall2");
}

#[allow(dead_code)]
fn bindgen(fname: &str) {
    let bindings = Abigen::new(fname, format!("./abis/{}.json", fname))
        .expect("could not instantiate Abigen")
        .generate()
        .expect("could not generate bindings");

    bindings
        .write_to_file(format!("./src/bindings/{}.rs", fname.to_lowercase()))
        .expect("could not write bindings to file");
}
