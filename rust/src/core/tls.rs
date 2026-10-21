//! Platform TLS trust-store initialization.

use std::sync::OnceLock;

/// The value chosen on the first call to [`configure`]. ureq caches its root
/// store after the first HTTPS request, so changing this later in the same
/// process would have no effect; the setting is applied once at startup and
/// changes require a restart.
static TRUST_USER_CERTS: OnceLock<bool> = OnceLock::new();

/// Prepares the native certificate store used by TaskChampion's ureq client.
///
/// ureq loads its root certificates through `rustls-native-certs` once, on the
/// first HTTPS request, so this must run before any sync. On Android that crate
/// only knows about the Termux CA bundle, so we hand it a bundle built from
/// Android's own trust store via `SSL_CERT_FILE`.
///
/// `trust_user_certs` controls whether CAs installed through Android Settings
/// are added to the bundle. Only the first call in a process has an effect.
pub(crate) fn configure(trust_user_certs: bool) {
    TRUST_USER_CERTS.get_or_init(|| {
        #[cfg(target_os = "android")]
        android::init(trust_user_certs);
        trust_user_certs
    });
}

/// Applies the default (system CAs only) if the app did not configure TLS.
pub(crate) fn ensure_init() {
    configure(false);
}

#[cfg(target_os = "android")]
mod android {
    use std::os::unix::fs::MetadataExt;
    use std::path::{Path, PathBuf};
    use tracing::{info, warn};

    const SYSTEM_DIRS: &[&str] = &[
        // Android 14+ (Conscrypt APEX)
        "/apex/com.android.conscrypt/cacerts",
        // Android 13 and older
        "/system/etc/security/cacerts",
    ];

    /// Android encodes the user id in the uid: `uid = user_id * 100000 + app_id`.
    const PER_USER_RANGE: u32 = 100_000;

    pub(super) fn init(trust_user_certs: bool) {
        if ["SSL_CERT_FILE", "SSL_CERT_DIR"]
            .iter()
            .any(|var| std::env::var_os(var).is_some_and(|value| !value.is_empty()))
        {
            info!("TLS: using preconfigured SSL_CERT_FILE/SSL_CERT_DIR");
            return;
        }

        let system_dir = SYSTEM_DIRS.iter().map(Path::new).find(|dir| dir.is_dir());

        let Ok(uid) = std::fs::metadata("/proc/self").map(|meta| meta.uid()) else {
            warn!("TLS: cannot determine uid; using system CAs only");
            return set_cert_dir(system_dir);
        };
        let user_id = uid / PER_USER_RANGE;
        let user_dir = PathBuf::from(format!("/data/misc/user/{user_id}"));

        let bundle = super::build_bundle(
            system_dir,
            &user_dir.join("cacerts-added"),
            &user_dir.join("cacerts-removed"),
            trust_user_certs,
        );
        info!(
            system = bundle.system,
            user = bundle.user,
            disabled = bundle.disabled,
            trust_user_certs,
            "TLS: loaded Android trust store"
        );

        if bundle.system + bundle.user == 0 {
            warn!("TLS: no Android CA certificates found; HTTPS sync will fail");
            return;
        }

        match write_bundle(user_id, &bundle.pem) {
            Ok(path) => set_env("SSL_CERT_FILE", &path),
            Err(e) => {
                // ureq trusts nothing if the bundle is unreadable, so fall back
                // to the system store alone to keep public CAs working.
                warn!("TLS: cannot write CA bundle ({e}); using system CAs only");
                set_cert_dir(system_dir);
            }
        }
    }

    /// Writes the bundle into the app's private `no_backup` directory and
    /// confirms it can be read back through the path ureq will use.
    ///
    /// `cache` is avoided because the system may clear it while the app runs,
    /// before the first sync reads the bundle.
    fn write_bundle(user_id: u32, pem: &str) -> std::io::Result<PathBuf> {
        let cmdline = std::fs::read("/proc/self/cmdline")?;
        // The main process is named after the package; secondary processes
        // append `:name`.
        let process = cmdline.split(|&b| b == 0).next().unwrap_or_default();
        let package = String::from_utf8_lossy(process);
        let package = package.split(':').next().unwrap_or_default();
        if package.is_empty() || package.contains('/') {
            return Err(std::io::Error::other(format!(
                "unexpected process name {package:?}"
            )));
        }

        let dir = PathBuf::from(format!("/data/user/{user_id}/{package}/no_backup"));
        std::fs::create_dir_all(&dir)?;
        let path = dir.join("ca-bundle.pem");
        let tmp = dir.join("ca-bundle.pem.tmp");
        std::fs::write(&tmp, pem)?;
        std::fs::rename(&tmp, &path)?;

        if std::fs::read(&path)?.len() != pem.len() {
            return Err(std::io::Error::other("CA bundle read back incomplete"));
        }
        Ok(path)
    }

