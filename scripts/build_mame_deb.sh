#!/usr/bin/env bash
# just build-mame: Debian sid's mame source package rebuilt on Debian 13 (trixie), amd64, in a
# container: mame + mame-data .deb files in files/, depending on trixie's libraries only (sid's own
# binary needs sid's libc6 and Qt). About 20 minutes on 16 cores; the build tree stays in the
# podman volume mame-build (podman volume rm mame-build to free it).
#
#   scripts/build_mame_deb.sh [SOURCE_VERSION]     default: the version in sid today
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
version=${1:-}
runtime=$(command -v podman || command -v docker || true)
[ -n "$runtime" ] || { echo "error: podman or docker is needed" >&2; exit 1; }
mkdir -p "$repo/files"

"$runtime" volume create mame-build > /dev/null 2>&1 || true
"$runtime" run --rm -v mame-build:/build -v "$repo/files:/out:z" -e VERSION="$version" \
    docker.io/library/debian:trixie bash -euo pipefail -c '
        export DEBIAN_FRONTEND=noninteractive
        echo "deb-src http://deb.debian.org/debian sid main" > /etc/apt/sources.list.d/sid-src.list
        apt-get update -qq
        [ -n "$VERSION" ] || VERSION=$(apt-cache showsrc mame | sed -n "s/^Version: //p" | sort -V | tail -n 1)
        echo "Building mame $VERSION for trixie"
        apt-get install -y -qq --no-install-recommends devscripts build-essential fakeroot ca-certificates > /dev/null
        apt-get build-dep -y -qq "mame=$VERSION" > /dev/null
        rm -rf /build/src && mkdir /build/src && cd /build/src
        apt-get source -qq "mame=$VERSION"
        cd mame-*/
        # Backport version (e.g. 0.289+dfsg1-1~bpo13+1): sorts before the next Debian upload.
        dch --bpo --distribution trixie-backports "Rebuild for Debian 13 (trixie), MAUI cabinets."
        # nodoc: no mame-doc (sphinx), nocheck: no test suite. Up to 14 jobs: about 1.5 GB each.
        jobs=$(( $(nproc) < 14 ? $(nproc) : 14 ))
        DEB_BUILD_OPTIONS="parallel=$jobs nocheck nodoc" dpkg-buildpackage -b -uc -us > /build/build.log 2>&1 \
            || { tail -n 40 /build/build.log; exit 1; }
        cp ../mame_*_amd64.deb ../mame-data_*_all.deb /out/
        cd /out && sha256sum mame_*_amd64.deb mame-data_*_all.deb'
echo "Packages in files/: set them, with these sha256, in mame_debs (group_vars/x86_64.yml)."
