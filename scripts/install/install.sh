#!/bin/sh

set -eu

VERSION="${1:-latest}"
REPOSITORY="${CODEX_INSTALL_REPOSITORY:-SDGLBL/codex}"
RELEASE_TAG_PREFIX="${CODEX_INSTALL_RELEASE_TAG_PREFIX:-internal-rust-v}"
RELEASE_TAG_OVERRIDE="${CODEX_INSTALL_RELEASE_TAG:-}"
RELEASE_BASE_URL="${CODEX_INSTALL_RELEASE_BASE_URL:-https://github.com/$REPOSITORY/releases/download}"
LATEST_RELEASE_URL="${CODEX_INSTALL_LATEST_RELEASE_URL:-https://api.github.com/repos/$REPOSITORY/releases/latest}"
LATEST_INSTALL_URL="${CODEX_INSTALL_LATEST_INSTALL_URL:-https://github.com/$REPOSITORY/releases/latest/download/install.sh}"
INSTALL_DIR=""
INSTALL_AK=""
INSTALL_AZURE_BASE_URL=""
INSTALL_MODEL="${CODEX_INSTALL_MODEL:-}"
SHOULD_BOOTSTRAP_INTERNAL_PROFILE="true"
path_action="already"
path_profile=""

step() {
  printf '==> %s\n' "$1"
}

normalize_version() {
  case "$1" in
    "" | latest)
      printf 'latest\n'
      ;;
    internal-rust-v*)
      printf '%s\n' "${1#internal-rust-v}"
      ;;
    rust-v*)
      printf '%s\n' "${1#rust-v}"
      ;;
    v*)
      printf '%s\n' "${1#v}"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

download_file() {
  url="$1"
  output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$output" "$url"
    return
  fi

  echo "curl or wget is required to install Codex." >&2
  exit 1
}

download_text() {
  url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -O - "$url"
    return
  fi

  echo "curl or wget is required to install Codex." >&2
  exit 1
}

tag_name_for_version() {
  printf '%s%s\n' "$RELEASE_TAG_PREFIX" "$1"
}

resolve_version_from_latest_install_url() {
  if command -v curl >/dev/null 2>&1; then
    redirect_tag="$(curl -fsSL -D - -o /dev/null "$LATEST_INSTALL_URL" 2>/dev/null | sed -n 's/^[Ll]ocation: .*\/releases\/download\/\(\(internal-\)\{0,1\}rust-v[^/]*\)\/install\.sh.*/\1/p' | head -n 1 | tr -d '\r')"
    if [ -n "$redirect_tag" ]; then
      printf '%s\n' "$(normalize_version "$redirect_tag")"
      return 0
    fi

    effective_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$LATEST_INSTALL_URL" 2>/dev/null || true)"
  elif command -v wget >/dev/null 2>&1; then
    redirect_tag="$(wget -q -O /dev/null --server-response "$LATEST_INSTALL_URL" 2>&1 | sed -n 's/^[[:space:]]*[Ll]ocation: .*\/releases\/download\/\(\(internal-\)\{0,1\}rust-v[^/]*\)\/install\.sh.*/\1/p' | head -n 1 | tr -d '\r')"
    if [ -n "$redirect_tag" ]; then
      printf '%s\n' "$(normalize_version "$redirect_tag")"
      return 0
    fi

release_asset_digest_or_empty() {
  asset="$1"
  resolved_version="$2"
  release_json="$(download_text "$(release_metadata_url "$resolved_version")")"

  digest="$(printf '%s\n' "$release_json" | awk -v asset="$asset" '
    /"name":[[:space:]]*"[^"]+"/ {
      name = $0
      sub(/^.*"name":[[:space:]]*"/, "", name)
      sub(/".*$/, "", name)
      if (name == asset) {
        in_asset = 1
        asset_depth = depth
      }
    }

    in_asset && /"digest":[[:space:]]*"[^"]+"/ {
      digest = $0
      sub(/^.*"digest":[[:space:]]*"/, "", digest)
      sub(/".*$/, "", digest)
    }

    {
      line = $0
      opens = gsub(/\{/, "{", line)
      closes = gsub(/\}/, "}", line)
      depth += opens - closes

      if (in_asset && depth < asset_depth) {
        in_asset = 0
      }
    }

    END {
      if (digest != "") {
        print digest
      }
    }
  ')"

  case "$digest" in
    sha256:????????????????????????????????????????????????????????????????)
      printf '%s\n' "${digest#sha256:}"
      ;;
    *)
      return 1
      ;;
  esac