    fn set_cert_dir(system_dir: Option<&Path>) {
        if let Some(dir) = system_dir {
            set_env("SSL_CERT_DIR", dir);
        }
    }

    fn set_env(var: &str, value: &Path) {
        info!("TLS: {var}={}", value.display());
        // SAFETY: `set_var` is unsound if another thread reads or writes the
        // environment concurrently. The Flutter/Dart threads already running
        // in this process do not touch it, and the first call to `configure`
        // runs before any HTTPS request can make ureq read it.
        unsafe {
            std::env::set_var(var, value);
        }
    }
}

/// A PEM bundle assembled from Android's certificate directories.
#[cfg(any(target_os = "android", test))]
#[derive(Debug, Default)]
struct Bundle {
    pem: String,
    system: usize,
    user: usize,
    disabled: usize,
}

/// Merges the system CAs (minus those the user disabled) with user-installed
/// CAs when `include_user_certs` is set, matching how Android's
/// `TrustedCertificateStore` resolves trust.
///
/// Missing or unreadable directories and files are skipped so one bad entry
/// cannot empty the whole store.
#[cfg(any(target_os = "android", test))]
fn build_bundle(
    system_dir: Option<&std::path::Path>,
    added_dir: &std::path::Path,
    removed_dir: &std::path::Path,
    include_user_certs: bool,
) -> Bundle {
    use tracing::warn;

    let mut bundle = Bundle::default();

    if let Some(system_dir) = system_dir {
        for path in cert_files(system_dir) {
            // Android marks a system CA as disabled by placing a file with the
            // same name in `cacerts-removed`.
            if path
                .file_name()
                .is_some_and(|name| removed_dir.join(name).exists())
            {
                bundle.disabled += 1;
                continue;
            }
            if append_cert(&mut bundle.pem, &path) {
                bundle.system += 1;
            }
        }
    }

    if include_user_certs {
        for path in cert_files(added_dir) {
            if append_cert(&mut bundle.pem, &path) {
                bundle.user += 1;
            }
        }
    }

    if bundle.system == 0 && system_dir.is_some() {
        warn!("TLS: no system CA certificates could be read");
    }
    bundle
}

/// Lists the `HHHHHHHH.N` certificate files in `dir`, or nothing if it is unreadable.
#[cfg(any(target_os = "android", test))]
fn cert_files(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<_> = entries
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(is_hash_file_name)
        })
        .collect();
    files.sort();
    files
}

/// Matches OpenSSL's `c_rehash` naming, which Android also uses: 8 hex digits, `.`, a digit.
#[cfg(any(target_os = "android", test))]
fn is_hash_file_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    bytes.len() == 10
        && bytes[..8].iter().all(u8::is_ascii_hexdigit)
        && bytes[8] == b'.'
        && bytes[9].is_ascii_digit()
}

