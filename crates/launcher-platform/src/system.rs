use std::path::Path;

use launcher_core::platform::SystemServices;
use launcher_core::Result;

use crate::quiet_command;

pub struct NativeSystemServices;

impl SystemServices for NativeSystemServices {
    fn open_url(&self, url: &str) -> Result<()> {
        #[cfg(target_os = "macos")]
        let status = quiet_command("open").arg(url).status()?;
        #[cfg(windows)]
        let status = quiet_command("cmd")
            .args(["/C", "start", "", url])
            .status()?;
        #[cfg(all(unix, not(target_os = "macos")))]
        let status = quiet_command("xdg-open").arg(url).status()?;
        if status.success() {
            Ok(())
        } else {
            Err(launcher_core::Error::Other("could not open URL".into()))
        }
    }

    fn reveal_in_file_manager(&self, path: &Path) -> Result<()> {
        #[cfg(target_os = "macos")]
        let status = quiet_command("open").arg("-R").arg(path).status()?;
        #[cfg(windows)]
        let status = quiet_command("explorer")
            .arg(format!("/select,{}", path.display()))
            .status()?;
        #[cfg(all(unix, not(target_os = "macos")))]
        let status = quiet_command("xdg-open")
            .arg(path.parent().unwrap_or(path))
            .status()?;
        if status.success() {
            Ok(())
        } else {
            Err(launcher_core::Error::Other("could not reveal path".into()))
        }
    }

    fn notify(&self, title: &str, body: &str) -> Result<()> {
        #[cfg(target_os = "macos")]
        {
            let script = format!(
                "display notification {} with title {}",
                applescript_string(body),
                applescript_string(title)
            );
            let status = quiet_command("osascript").args(["-e", &script]).status()?;
            if status.success() {
                Ok(())
            } else {
                Err(launcher_core::Error::Other("notification failed".into()))
            }
        }
        #[cfg(windows)]
        {
            let script = format!(
                "[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null; $t=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02); $x=$t.GetElementsByTagName('text'); $x.Item(0).AppendChild($t.CreateTextNode('{}')) > $null; $x.Item(1).AppendChild($t.CreateTextNode('{}')) > $null; [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('LingXi Launcher').Show([Windows.UI.Notifications.ToastNotification]::new($t))",
                title.replace('\'', "''"),
                body.replace('\'', "''")
            );
            let status = quiet_command("powershell")
                .args(["-NoProfile", "-Command", &script])
                .status()?;
            if status.success() {
                Ok(())
            } else {
                Err(launcher_core::Error::Other("notification failed".into()))
            }
        }
        #[cfg(all(unix, not(target_os = "macos")))]
        {
            let _ = quiet_command("notify-send").arg(title).arg(body).status();
            Ok(())
        }
    }
}

#[cfg(target_os = "macos")]
fn applescript_string(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}