release_asset_exists() {
  asset="$1"
  resolved_version="$2"

  release_asset_digest_or_empty "$asset" "$resolved_version" >/dev/null 2>&1
}

release_asset_digest() {
  asset="$1"
  resolved_version="$2"

  digest="$(release_asset_digest_or_empty "$asset" "$resolved_version" || true)"
  if [ -z "$digest" ]; then
    echo "Could not find SHA-256 digest for release asset $asset." >&2
    exit 1
  fi

  printf '%s\n' "$digest"
}

package_archive_digest() {
  asset="$1"
  manifest_path="$2"

  digest="$(awk -v asset="$asset" '
    $2 == asset && $1 ~ /^[0-9a-fA-F]{64}$/ {
      print tolower($1)
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$manifest_path" 2>/dev/null || true)"

  if [ -z "$digest" ]; then
    echo "Could not find SHA-256 digest for $asset in codex-package_SHA256SUMS." >&2
    exit 1
  fi

  printf '%s\n' "$digest"
}

file_sha256() {
  path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | sed 's/^.*= //'
    return
  fi

  echo "sha256sum, shasum, or openssl is required to verify the Codex download." >&2
  exit 1
}

verify_archive_digest() {
  archive_path="$1"
  expected_digest="$2"
  actual_digest="$(file_sha256 "$archive_path")"

  if [ "$actual_digest" != "$expected_digest" ]; then
    echo "Downloaded Codex archive checksum did not match expected digest." >&2
    echo "expected: $expected_digest" >&2
    echo "actual:   $actual_digest" >&2
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required to install Codex." >&2
    exit 1
  fi
}

require_command dirname
require_command mktemp
require_command tar

resolve_version() {
  normalized_version="$(normalize_version "$VERSION")"

  if [ "$normalized_version" != "latest" ]; then
    printf '%s\n' "$normalized_version"
    return
  fi

  release_json="$(download_text "$LATEST_RELEASE_URL" 2>/dev/null || true)"
  resolved_tag="$(printf '%s\n' "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\(\(internal-\)\{0,1\}rust-v[^"]*\)".*/\1/p' | head -n 1)"
  resolved=""
  if [ -n "$resolved_tag" ]; then
    resolved="$(normalize_version "$resolved_tag")"
  fi

  if [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
    return
  fi

  resolved="$(resolve_version_from_latest_install_url || true)"

  if [ -z "$resolved" ]; then
    echo "Failed to resolve the latest Codex release version." >&2
    exit 1
  fi

  printf '%s\n' "$resolved"
}

release_url_for_asset() {
  asset="$1"
  resolved_tag="$2"

  printf '%s/%s/%s\n' "${RELEASE_BASE_URL%/}" "$resolved_tag" "$asset"
}

resolve_release_tag() {
  if [ -n "$RELEASE_TAG_OVERRIDE" ]; then
    printf '%s\n' "$RELEASE_TAG_OVERRIDE"
    return
  fi

  case "$VERSION" in
    internal-*)
      printf '%s\n' "$VERSION"
      return
      ;;
  esac

  resolved_version="$(resolve_version)"
  tag_name_for_version "$resolved_version"
}

can_write_dir() {
  dir="$1"
  probe="$dir"

  while [ ! -e "$probe" ]; do
    parent="$(dirname "$probe")"
    if [ "$parent" = "$probe" ]; then
      break
    fi
    probe="$parent"
  done

  [ -d "$probe" ] && [ -w "$probe" ]
}

can_write_path() {
  path="$1"

  if [ -e "$path" ]; then
    [ -w "$path" ]
    return
  fi

  can_write_dir "$(dirname "$path")"
}

resolve_install_dir() {
  if [ -n "${CODEX_INSTALL_DIR:-}" ]; then
    printf '%s\n' "$CODEX_INSTALL_DIR"
    return
  fi

  existing_codex="$(command -v codex 2>/dev/null || true)"
  if [ -n "$existing_codex" ] && [ -f "$existing_codex" ]; then
    existing_dir="$(dirname "$existing_codex")"
    if can_write_dir "$existing_dir"; then
      printf '%s\n' "$existing_dir"
      return
    fi
  fi

  for candidate in "$HOME/.local/bin" "$HOME/bin"; do
    if can_write_dir "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  printf '%s\n' "$HOME/.local/bin"
}

add_to_path() {
  path_action="already"
  path_profile=""

  case ":$PATH:" in
    *":$INSTALL_DIR:"*)
      return
      ;;
  esac

  path_line="export PATH=\"$INSTALL_DIR:\$PATH\""
  set -- "$HOME/.profile"
  case "${SHELL:-}" in
    */zsh)
      set -- "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.profile"
      ;;
    */bash)
      set -- "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"
      ;;
  esac

  for candidate in "$@"; do
    if [ -f "$candidate" ] && grep -F "$path_line" "$candidate" >/dev/null 2>&1; then
      path_profile="$candidate"
      path_action="configured"
      return
    fi
  done

  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  date +%s >"$LOCK_DIR/started_at" 2>/dev/null || true
  lock_kind="mkdir"
}

