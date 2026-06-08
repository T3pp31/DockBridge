fn main() {
    uniffi::generate_scaffolding("src/dockbridge_uniffi.udl")
        .expect("UniFFI scaffolding generation failed");
}
