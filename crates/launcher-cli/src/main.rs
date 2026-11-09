mod commands;
mod context;

use std::path::PathBuf;

use clap::{Args, Parser, Subcommand};

use launcher_core::{Error, Result};

#[derive(Parser, Debug)]
#[command(
    name = "lingxi",
    version,
    about = "LingXi Launcher CLI: install, launch and maintain Minecraft instances"
)]
struct Cli {
    /// Game root (the .minecraft directory). Defaults to the official launcher location.
    #[arg(long, global = true)]
    root: Option<PathBuf>,
    /// Launcher data root. Defaults to the platform application data directory.
    #[arg(long = "data-root", global = true)]
    data_root: Option<PathBuf>,
    /// Emit a single JSON document on stdout.
    #[arg(long, global = true)]
    json: bool,
    /// Download source: official, mirror, auto or local-cache-only.
    #[arg(long, global = true)]
    source: Option<String>,
    /// Trusted mirror configuration JSON (required with --source mirror).
    #[arg(long = "mirror-config", global = true)]
    mirror_config: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Inspect version metadata.
    Version {
        #[command(subcommand)]
        action: VersionAction,
    },
    /// Check Java runtimes and version dependencies.
    #[command(disable_version_flag = true)]
    Doctor {
        #[arg(long)]
        java: Option<PathBuf>,
        #[arg(long)]
        version: Option<String>,
    },
    /// Launch a game instance.
    Launch(LaunchArgs),
    /// Manage local and Microsoft accounts.
    Account {
        #[command(subcommand)]
        action: AccountAction,
    },
    /// Discover and install Java runtimes.
    Java {
        #[command(subcommand)]
        action: JavaAction,
    },
    /// Create, list and copy instances.
    Instance {
        #[command(subcommand)]
        action: InstanceAction,
    },
    /// Diagnose an instance crash or launch failure.
    Diagnose {
        #[arg(long)]
        instance: String,
        #[arg(long = "exit-code")]
        exit_code: Option<i32>,
        #[arg(long)]
        markdown: bool,
    },
    /// Install Minecraft and mod loaders.
    Install {
        #[command(subcommand)]
        action: InstallAction,
    },
    /// Search, install and manage mods.
    Mod {
        #[command(subcommand)]
        action: ModAction,
    },
    /// Inspect or install Modrinth modpacks.
    Mrpack {
        #[command(subcommand)]
        action: MrpackAction,
    },
    /// Inspect and update installed modpacks.
    Modpack {
        #[command(subcommand)]
        action: ModpackAction,
    },
    /// Inspect or set up graphics options.
    Graphics {
        #[command(subcommand)]
        action: GraphicsAction,
    },
    /// Search, install and manage shader packs.
    Shader {
        #[command(subcommand)]
        action: PackAction,
    },
    /// Search, install and manage resource packs.
    #[command(alias = "resourcepacks")]
    Resourcepack {
        #[command(subcommand)]
        action: PackAction,
    },
    /// Report performance, benchmark and apply tuning.
    #[command(alias = "perf")]
    Performance {
        #[command(subcommand)]
        action: PerformanceAction,
    },
    /// List, back up and restore worlds.
    World {
        #[command(subcommand)]
        action: WorldAction,
    },
    /// Verify installed version files.
    #[command(disable_version_flag = true)]
    Verify {
        #[arg(long)]
        instance: Option<String>,
        #[arg(long)]
        version: Option<String>,
        #[arg(long)]
        repair: bool,
    },
}

#[derive(Subcommand, Debug)]
enum VersionAction {
    /// Show resolved metadata for one version.
    Inspect {
        #[arg(long)]
        id: String,
        /// Include Java runtime details.
        #[arg(long)]
        java: bool,
    },
    /// List versions from the launcher manifest.
    List {
        #[arg(long = "type", default_value = "release")]
        kind: String,
    },
}

#[derive(Args, Debug)]
struct LaunchArgs {
    /// Identity: local:<name> or microsoft:<uuid|playerName>.
    #[arg(long)]
    identity: Option<String>,
    /// Instance id to launch.
    #[arg(long)]
    instance: Option<String>,
    /// Version id when launching without an instance.
    #[arg(long)]
    version: Option<String>,
    /// Print the resolved command line instead of launching.
    #[arg(long = "dry-run")]
    dry_run: bool,
    /// Java executable override.
    #[arg(long)]
    java: Option<PathBuf>,
}

#[derive(Subcommand, Debug)]
enum AccountAction {
    /// Manage offline local accounts.
    Local {
        #[command(subcommand)]
        action: LocalAccountAction,
    },
    /// Manage Microsoft accounts.
    Microsoft {
        #[command(subcommand)]
        action: MicrosoftAccountAction,
    },
    /// List accounts and mark the active one.
    List,
}

#[derive(Subcommand, Debug)]
enum LocalAccountAction {
    Create {
        #[arg(long)]
        name: String,
    },
    List,
    Delete {
        #[arg(long)]
        name: String,
    },
}

#[derive(Subcommand, Debug)]
enum MicrosoftAccountAction {
    Login,
    Status,
    Logout {
        #[arg(long)]
        id: String,
    },
}

#[derive(Subcommand, Debug)]
enum JavaAction {
    List,
    Install {
        #[arg(long)]
        major: u32,
    },
}

