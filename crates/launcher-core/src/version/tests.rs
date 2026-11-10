//! Version inheritance and argument resolution regression tests.
//!
//! These exercise the real on-disk chain loader: every fixture is written to a
//! temporary game root so the inheritsFrom traversal, library de-duplication
//! and argument merging run exactly as they do in production.

use std::path::{Path, PathBuf};

use serde_json::json;

use super::*;

fn temp_root(label: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "lingxi-version-{label}-{}",
        uuid::Uuid::new_v4().simple()
    ));
    std::fs::create_dir_all(root.join("versions")).unwrap();
    root
}

fn write_version(root: &Path, id: &str, document: serde_json::Value) {
    let directory = root.join("versions").join(id);
    std::fs::create_dir_all(&directory).unwrap();
    std::fs::write(
        directory.join(format!("{id}.json")),
        serde_json::to_vec_pretty(&document).unwrap(),
    )
    .unwrap();
}

fn vanilla(id: &str) -> serde_json::Value {
    json!({
        "id": id,
        "type": "release",
        "mainClass": "net.minecraft.client.main.Main",
        "assets": "17",
        "assetIndex": { "id": "17", "url": "https://example.invalid/17.json" },
        "javaVersion": { "component": "java-runtime-delta", "majorVersion": 21 },
        "releaseTime": "2026-10-01T00:00:00Z",
        "libraries": [
            { "name": "com.mojang:authlib:6.0.54" },
            { "name": "org.lwjgl:lwjgl:3.3.3" }
        ],
        "arguments": {
            "jvm": [
                { "rules": [], "value": ["-Djava.library.path=${natives_directory}"] }
            ],
            "game": [
                { "rules": [], "value": ["--username", "${auth_player_name}"] },
                { "rules": [], "value": ["--version", "${version_name}"] }
            ]
        },
        "downloads": {
            "client": { "url": "https://example.invalid/client.jar", "size": 1234 }
        }
    })
}

