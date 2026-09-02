//! Runs the packaged Omarchy plugin's QML tests through Qt 6's `qmltestrunner`.
//!
//! The runner is part of `qt6-declarative`, which QuickShell already requires,
//! so an absent runner is a broken development environment and fails the test
//! instead of skipping it.

use std::error::Error;
use std::path::{Path, PathBuf};
use std::process::Command;

const PLUGIN: &str = "packaging/omarchy/plugins/local.omabox";

fn plugin() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(PLUGIN)
}

/// Locate Qt 6's own `qmltestrunner`.
///
/// Qt is asked where it installed its tools rather than searching `PATH`:
/// distributions put Qt 5's `qmltestrunner` in `/usr/bin` and Qt 6's under the
/// Qt 6 prefix, and Qt 5 cannot load the plugin's versionless imports.
fn runner() -> Result<PathBuf, Box<dyn Error>> {
    let query = Command::new("qmake6")
        .args(["-query", "QT_INSTALL_BINS"])
        .output()
        .map_err(|source| {
            format!("could not run `qmake6`, so Qt 6 is missing: {source}. Install qt6-base.")
        })?;
    if !query.status.success() {
        return Err(format!(
            "`qmake6 -query QT_INSTALL_BINS` failed with status {:?}",
            query.status.code()
        )
        .into());
    }
    let bins = String::from_utf8(query.stdout)?;
    let runner = Path::new(bins.trim()).join("qmltestrunner");
    if !runner.is_file() {
        return Err(format!(
            "{} is missing. Install qt6-declarative to run the QML widget tests.",
            runner.display()
        )
        .into());
    }
    Ok(runner)
}

/// Every `tst_*.qml` case the plugin ships, in a stable order.
///
/// The directory is read instead of naming one file so a case added later
/// cannot sit there unrun, which is how these tests were lost before.
fn cases(directory: &Path) -> Result<Vec<PathBuf>, Box<dyn Error>> {
    let mut cases = Vec::new();
    for entry in std::fs::read_dir(directory)? {
        let path = entry?.path();
        let named = path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("tst_") && name.ends_with(".qml"));
        if named {
            cases.push(path);
        }
    }
    cases.sort();
    if cases.is_empty() {
        return Err(format!("{} declares no QML test cases", directory.display()).into());
    }
    Ok(cases)
}

/// Return the names of every `test_*` function declared by a QML test case.
fn declared(source: &str) -> Vec<&str> {
    source
        .lines()
        .filter_map(|line| line.trim_start().strip_prefix("function "))
        .filter_map(|rest| rest.split('(').next())
        .filter(|name| name.starts_with("test_"))
        .collect()
}

#[test]
fn packaged_widget_qml_tests_pass() -> Result<(), Box<dyn Error>> {
    let plugin = plugin();
    let runner = runner()?;
    for case in cases(&plugin.join("tests"))? {
        let source = std::fs::read_to_string(&case)?;
        let declared = declared(&source);
        if declared.is_empty() {
            return Err(format!("{} declares no test functions", case.display()).into());
        }

        let output = Command::new(&runner)
            .arg("-import")
            .arg(plugin.join("tests/mocks"))
            .arg("-input")
            .arg(&case)
            .args(["-o", "-,tap"])
            // Keep the run headless, and keep Qt's diagnostics on stderr instead
            // of the journal, which is where they go when stderr is not a
            // terminal.
            .env("QT_QPA_PLATFORM", "offscreen")
            .env("QT_FORCE_STDERR_LOGGING", "1")
            .output()?;
        let tap = String::from_utf8_lossy(&output.stdout);
        let diagnostics = String::from_utf8_lossy(&output.stderr);
        let report = format!(
            "{} exited {:?}\n{tap}{diagnostics}",
            case.display(),
            output.status.code()
        );

        for name in declared {
            let ended = format!("::{name}()");
            let passed = tap
                .lines()
                .any(|line| line.starts_with("ok ") && line.ends_with(&ended));
            assert!(passed, "QML test {name} did not pass:\n{report}");
        }
        assert!(
            tap.lines().any(|line| line.trim() == "# fail 0"),
            "QML tests reported failures:\n{report}"
        );
        assert!(output.status.success(), "qmltestrunner failed:\n{report}");
    }
    Ok(())
}