release_install_lock() {
  if [ "$lock_kind" = "mkdir" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  elif [ "$lock_kind" = "flock" ] || [ "$lock_kind" = "lockf" ]; then
    exec 9>&- 2>/dev/null || true
  fi
  lock_kind=""
}

cleanup_stale_install_artifacts() {
  mkdir -p "$RELEASES_DIR" "$STANDALONE_ROOT"

  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -name '.staging.*' -exec rm -rf {} +
  find "$STANDALONE_ROOT" -mindepth 1 -maxdepth 1 -name '.current.*' -exec rm -f {} +

  if [ -d "$BIN_DIR" ]; then
    find "$BIN_DIR" -mindepth 1 -maxdepth 1 -name '.codex.*' -exec rm -f {} +
  fi
}

replace_path_with_symlink() {
  link_path="$1"
  link_target="$2"
  tmp_link="$3"

  rm -f "$tmp_link"
  ln -s "$link_target" "$tmp_link"

  if mv -Tf "$tmp_link" "$link_path" 2>/dev/null; then
    return
  fi

  if mv -hf "$tmp_link" "$link_path" 2>/dev/null; then
    return
  fi

  rm -f "$link_path"
  mv -f "$tmp_link" "$link_path"
}

version_from_binary() {
  codex_path="$1"

  if [ ! -x "$codex_path" ]; then
    return 1
  fi

  "$codex_path" --version 2>/dev/null | sed -n 's/.* \([0-9][0-9A-Za-z.+-]*\)$/\1/p' | head -n 1
}

current_installed_version() {
  version="$(version_from_binary "$CURRENT_LINK/bin/codex" || true)"
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
    return 0
  fi

  version="$(version_from_binary "$CURRENT_LINK/codex" || true)"
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
    return 0
  fi

  return 0
}

resolve_existing_codex() {
  command -v codex 2>/dev/null || true
}

classify_existing_codex() {
  existing_path="$1"

  if [ -z "$existing_path" ] || [ "$existing_path" = "$BIN_PATH" ]; then
    return 1
  fi

  case "$existing_path" in
    /opt/homebrew/* | /usr/local/*)
      if [ "$os" = "darwin" ]; then
        printf 'brew\n'
        return 0
      fi
      return
    fi
  done

  path_action="manual"
}

warn_if_crawl_url() {
  case "$1" in
    */v2/crawl|*/v2/crawl/)
      echo "Warning: CODEX_INSTALL_AZURE_BASE_URL ends with /v2/crawl. GPT models use the responses API, so this should point at the openapi base URL, not /v2/crawl." >&2
      ;;
  esac
}

