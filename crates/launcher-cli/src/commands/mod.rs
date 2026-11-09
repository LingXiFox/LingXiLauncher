pub mod accounts;
pub mod install;
pub mod instances;
pub mod launch;
pub mod modpacks;
pub mod mods;
pub mod packs;
pub mod system;
pub mod tools;
pub mod worlds;

use launcher_core::Result;

use crate::context::Context;
use crate::Command;

pub async fn dispatch(context: &Context, command: Command) -> Result<()> {
    match command {
        Command::Version { action } => system::version(context, action).await,
        Command::Doctor { java, version } => {
            system::doctor(context, &system::DoctorArgs { java, version }).await
        }
        Command::Launch(args) => launch::launch(context, &args).await,
        Command::Account { action } => accounts::account(context, action).await,
        Command::Java { action } => system::java(context, action).await,
        Command::Instance { action } => instances::instance(context, action),
        Command::Diagnose {
            instance,
            exit_code,
            markdown,
        } => tools::diagnose(context, &instance, exit_code, markdown),
        Command::Install { action } => install::install(context, action).await,
        Command::Mod { action } => mods::mods(context, action).await,
        Command::Mrpack { action } => modpacks::mrpack(context, action).await,
        Command::Modpack { action } => modpacks::modpack(context, action).await,
        Command::Graphics { action } => tools::graphics(context, action).await,
        Command::Shader { action } => packs::shader(context, action).await,
        Command::Resourcepack { action } => packs::resourcepack(context, action).await,
        Command::Performance { action } => tools::performance(context, action),
        Command::World { action } => worlds::world(context, action),
        Command::Verify {
            instance,
            version,
            repair,
        } => {
            system::verify(
                context,
                &system::VerifyArgs {
                    instance,
                    version,
                    repair,
                },
            )
            .await
        }
    }
}