#[test]
fn inheritance_merges_libraries_and_arguments() {
    let root = temp_root("merge");
    write_version(&root, "1.21.11", vanilla("1.21.11"));
    write_version(
        &root,
        "fabric-loader-0.20.1-1.21.11",
        json!({
            "id": "fabric-loader-0.20.1-1.21.11",
            "inheritsFrom": "1.21.11",
            "mainClass": "net.fabricmc.loader.impl.launch.knot.KnotClient",
            "libraries": [
                { "name": "org.lwjgl:lwjgl:3.3.3" },
                { "name": "net.fabricmc:fabric-loader:0.20.1" }
            ],
            "arguments": {
                "jvm": [],
                "game": [{ "rules": [], "value": ["--fabric"] }]
            }
        }),
    );

    let resolved = VersionResolver
        .resolve("fabric-loader-0.20.1-1.21.11", &root)
        .unwrap();

    assert_eq!(
        resolved.main_class,
        "net.fabricmc.loader.impl.launch.knot.KnotClient"
    );
    assert_eq!(resolved.inherits_from.as_deref(), Some("1.21.11"));
    assert_eq!(resolved.asset_index_id, "17");
    assert_eq!(resolved.java_requirement.major_version, Some(21));
    assert_eq!(resolved.compatibility, VersionCompatibility::Modern);

    let names: Vec<&str> = resolved
        .libraries
        .iter()
        .map(|library| library.name.as_str())
        .collect();
    assert_eq!(
        names.len(),
        3,
        "duplicate lwjgl entry must collapse: {names:?}"
    );
    assert_eq!(
        names
            .iter()
            .filter(|name| **name == "org.lwjgl:lwjgl:3.3.3")
            .count(),
        1
    );
    assert!(names.contains(&"com.mojang:authlib:6.0.54"));
    assert!(names.contains(&"net.fabricmc:fabric-loader:0.20.1"));

    // Parent arguments stay first so loader flags appended by the child win.
    assert_eq!(resolved.game_arguments.len(), 3);
    // Argument objects keep their value list intact, so a single entry may carry
    // several tokens; the parent entry still comes before the loader one.
    match &resolved.game_arguments[0] {
        ArgumentEntry::Conditional { rules, values } => {
            assert!(rules.is_empty());
            assert_eq!(
                values,
                &vec!["--username".to_string(), "${auth_player_name}".to_string()]
            );
        }
        other => panic!("expected a conditional argument, got {other:?}"),
    }
    assert_eq!(
        resolved.game_arguments.last().unwrap(),
        &ArgumentEntry::Conditional {
            rules: Vec::new(),
            values: vec!["--fabric".to_string()],
        }
    );
    assert_eq!(resolved.jvm_arguments.len(), 1);
    assert!(resolved.client_jar.is_some());
    assert_eq!(resolved.client_jar_version_id, "1.21.11");
    assert_eq!(resolved.natives_version_id, "1.21.11");
    assert!(resolved.release_time.is_some());

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn java_requirement_takes_the_highest_major() {
    let root = temp_root("java");
    let mut parent = vanilla("1.21.11");
    parent["javaVersion"] = json!({ "component": "jre-legacy", "majorVersion": 8 });
    write_version(&root, "1.21.11", parent);
    write_version(
        &root,
        "modern-loader",
        json!({
            "id": "modern-loader",
            "inheritsFrom": "1.21.11",
            "javaVersion": { "component": "java-runtime-delta", "majorVersion": 21 }
        }),
    );
    write_version(
        &root,
        "legacy-loader",
        json!({
            "id": "legacy-loader",
            "inheritsFrom": "1.21.11",
            "javaVersion": { "component": "java-runtime-gamma", "majorVersion": 17 }
        }),
    );

    let modern = VersionResolver.resolve("modern-loader", &root).unwrap();
    assert_eq!(modern.java_requirement.major_version, Some(21));
    assert_eq!(
        modern.java_requirement.component.as_deref(),
        Some("java-runtime-delta")
    );
    assert!(modern.requires_java(17));
    assert!(!modern.requires_java(21));

    let legacy = VersionResolver.resolve("legacy-loader", &root).unwrap();
    assert_eq!(legacy.java_requirement.major_version, Some(17));
    assert!(legacy.requires_java(8));
    assert!(!legacy.requires_java(17));

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn circular_inheritance_is_rejected() {
    let root = temp_root("cycle");
    write_version(
        &root,
        "a",
        json!({ "id": "a", "inheritsFrom": "b", "mainClass": "A" }),
    );
    write_version(
        &root,
        "b",
        json!({ "id": "b", "inheritsFrom": "a", "mainClass": "B" }),
    );

    let error = VersionResolver.resolve("a", &root).unwrap_err();
    let message = error.to_string();
    assert!(
        message.contains("circular version inheritance"),
        "unexpected error: {message}"
    );
    assert!(
        message.contains("a -> b -> a"),
        "unexpected error: {message}"
    );

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn missing_parent_is_reported() {
    let root = temp_root("missing");
    write_version(
        &root,
        "orphan",
        json!({ "id": "orphan", "inheritsFrom": "ghost", "mainClass": "A" }),
    );

    let error = VersionResolver.resolve("orphan", &root).unwrap_err();
    let message = error.to_string();
    assert!(message.contains("ghost"), "unexpected error: {message}");

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn mismatched_json_id_is_rejected() {
    let root = temp_root("mismatch");
    write_version(
        &root,
        "1.21.11",
        json!({ "id": "1.20.1", "mainClass": "net.minecraft.client.main.Main" }),
    );

    let error = VersionResolver.resolve("1.21.11", &root).unwrap_err();
    let message = error.to_string();
    assert!(
        message.contains("does not match directory"),
        "unexpected error: {message}"
    );

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn legacy_minecraft_arguments_fall_back() {
    let root = temp_root("legacy");
    write_version(
        &root,
        "1.7.10",
        json!({
            "id": "1.7.10",
            "mainClass": "net.minecraft.client.main.Main",
            "assets": "legacy",
            "minecraftArguments": "--username ${auth_player_name} --gameDir ${game_directory} --assetsDir ${assets_root} --uuid ${auth_uuid}"
        }),
    );

    let resolved = VersionResolver.resolve("1.7.10", &root).unwrap();
    assert_eq!(
        resolved.compatibility,
        VersionCompatibility::LegacyArguments
    );
    assert_eq!(resolved.game_arguments.len(), 8);
    assert_eq!(
        resolved.game_arguments[0],
        ArgumentEntry::Plain("--username".into())
    );
    assert_eq!(resolved.jvm_arguments, legacy_jvm_arguments());
    assert_eq!(resolved.asset_index_id, "legacy");

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn quoted_legacy_arguments_are_tokenized() {
    assert_eq!(
        parse_legacy_arguments(r#"--title "Hello World" --flag 'a b' --path "/tmp/x y""#),
        vec![
            ArgumentEntry::Plain("--title".into()),
            ArgumentEntry::Plain("Hello World".into()),
            ArgumentEntry::Plain("--flag".into()),
            ArgumentEntry::Plain("a b".into()),
            ArgumentEntry::Plain("--path".into()),
            ArgumentEntry::Plain("/tmp/x y".into()),
        ]
    );
}

#[test]
fn resolve_metadata_requires_a_parent_chain() {
    let metadata: VersionMetadata = serde_json::from_value(json!({
        "id": "fabric-loader-0.20.1-1.21.11",
        "inheritsFrom": "1.21.11",
        "mainClass": "net.fabricmc.loader.impl.launch.knot.KnotClient"
    }))
    .unwrap();

    let error = VersionResolver
        .resolve_metadata(
            metadata,
            "fabric-loader-0.20.1-1.21.11",
            PathBuf::from("/tmp/nowhere"),
            PathBuf::from("/tmp/nowhere/version.json"),
        )
        .unwrap_err();
    let message = error.to_string();
    assert!(
        message.contains("no parent chain was supplied"),
        "unexpected error: {message}"
    );
}

#[test]
fn resolve_metadata_rejects_id_mismatch() {
    let metadata: VersionMetadata = serde_json::from_value(json!({
        "id": "other",
        "mainClass": "net.minecraft.client.main.Main",
        "assets": "17"
    }))
    .unwrap();

    let error = VersionResolver
        .resolve_metadata(
            metadata,
            "1.21.11",
            PathBuf::from("/tmp/nowhere"),
            PathBuf::from("/tmp/nowhere/version.json"),
        )
        .unwrap_err();
    assert!(error
        .to_string()
        .contains("does not match requested version"));
}

#[test]
fn empty_game_arguments_are_rejected() {
    let root = temp_root("noargs");
    write_version(
        &root,
        "broken",
        json!({
            "id": "broken",
            "mainClass": "net.minecraft.client.main.Main",
            "assets": "17",
            "arguments": { "jvm": [], "game": [] }
        }),
    );

    let error = VersionResolver.resolve("broken", &root).unwrap_err();
    assert!(error.to_string().contains("no game arguments"));

    std::fs::remove_dir_all(&root).ok();
}