prompt_for_install_config() {
  has_internal_profile="false"
  config_path="$HOME/.codex/config.toml"
  if [ -f "$config_path" ] && grep -Eq '^[[:space:]]*\[profiles\.internal\][[:space:]]*$' "$config_path"; then
    has_internal_profile="true"
  fi

  if [ -n "${CODEX_INSTALL_AK:-}" ]; then
    INSTALL_AK="$CODEX_INSTALL_AK"
  fi
  if [ -n "${CODEX_INSTALL_AZURE_BASE_URL:-}" ]; then
    INSTALL_AZURE_BASE_URL="$CODEX_INSTALL_AZURE_BASE_URL"
  fi

  has_bootstrap_overrides="false"
  if [ -n "$INSTALL_AK" ] || [ -n "$INSTALL_AZURE_BASE_URL" ] || [ -n "$INSTALL_MODEL" ]; then
    has_bootstrap_overrides="true"
  fi

  if [ "$has_internal_profile" = "true" ] && [ "$has_bootstrap_overrides" = "false" ]; then
    SHOULD_BOOTSTRAP_INTERNAL_PROFILE="false"
    return
  fi

  if [ -n "$INSTALL_AK" ] && [ -n "$INSTALL_AZURE_BASE_URL" ]; then
    warn_if_crawl_url "$INSTALL_AZURE_BASE_URL"
    return
  fi

  if [ "$has_internal_profile" = "true" ]; then
    if [ -n "$INSTALL_AZURE_BASE_URL" ]; then
      warn_if_crawl_url "$INSTALL_AZURE_BASE_URL"
    fi
    return
  fi

  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    echo "When bootstrapping a new internal profile, non-interactive installs must set both CODEX_INSTALL_AK and CODEX_INSTALL_AZURE_BASE_URL, for example:" >&2
    echo "  CODEX_INSTALL_AK=... CODEX_INSTALL_AZURE_BASE_URL=... curl -fsSL https://github.com/SDGLBL/codex/releases/latest/download/install.sh | bash" >&2
    exit 1
  fi

  if [ -z "$INSTALL_AZURE_BASE_URL" ]; then
    printf 'Enter the internal Azure base URL: ' >/dev/tty
    IFS= read -r INSTALL_AZURE_BASE_URL </dev/tty || true
  fi

  if [ -z "$INSTALL_AK" ]; then
    old_stty=""
    if command -v stty >/dev/null 2>&1; then
      old_stty="$(stty -g </dev/tty 2>/dev/null || true)"
      stty -echo </dev/tty 2>/dev/null || true
    fi

    printf 'Enter ak for the internal Azure provider: ' >/dev/tty
    IFS= read -r INSTALL_AK </dev/tty || true

    if [ -n "$old_stty" ]; then
      stty "$old_stty" </dev/tty 2>/dev/null || true
    fi
    printf '\n' >/dev/tty
  fi

  if [ -z "$INSTALL_AK" ] || [ -z "$INSTALL_AZURE_BASE_URL" ]; then
    echo "A non-empty Azure base URL and ak are required to configure the internal profile." >&2
    exit 1
  fi

  warn_if_crawl_url "$INSTALL_AZURE_BASE_URL"
}

run_internal_profile_bootstrap() {
  if [ -n "$INSTALL_MODEL" ]; then
    printf '%s\n' "$INSTALL_AK" | "$INSTALL_DIR/codex" debug bootstrap-internal-profile --ak-stdin --azure-base-url "$INSTALL_AZURE_BASE_URL" --model "$INSTALL_MODEL"
  else
    printf '%s\n' "$INSTALL_AK" | "$INSTALL_DIR/codex" debug bootstrap-internal-profile --ak-stdin --azure-base-url "$INSTALL_AZURE_BASE_URL"
  fi
}

install_package_release() {
  release_dir="$1"
  archive_path="$2"
  stage_release="$RELEASES_DIR/.staging.$(basename "$release_dir").$$"

  mkdir -p "$RELEASES_DIR"
  rm -rf "$stage_release"
  mkdir -p "$stage_release"
  tar -xzf "$archive_path" -C "$stage_release"
  chmod 0755 "$stage_release/bin/codex" "$stage_release/codex-path/rg"
  if [ -f "$stage_release/codex-resources/bwrap" ]; then
    chmod 0755 "$stage_release/codex-resources/bwrap"
  fi
  ln -sf "bin/codex" "$stage_release/codex"

  if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
    rm -rf "$release_dir"
  fi
  mv "$stage_release" "$release_dir"
}

