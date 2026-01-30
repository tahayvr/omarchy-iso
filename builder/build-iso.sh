#!/bin/bash

set -e

# Note that these are packages installed to the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git sudo base-devel jq grub

# Install omarchy-keyring for package verification during build
# The [omarchy] repo is defined in /configs/pacman-online.conf with SigLevel = Optional TrustAll
if [[ $OMARCHY_MIRROR == "edge" ]]; then
  pacman --config /configs/pacman-online-edge.conf --noconfirm -Sy omarchy-keyring
else
  pacman --config /configs/pacman-online-stable.conf --noconfirm -Sy omarchy-keyring
fi
pacman-key --populate omarchy

# Setup build locations
build_cache_dir="/var/cache"
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"
mkdir -p $build_cache_dir/
mkdir -p $offline_mirror_dir/

# We base our ISO on the official arch ISO (releng) config
cp -r /archiso/configs/releng/* $build_cache_dir/
rm "$build_cache_dir/airootfs/etc/motd"

# Avoid using reflector for mirror identification as we are relying on the global CDN
# rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
# rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
# rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Persist OMARCHY_MIRROR so it's available at install time
echo "$OMARCHY_MIRROR" > "$build_cache_dir/airootfs/root/omarchy_mirror"

# Setup Omarchy itself
rm -rf "$build_cache_dir/airootfs/root/omarchy"
if [[ -d /omarchy ]]; then
  cp -rp /omarchy "$build_cache_dir/airootfs/root/omarchy"
else
  git clone -b $OMARCHY_INSTALLER_REF https://github.com/$OMARCHY_INSTALLER_REPO.git "$build_cache_dir/airootfs/root/omarchy"
fi

# Bring in User's Custom configs, overlaying them on top of the cloned repo
cp -r /configs/* $build_cache_dir/

# Remove user-excluded packages from omarchy-base.packages
if [[ -f /builder/custom.ignored ]]; then
  omarchy_base_packages="$build_cache_dir/airootfs/root/omarchy/install/omarchy-base.packages"
  
  if [[ -f "$omarchy_base_packages" ]]; then
    # Read excluded packages into array
    mapfile -t excluded_packages < <(grep -v '^#' /builder/custom.ignored | grep -v '^$')
    
    if ((${#excluded_packages[@]} > 0)); then
      echo "Removing ${#excluded_packages[@]} excluded package(s) from omarchy-base.packages"
      
      # Create a temporary file
      temp_file=$(mktemp)
      
      # Copy omarchy-base.packages, excluding user-selected packages
      while IFS= read -r line; do
        # Keep comments and empty lines
        if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
          echo "$line" >> "$temp_file"
        else
          # Check if this package should be excluded
          should_exclude=false
          for excluded in "${excluded_packages[@]}"; do
            if [[ "$line" == "$excluded" ]]; then
              should_exclude=true
              echo "  Excluding: $excluded"
              break
            fi
          done
          
          # Only add if not excluded
          if [[ "$should_exclude" == false ]]; then
            echo "$line" >> "$temp_file"
          fi
        fi
      done < "$omarchy_base_packages"
      
      # Replace original with filtered version
      mv "$temp_file" "$omarchy_base_packages"
      echo "Excluded packages removed from omarchy-base.packages"
    fi
  else
    echo "Warning: omarchy-base.packages not found at $omarchy_base_packages"
  fi
fi

# Make log uploader available in the ISO too
mkdir -p "$build_cache_dir/airootfs/usr/local/bin/"
cp "$build_cache_dir/airootfs/root/omarchy/bin/omarchy-upload-log" "$build_cache_dir/airootfs/usr/local/bin/omarchy-upload-log"

# Copy the Omarchy Plymouth theme to the ISO
mkdir -p "$build_cache_dir/airootfs/usr/share/plymouth/themes/omarchy"
cp -r "$build_cache_dir/airootfs/root/omarchy/default/plymouth/"* "$build_cache_dir/airootfs/usr/share/plymouth/themes/omarchy/"

# Download and verify Node.js binary for offline installation
NODE_DIST_URL="https://nodejs.org/dist/latest"

# Get checksums and parse filename and SHA
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $1}')

# Download the tarball
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"

# Verify SHA256 checksum
echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c - || {
    echo "ERROR: Node.js checksum verification failed!"
    exit 1
}

# Copy to ISO
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Add our additional packages to packages.x86_64
arch_packages=(linux-t2 git gum jq openssl plymouth tzupdate omarchy-keyring)
printf '%s\n' "${arch_packages[@]}" >>"$build_cache_dir/packages.x86_64"

# Inject custom packages into the installer's package list
target_pkg_list="$build_cache_dir/airootfs/root/omarchy/install/omarchy-base.packages"
if [[ -f "$target_pkg_list" ]]; then
  if [[ -f /builder/custom-arch.packages ]]; then
    echo "Adding custom official packages to installer list..."
    echo "" >> "$target_pkg_list"
    grep -v '^#' /builder/custom-arch.packages | grep -v '^$' >> "$target_pkg_list" || true
  echo "Custom official packages appended to omarchy-base.packages"
  fi

  # Ensure custom AUR packages are also installed (they are built into the offline repo above)
  if [[ -f /builder/custom-aur.packages ]]; then
    echo "Adding custom AUR packages to installer list..."
    echo "" >> "$target_pkg_list"
    grep -v '^#' /builder/custom-aur.packages | grep -v '^$' >> "$target_pkg_list" || true
    echo "Custom AUR packages appended to omarchy-base.packages"
  fi
fi

# Remove packages listed in custom.ignored from omarchy-base.packages
if [[ -f /builder/custom.ignored ]] && [[ -f "$target_pkg_list" ]]; then
  mapfile -t ignored_packages < <(grep -v '^#' /builder/custom.ignored | grep -v '^$')

  if ((${#ignored_packages[@]} > 0)); then
    temp_file=$(mktemp)
    while IFS= read -r line; do
      if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
        echo "$line" >> "$temp_file"
      else
        should_exclude=false
        for ignored in "${ignored_packages[@]}"; do
          if [[ "$line" == "$ignored" ]]; then
            should_exclude=true
            break
          fi
        done

        if [[ "$should_exclude" == false ]]; then
          echo "$line" >> "$temp_file"
        fi
      fi
    done < "$target_pkg_list"

    mv "$temp_file" "$target_pkg_list"
  fi
fi

# DEBUG: Print final installer package list for testing
if [[ -f "$target_pkg_list" ]]; then
  echo "==== BEGIN omarchy-base.packages (final) ===="
  cat "$target_pkg_list"
  echo "==== END omarchy-base.packages (final) ===="
fi

# Read requested AUR packages once (used both for filtering pacman downloads and for yay builds)
aur_packages=()
aur_filter_file=""
if [[ -f /builder/custom-aur.packages ]]; then
  mapfile -t aur_packages < <(grep -v '^#' /builder/custom-aur.packages | grep -v '^$' || true)
fi
if ((${#aur_packages[@]} > 0)); then
  aur_filter_file=$(mktemp)
  printf '%s\n' "${aur_packages[@]}" > "$aur_filter_file"
fi

# Build list of all the packages needed for the offline mirror
all_packages=($(cat "$build_cache_dir/packages.x86_64"))
if [[ -n "$aur_filter_file" ]]; then
  # Exclude AUR package names here because pacman cannot download them from official repos.
  # They are built later via yay and added to the offline repo.
  all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-base.packages" | grep -v '^$' | grep -v -x -F -f "$aur_filter_file"))
  all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-other.packages" | grep -v '^$' | grep -v -x -F -f "$aur_filter_file"))
  all_packages+=($(grep -v '^#' /builder/archinstall.packages | grep -v '^$' | grep -v -x -F -f "$aur_filter_file"))
else
  all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-base.packages" | grep -v '^$'))
  all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omarchy/install/omarchy-other.packages" | grep -v '^$'))
  all_packages+=($(grep -v '^#' /builder/archinstall.packages | grep -v '^$'))
fi

# Download all the packages to the offline mirror inside the ISO
mkdir -p /tmp/offlinedb
if [[ $OMARCHY_MIRROR == "edge" ]]; then
  pacman --config /configs/pacman-online-edge.conf --noconfirm -Syw "${all_packages[@]}" --cachedir $offline_mirror_dir/ --dbpath /tmp/offlinedb
else
  pacman --config /configs/pacman-online-stable.conf --noconfirm -Syw "${all_packages[@]}" --cachedir $offline_mirror_dir/ --dbpath /tmp/offlinedb
fi

# Clean up temporary filter file if created
if [[ -n "$aur_filter_file" ]]; then
  rm -f "$aur_filter_file"
fi

# Build and package AUR packages if specified
if [[ ${#aur_packages[@]} -gt 0 ]]; then
    echo "Building ${#aur_packages[@]} AUR package(s)..."
    echo "AUR packages requested: ${aur_packages[*]}"
    
    # Create a build user (makepkg doesn't run as root)
    useradd -m -G wheel builduser
    echo "builduser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    
    # Install yay for the build user
    su - builduser -c "
      cd /tmp
      rm -rf yay-bin
      git clone https://aur.archlinux.org/yay-bin.git
      cd yay-bin
      makepkg -si --noconfirm
    "
    
    # Create build directory
    mkdir -p /tmp/aur-builds
    chown builduser:builduser /tmp/aur-builds
    
    total_copied=0

    # Build each AUR package
    for pkg in "${aur_packages[@]}"; do
      echo "Building AUR package: $pkg"

      marker=$(mktemp)
      touch "$marker"

      # NOTE: $pkg must expand here (root shell) so the builduser shell gets the actual package name.
      su - builduser -c "yay -S --noconfirm --needed --builddir /tmp/aur-builds -- \"$pkg\""

      copied_count=0
      copied_files=()

      # Capture built AUR packages
      while IFS= read -r -d '' f; do
        cp "$f" "$offline_mirror_dir/"
        copied_files+=("$f")
        copied_count=$((copied_count + 1))
      done < <(find /tmp/aur-builds -name "*.pkg.tar.zst" -cnewer "$marker" -print0 2>/dev/null)

      # Capture official dependencies downloaded by pacman during the build
      while IFS= read -r -d '' f; do
        cp "$f" "$offline_mirror_dir/"
        copied_files+=("$f")
        copied_count=$((copied_count + 1))
      done < <(find /var/cache/pacman/pkg -name "*.pkg.tar.zst" -cnewer "$marker" -print0 2>/dev/null)

      rm -f "$marker"
      total_copied=$((total_copied + copied_count))

      echo "AUR package '$pkg' done; copied ${copied_count} new file(s) into offline mirror"
      if (( copied_count > 0 )); then
        echo "Newly built package files for '$pkg' (up to 10):"
        printf '%s\n' "${copied_files[@]}" | tail -n 10
      else
        echo "Warning: No new *.pkg.tar.zst produced for '$pkg' (check yay output above)"
      fi
    done

    shopt -s nullglob
    mirror_files=("$offline_mirror_dir"/*.pkg.tar.zst)
    echo "AUR build complete. Total new file(s) copied: ${total_copied}. Offline mirror now contains ${#mirror_files[@]} package file(s)."
    if compgen -G "$offline_mirror_dir/*.pkg.tar.zst" > /dev/null; then
      echo "Latest AUR/offline mirror package files (up to 10):"
      ls -1t "$offline_mirror_dir"/*.pkg.tar.zst | head -n 10
    else
      echo "Warning: No *.pkg.tar.zst files found in offline mirror after AUR build"
    fi
else
  echo "No custom AUR packages requested; skipping AUR builds"
fi

# Add all packages to the offline repository database
repo-add --new "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst

# Create a symlink to the offline mirror instead of duplicating it.
# mkarchiso needs packages at /var/cache/omarchy/mirror/offline in the container,
# but they're actually in $build_cache_dir/airootfs/var/cache/omarchy/mirror/offline
mkdir -p /var/cache/omarchy/mirror
ln -s "$offline_mirror_dir" "/var/cache/omarchy/mirror/offline"

# Copy the pacman.conf to the ISO's /etc directory so the live environment uses our
# same config when booted
cp $build_cache_dir/pacman.conf "$build_cache_dir/airootfs/etc/pacman.conf"

# Finally, we assemble the entire ISO
mkarchiso -v -w "$build_cache_dir/work/" -o "/out/" "$build_cache_dir/"

# Fix ownership of output files to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" /out/
fi
