//! `tohdr` command line: produce and inspect HDR gain-map HEICs.
//!
//! Subcommands dispatch to modules that each own one concern:
//! [`convert`] encodes one file and [`batch`] many, [`inspect`] and
//! [`verify`] read back, [`bench`] compares engines. [`cli`] is parsing only,
//! so `--help` works even while every engine crate underneath is still
//! `todo!()`.

mod batch;
#[cfg(target_os = "macos")]
mod bench;
mod cli;
mod convert;
mod engine;
#[cfg(target_os = "macos")]
mod inspect;
mod panic_guard;
#[cfg(target_os = "macos")]
mod verify;

use clap::Parser;

use cli::{Cli, Command};

fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Command::Convert(args) => convert::run(args),
        Command::Batch(args) => batch::run(args),
        #[cfg(target_os = "macos")]
        Command::Inspect(args) => inspect::run(args),
        #[cfg(target_os = "macos")]
        Command::Verify(args) => verify::run(args),
        #[cfg(target_os = "macos")]
        Command::Bench(args) => bench::run(args),
    };

    match result {
        Ok(code) => std::process::exit(code),
        Err(e) => {
            eprintln!("tohdr: error: {e:#}");
            std::process::exit(1);
        }
    }
}