install_legacy_platform_npm_release() {
  release_dir="$1"
  archive_path="$2"
  target="$3"
  stage_release="$RELEASES_DIR/.staging.$(basename "$release_dir").$$"
  extract_dir="$tmp_dir/extract"
  vendor_root="$extract_dir/package/vendor/$target"

  mkdir -p "$RELEASES_DIR"
  rm -rf "$stage_release" "$extract_dir"
  mkdir -p "$stage_release/codex-resources" "$extract_dir"
  tar -xzf "$archive_path" -C "$extract_dir"

  cp "$vendor_root/codex/codex" "$stage_release/codex"
  cp "$vendor_root/path/rg" "$stage_release/codex-resources/rg"
  chmod 0755 "$stage_release/codex" "$stage_release/codex-resources/rg"
  if [ -f "$vendor_root/codex-resources/bwrap" ]; then
    cp "$vendor_root/codex-resources/bwrap" "$stage_release/codex-resources/bwrap"
    chmod 0755 "$stage_release/codex-resources/bwrap"
  fi

  if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
    rm -rf "$release_dir"
  fi
}

release_dir_is_complete() {
  release_dir="$1"
  expected_version="$2"
  expected_target="$3"
  layout="$4"

  [ -d "$release_dir" ] &&
    [ "$(basename "$release_dir")" = "$expected_version-$expected_target" ] ||
    return 1

  case "$layout" in
    package)
      [ -f "$release_dir/codex-package.json" ] &&
        [ -x "$release_dir/bin/codex" ] &&
        [ -x "$release_dir/codex" ] &&
        [ -x "$release_dir/codex-path/rg" ] ||
        return 1
      ;;
    legacy-platform-npm)
      [ -x "$release_dir/codex" ] &&
        [ -x "$release_dir/codex-resources/rg" ] ||
        return 1
      ;;
    *)
      return 1
      ;;
  esac

  case "$layout:$expected_target" in
    package:*linux* | legacy-platform-npm:*linux*) [ -x "$release_dir/codex-resources/bwrap" ] ;;
    *) true ;;
  esac
}

update_current_link() {
  release_dir="$1"
  tmp_link="$STANDALONE_ROOT/.current.$$"

  replace_path_with_symlink "$CURRENT_LINK" "$release_dir" "$tmp_link"
}

release_codex_relative_path() {
  release_dir="$1"

  if [ -x "$release_dir/bin/codex" ]; then
    printf 'bin/codex\n'
  else
    printf 'codex\n'
  fi
}

update_visible_command() {
  release_dir="$1"
  mkdir -p "$BIN_DIR"
  tmp_link="$BIN_DIR/.codex.$$"
  codex_relative_path="$(release_codex_relative_path "$release_dir")"

  replace_path_with_symlink "$BIN_PATH" "$CURRENT_LINK/$codex_relative_path" "$tmp_link"
}

verify_visible_command() {
  "$BIN_PATH" --version >/dev/null
}

parse_args "$@"

require_command mktemp
require_command tar

case "$(uname -s)" in
  Darwin)
    os="darwin"
    ;;
  Linux)
    os="linux"
    ;;
  *)
    echo "install.sh supports macOS and Linux. Use install.ps1 on Windows." >&2
    exit 1
    ;;
esac

case "$uname_m_value" in
  x86_64 | amd64)
    arch="x86_64"
    ;;
  arm64 | aarch64)
    arch="aarch64"
    ;;
  *)
    echo "Unsupported architecture: $uname_m_value" >&2
    exit 1
    ;;
esac

if [ "$os" = "darwin" ] && [ "$arch" = "x86_64" ]; then
  proc_translated="${CODEX_INSTALL_PROC_TRANSLATED:-$(sysctl -n sysctl.proc_translated 2>/dev/null || true)}"
  if [ "$proc_translated" = "1" ]; then
    arch="aarch64"
  fi
fi

if [ "$os" = "darwin" ]; then
  if [ "$arch" = "aarch64" ]; then
    vendor_target="aarch64-apple-darwin"
    platform_label="macOS (Apple Silicon)"
  else
    vendor_target="x86_64-apple-darwin"
    platform_label="macOS (Intel)"
  fi