/// Appends the certificate at `path` to `pem`, converting DER to PEM.
///
/// System CAs are stored as PEM (followed by a text dump, which PEM parsers
/// skip); user-installed CAs are stored as raw DER.
#[cfg(any(target_os = "android", test))]
fn append_cert(pem: &mut String, path: &std::path::Path) -> bool {
    use base64::Engine;

    let bytes = match std::fs::read(path) {
        Ok(bytes) if !bytes.is_empty() => bytes,
        Ok(_) => return false,
        Err(e) => {
            tracing::warn!("TLS: skipping {}: {e}", path.display());
            return false;
        }
    };

    if bytes.starts_with(b"-----BEGIN") {
        pem.push_str(&String::from_utf8_lossy(&bytes));
    } else {
        let encoded = base64::engine::general_purpose::STANDARD.encode(&bytes);
        pem.push_str("-----BEGIN CERTIFICATE-----\n");
        for line in encoded.as_bytes().chunks(64) {
            // base64 output is ASCII
            pem.push_str(std::str::from_utf8(line).unwrap_or_default());
            pem.push('\n');
        }
        pem.push_str("-----END CERTIFICATE-----");
    }
    if !pem.ends_with('\n') {
        pem.push('\n');
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "taskdroid-tls-{label}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn dir(&self, name: &str) -> PathBuf {
            let dir = self.0.join(name);
            fs::create_dir_all(&dir).unwrap();
            dir
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    const PEM_A: &str = "-----BEGIN CERTIFICATE-----\nQUFBQQ==\n-----END CERTIFICATE-----\nCertificate:\n    Data: ...\n";
    const PEM_B: &str = "-----BEGIN CERTIFICATE-----\nQkJCQg==\n-----END CERTIFICATE-----";

    #[test]
    fn hash_file_names() {
        assert!(is_hash_file_name("01419da9.0"));
        assert!(is_hash_file_name("ABCDEF00.9"));
        assert!(!is_hash_file_name("01419da9.a"));
        assert!(!is_hash_file_name("01419da9"));
        assert!(!is_hash_file_name("cert.pem"));
        assert!(!is_hash_file_name("01419da9.10"));
    }

    #[test]
    fn merges_system_and_user_certs() {
        let tmp = TempDir::new("merge");
        let system = tmp.dir("system");
        let added = tmp.dir("added");
        fs::write(system.join("aaaaaaaa.0"), PEM_A).unwrap();
        fs::write(system.join("bbbbbbbb.0"), PEM_B).unwrap();
        fs::write(system.join("README"), "not a cert").unwrap();
        fs::write(added.join("cccccccc.0"), [0x30, 0x82, 0x01, 0x02]).unwrap();

        let bundle = build_bundle(Some(&system), &added, &tmp.0.join("missing"), true);

        assert_eq!((bundle.system, bundle.user, bundle.disabled), (2, 1, 0));
        assert!(bundle.pem.contains("QUFBQQ=="));
        assert!(bundle.pem.contains("QkJCQg=="));
        // DER is wrapped as PEM
        assert!(
            bundle
                .pem
                .contains("-----BEGIN CERTIFICATE-----\nMIIBAg==\n-----END CERTIFICATE-----\n")
        );
        assert!(!bundle.pem.contains("not a cert"));
        assert_eq!(bundle.pem.matches("-----BEGIN CERTIFICATE-----").count(), 3);
    }

    #[test]
    fn skips_disabled_system_certs() {
        let tmp = TempDir::new("disabled");
        let system = tmp.dir("system");
        let removed = tmp.dir("removed");
        fs::write(system.join("aaaaaaaa.0"), PEM_A).unwrap();
        fs::write(system.join("bbbbbbbb.0"), PEM_B).unwrap();
        fs::write(removed.join("aaaaaaaa.0"), PEM_A).unwrap();

        let bundle = build_bundle(Some(&system), &tmp.0.join("missing"), &removed, false);

        assert_eq!((bundle.system, bundle.user, bundle.disabled), (1, 0, 1));
        assert!(!bundle.pem.contains("QUFBQQ=="));
        assert!(bundle.pem.contains("QkJCQg=="));
    }

    #[test]
    fn excludes_user_certs_when_disabled() {
        let tmp = TempDir::new("system-only");
        let system = tmp.dir("system");
        let added = tmp.dir("added");
        fs::write(system.join("aaaaaaaa.0"), PEM_A).unwrap();
        fs::write(added.join("cccccccc.0"), PEM_B).unwrap();

        let bundle = build_bundle(Some(&system), &added, &tmp.0.join("missing"), false);

        assert_eq!((bundle.system, bundle.user), (1, 0));
        assert!(bundle.pem.contains("QUFBQQ=="));
        assert!(!bundle.pem.contains("QkJCQg=="));
    }

    #[test]
    fn tolerates_missing_and_bad_entries() {
        let tmp = TempDir::new("bad");
        let system = tmp.dir("system");
        fs::write(system.join("aaaaaaaa.0"), PEM_A).unwrap();
        fs::write(system.join("bbbbbbbb.0"), "").unwrap();
        // a directory with a cert-like name must not abort the scan
        tmp.dir("system/cccccccc.0");

        let bundle = build_bundle(Some(&system), &tmp.0.join("x"), &tmp.0.join("y"), true);
        assert_eq!((bundle.system, bundle.user), (1, 0));

        let empty = build_bundle(None, &tmp.0.join("x"), &tmp.0.join("y"), true);
        assert_eq!((empty.system, empty.user), (0, 0));
        assert!(empty.pem.is_empty());
    }
}
