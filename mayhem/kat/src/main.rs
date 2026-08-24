//! `kat` — a minimal stand-in for `nickel eval`, reading a Nickel program from stdin, fully
//! evaluating it, and printing the result exactly as the real CLI does
//! (cli/src/eval.rs: `program.eval_full().map(|t| println!("{t}"))`).
//!
//! Exists ONLY as a lightweight, dynamically linked target for mayhem/test.sh's direct KAT
//! (known-answer) probes — see mayhem/kat/Cargo.toml for why this isn't just the real `nickel`
//! CLI binary.
use std::io::Read;

use nickel_lang_core::{eval::cache::CacheImpl, program::ProgramBuilder};

fn main() {
    let mut src = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut src) {
        eprintln!("kat: failed to read stdin: {e}");
        std::process::exit(2);
    }

    let program = ProgramBuilder::new()
        .add_source_string(src, "kat")
        .build::<CacheImpl>();

    let mut program = match program {
        Ok(p) => p,
        Err(e) => {
            eprintln!("kat: failed to build program: {e}");
            std::process::exit(1);
        }
    };

    match program.eval_full() {
        Ok(value) => println!("{value}"),
        Err(e) => {
            // nickel_lang_core::error::Error only derives Debug (its "real" rendering goes
            // through a Files-aware Reporter/codespan diagnostic, which we don't need here —
            // the KAT probes only check exit status + stdout for the error cases).
            eprintln!("kat: evaluation error: {e:?}");
            std::process::exit(1);
        }
    }
}