else
  if [ "$arch" = "aarch64" ]; then
    echo "Linux (ARM64) is not currently published for the internal release installer." >&2
    exit 1
  else
    vendor_target="x86_64-unknown-linux-musl"
    platform_label="Linux (x64)"
  fi
fi

resolved_version="$(resolve_version)"
package_asset="codex-package-$vendor_target.tar.gz"
checksum_asset="codex-package_SHA256SUMS"
if release_asset_exists "$package_asset" "$resolved_version" &&
  release_asset_exists "$checksum_asset" "$resolved_version"; then
  install_layout="package"
  asset="$package_asset"
elif release_asset_exists "codex-npm-$npm_tag-$resolved_version.tgz" "$resolved_version"; then
  install_layout="legacy-platform-npm"
  asset="codex-npm-$npm_tag-$resolved_version.tgz"
else
  echo "Could not find Codex package or platform npm release assets for Codex $resolved_version." >&2
  exit 1
fi
download_url="$(release_url_for_asset "$asset" "$resolved_version")"
checksum_url="$(release_url_for_asset "$checksum_asset" "$resolved_version")"
release_name="$resolved_version-$vendor_target"
release_dir="$RELEASES_DIR/$release_name"
current_version="$(current_installed_version)"

if [ -n "$current_version" ] && [ "$current_version" != "$resolved_version" ]; then
  step "Updating Codex CLI from $current_version to $resolved_version"
elif [ -n "$current_version" ]; then
  step "Updating Codex CLI"
else
  install_mode="Installing"
fi

step "$install_mode Codex CLI"
step "Detected platform: $platform_label"

resolved_tag="$(resolve_release_tag)"
resolved_version="$(normalize_version "$resolved_tag")"
native_asset="codex-$vendor_target.tar.gz"
rg_asset="rg-$vendor_target.tar.gz"
native_download_url="$(release_url_for_asset "$native_asset" "$resolved_tag")"
rg_download_url="$(release_url_for_asset "$rg_asset" "$resolved_tag")"

step "Resolved version: $resolved_version"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

native_archive_path="$tmp_dir/$native_asset"
rg_archive_path="$tmp_dir/$rg_asset"
native_extract_dir="$tmp_dir/native"
rg_extract_dir="$tmp_dir/rg"

if ! release_dir_is_complete "$release_dir" "$resolved_version" "$vendor_target" "$install_layout"; then
  if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
    warn "Found incomplete existing release at $release_dir; reinstalling."
  fi

  archive_path="$tmp_dir/$asset"
  checksum_path="$tmp_dir/$checksum_asset"

  step "Downloading Codex CLI"
  if [ "$install_layout" = "package" ]; then
    checksum_digest="$(release_asset_digest "$checksum_asset" "$resolved_version")"
    download_file "$checksum_url" "$checksum_path"
    verify_archive_digest "$checksum_path" "$checksum_digest"
    expected_digest="$(package_archive_digest "$asset" "$checksum_path")"
  else
    expected_digest="$(release_asset_digest "$asset" "$resolved_version")"
  fi
  download_file "$download_url" "$archive_path"
  verify_archive_digest "$archive_path" "$expected_digest"

  step "Installing standalone package to $release_dir"
  if [ "$install_layout" = "package" ]; then
    install_package_release "$release_dir" "$archive_path"
  else
    install_legacy_platform_npm_release "$release_dir" "$archive_path" "$vendor_target"
  fi
fi
update_current_link "$release_dir"
update_visible_command "$release_dir"
add_to_path

case "$path_action" in
  added)
    step "PATH updated for future shells in $path_profile"
    step "Run now: export PATH=\"$INSTALL_DIR:\$PATH\" && codex"
    step "Or open a new terminal and run: codex"
    ;;
  configured)
    step "PATH is already configured for future shells in $path_profile"
    step "Run now: export PATH=\"$INSTALL_DIR:\$PATH\" && codex"
    step "Or open a new terminal and run: codex"
    ;;
  manual)
    step "Could not update your shell profile automatically"
    step "Run now: export PATH=\"$INSTALL_DIR:\$PATH\" && codex"
    step "To persist it, add this line to your shell profile: export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
  *)
    step "$INSTALL_DIR is already on PATH"
    step "Run: codex"
    ;;
esac

printf 'Codex CLI %s installed successfully.\n' "$resolved_version"
