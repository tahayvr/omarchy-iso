#!/bin/bash
#
# Custom package support for personalised ISO builds (used by omarchyiso).
#
# Sourced by build-iso.sh after the Omarchy package lists have been copied into
# the airootfs, and before the offline mirror is assembled. It is a no-op when
# none of the input files exist, so a plain build is unaffected.
#
# Inputs (all optional, one package name per line, # comments allowed):
#   /builder/custom.ignored        packages to drop from omarchy-base.packages
#   /builder/custom-arch.packages  official Arch packages to add to the install
#   /builder/custom-aur.packages   AUR packages to build and add to the install
#
# Outputs consumed by build-iso.sh:
#   custom_aur_names   AUR package names (must be kept out of the online pacman
#                      transactions, they only exist in the offline mirror)
#   custom_aur_files   filenames of the built AUR packages now sitting in the
#                      offline mirror (kept through the prune step)
#   custom_aur_deps    repo packages the AUR packages depend on (added to the
#                      online download so the mirror carries them)
#
# The shipped copy of omarchy-base.packages is what the install orchestrator
# reads at install time, so editing it is enough to change what gets installed.

custom_aur_names=()
custom_aur_files=()
custom_aur_deps=()

_custom_read_list() {
  local file="$1"
  [[ -f $file ]] || return 0
  grep -v '^\s*#' "$file" | sed 's/\s\+$//' | grep -v '^$' || true
}

_custom_shipped_base_list() {
  echo "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
}

custom_remove_ignored_packages() {
  local list_file
  list_file=$(_custom_shipped_base_list)
  [[ -f /builder/custom.ignored && -f $list_file ]] || return 0

  local -a ignored
  mapfile -t ignored < <(_custom_read_list /builder/custom.ignored)
  (( ${#ignored[@]} > 0 )) || return 0

  echo "Removing ${#ignored[@]} package(s) from omarchy-base.packages: ${ignored[*]}"
  local tmp
  tmp=$(mktemp)
  grep -Fxv -f <(printf '%s\n' "${ignored[@]}") "$list_file" > "$tmp" || true
  mv "$tmp" "$list_file"
}

custom_add_official_packages() {
  local list_file
  list_file=$(_custom_shipped_base_list)
  [[ -f /builder/custom-arch.packages && -f $list_file ]] || return 0

  local -a extra
  mapfile -t extra < <(_custom_read_list /builder/custom-arch.packages)
  (( ${#extra[@]} > 0 )) || return 0

  echo "Adding ${#extra[@]} official package(s) to omarchy-base.packages: ${extra[*]}"
  {
    echo
    echo "# Custom official packages (omarchyiso)"
    printf '%s\n' "${extra[@]}"
  } >> "$list_file"
}

# Runtime dependencies of a built package file, as bare package names.
# Version constraints are stripped; shared-object dependencies are skipped
# because pacman resolves those through the owning package anyway.
_custom_package_depends() {
  local pkg_file="$1"
  bsdtar -xOf "$pkg_file" .PKGINFO 2>/dev/null |
    awk -F' = ' '$1 == "depend" { print $2 }' |
    sed -E 's/[<>=].*$//' |
    grep -v '\.so' || true
}

custom_build_aur_packages() {
  [[ -f /builder/custom-aur.packages ]] || return 0

  mapfile -t custom_aur_names < <(_custom_read_list /builder/custom-aur.packages)
  (( ${#custom_aur_names[@]} > 0 )) || return 0

  echo "Building ${#custom_aur_names[@]} AUR package(s): ${custom_aur_names[*]}"

  local pkgdest=${CUSTOM_AUR_PKGDEST:-/tmp/aur-pkgdest}
  local builddir=${CUSTOM_AUR_BUILDDIR:-/tmp/aur-builds}
  rm -rf "$pkgdest" "$builddir"
  mkdir -p "$pkgdest" "$builddir"

  # makepkg refuses to run as root, so build as a throwaway user with
  # passwordless sudo (yay needs it to install dependencies).
  if ! id builduser &>/dev/null; then
    useradd -m -G wheel builduser
    echo "builduser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
  fi
  chown builduser:builduser "$pkgdest" "$builddir"

  # yay is needed to resolve AUR dependency chains. Install it from yay-bin.
  if ! command -v yay &>/dev/null; then
    su - builduser -c "
      set -e
      cd /tmp
      rm -rf yay-bin
      git clone -q https://aur.archlinux.org/yay-bin.git
      cd yay-bin
      makepkg -si --noconfirm
    "
  fi

  local pkg
  for pkg in "${custom_aur_names[@]}"; do
    echo "Building AUR package: $pkg"
    su - builduser -c "
      set -e
      export PKGDEST=$pkgdest
      yay -S --noconfirm --needed --answerdiff None --answerclean None \
        --builddir $builddir -- '$pkg'
    "
  done

  # Everything makepkg produced (the requested packages and any AUR
  # dependencies yay had to build) goes into the offline mirror.
  local pkg_file name
  while IFS= read -r -d '' pkg_file; do
    name=$(basename "$pkg_file")
    cp "$pkg_file" "$offline_mirror_dir/$name"
    custom_aur_files+=("$name")
    mapfile -t -O "${#custom_aur_deps[@]}" custom_aur_deps < <(_custom_package_depends "$pkg_file")
  done < <(find "$pkgdest" -maxdepth 1 -type f -name '*.pkg.tar.zst' ! -name '*.sig' -print0)

  if (( ${#custom_aur_files[@]} == 0 )); then
    echo "ERROR: no package files were produced for the requested AUR packages" >&2
    exit 1
  fi
  echo "Built AUR package files: ${custom_aur_files[*]}"

  # Dependencies satisfied by other built AUR packages are not repo packages.
  local -a built_names
  for pkg_file in "$pkgdest"/*.pkg.tar.zst; do
    built_names+=("$(bsdtar -xOf "$pkg_file" .PKGINFO | awk -F' = ' '$1 == "pkgname" { print $2 }')")
    mapfile -t -O "${#built_names[@]}" built_names < <(
      bsdtar -xOf "$pkg_file" .PKGINFO | awk -F' = ' '$1 == "provides" { print $2 }' | sed -E 's/[<>=].*$//'
    )
  done
  if (( ${#custom_aur_deps[@]} > 0 )); then
    mapfile -t custom_aur_deps < <(
      printf '%s\n' "${custom_aur_deps[@]}" | sort -u |
        grep -Fxv -f <(printf '%s\n' "${built_names[@]}") || true
    )
  fi
  (( ${#custom_aur_deps[@]} > 0 )) && echo "Repo dependencies of AUR packages: ${custom_aur_deps[*]}"

  # The install orchestrator installs what omarchy-base.packages lists, and the
  # offline repo built below carries these packages, so listing them is enough.
  local list_file
  list_file=$(_custom_shipped_base_list)
  {
    echo
    echo "# Custom AUR packages (omarchyiso)"
    printf '%s\n' "${custom_aur_names[@]}"
  } >> "$list_file"
}

custom_remove_ignored_packages
custom_add_official_packages
custom_build_aur_packages