#[derive(Subcommand, Debug)]
enum InstanceAction {
    Create {
        #[arg(long)]
        name: String,
        #[arg(long)]
        version: Option<String>,
        #[arg(long)]
        id: Option<String>,
    },
    List,
    Copy {
        source: String,
        #[arg(long)]
        name: String,
        /// Copy the saves directory as well.
        #[arg(long)]
        saves: bool,
    },
}

#[derive(Subcommand, Debug)]
enum InstallAction {
    Vanilla {
        #[arg(long)]
        version: String,
        #[arg(long)]
        instance: String,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        concurrency: Option<usize>,
    },
    Fabric {
        #[arg(long)]
        version: String,
        #[arg(long)]
        instance: String,
        #[arg(long)]
        loader: Option<String>,
        #[arg(long)]
        name: Option<String>,
        /// Allow updating an existing instance.
        #[arg(long)]
        update: bool,
    },
    Neoforge {
        #[arg(long)]
        version: String,
        #[arg(long)]
        instance: String,
        #[arg(long)]
        loader: String,
        #[arg(long)]
        name: Option<String>,
        /// Allow updating an existing instance.
        #[arg(long)]
        update: bool,
    },
}

#[derive(Subcommand, Debug)]
enum ModAction {
    Search {
        #[arg(long)]
        query: String,
        #[arg(long = "game-version")]
        game_version: Option<String>,
        #[arg(long)]
        loader: Option<String>,
        #[arg(long, default_value_t = 0)]
        offset: u32,
        #[arg(long, default_value_t = 20)]
        limit: u32,
    },
    Install {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        project: String,
        #[arg(long)]
        version: Option<String>,
        #[arg(long = "game-version")]
        game_version: Option<String>,
        #[arg(long)]
        loader: Option<String>,
    },
    List {
        #[arg(long)]
        instance: String,
    },
    Enable {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        project: String,
    },
    Disable {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        project: String,
    },
    Remove {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        project: String,
    },
    Updates {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        apply: bool,
    },
}

#[derive(Subcommand, Debug)]
enum MrpackAction {
    Inspect {
        #[arg(long)]
        file: PathBuf,
    },
    Install {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        name: Option<String>,
    },
}

#[derive(Subcommand, Debug)]
enum ModpackAction {
    Info {
        #[arg(long)]
        instance: String,
    },
    Update {
        #[command(subcommand)]
        action: ModpackUpdateAction,
    },
}

#[derive(Subcommand, Debug)]
enum ModpackUpdateAction {
    Check {
        #[arg(long)]
        instance: String,
    },
    Preview {
        #[arg(long)]
        instance: String,
    },
    Apply {
        #[arg(long)]
        instance: String,
        /// Comma separated instance-relative paths to preserve across the update.
        #[arg(long)]
        preserve: Option<String>,
        #[arg(long)]
        yes: bool,
    },
    Recover {
        #[arg(long)]
        instance: String,
    },
}

#[derive(Subcommand, Debug)]
enum GraphicsAction {
    Status {
        #[arg(long)]
        instance: String,
    },
    Setup {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        replace: bool,
    },
}

#[derive(Subcommand, Debug)]
enum PackAction {
    Search {
        #[arg(long)]
        query: Option<String>,
        #[arg(long)]
        instance: Option<String>,
        #[arg(long, default_value_t = 0)]
        offset: u32,
        #[arg(long, default_value_t = 20)]
        limit: u32,
    },
    Install {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        project: String,
        #[arg(long)]
        version: Option<String>,
    },
    List {
        #[arg(long)]
        instance: String,
    },
    Import {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        file: PathBuf,
    },
    Updates {
        #[arg(long)]
        instance: String,
    },
    Enable {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        file: String,
    },
    Disable {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        file: String,
    },
    Remove {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        file: String,
    },
}

#[derive(Subcommand, Debug)]
enum PerformanceAction {
    Status {
        #[arg(long)]
        instance: String,
    },
    Benchmark {
        #[arg(long)]
        instance: String,
    },
    Tune {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        apply: bool,
    },
    Apply {
        #[arg(long)]
        instance: String,
    },
    Reports {
        #[arg(long)]
        instance: String,
    },
}

#[derive(Subcommand, Debug)]
enum WorldAction {
    List {
        #[arg(long)]
        instance: String,
    },
    Backups {
        #[arg(long)]
        instance: String,
    },
    Backup {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        world: Option<String>,
    },
    Restore {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        backup: String,
        #[arg(long)]
        confirm: bool,
    },
    Delete {
        #[arg(long)]
        instance: String,
        #[arg(long)]
        backup: Option<String>,
        #[arg(long)]
        world: Option<String>,
        #[arg(long)]
        confirm: bool,
    },
}

fn main() {
    let cli = Cli::parse();
    let result = run(cli);
    if let Err(error) = result {
        eprintln!("error: {error}");
        std::process::exit(error.exit_code());
    }
}

fn run(cli: Cli) -> Result<()> {
    let context = context::Context::new(
        cli.root,
        cli.data_root,
        cli.json,
        cli.source.as_deref(),
        cli.mirror_config.as_ref(),
    )?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(Error::Io)?;
    runtime.block_on(commands::dispatch(&context, cli.command))
}
