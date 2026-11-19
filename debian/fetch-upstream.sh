#!/bin/sh
# KubeOS control plane: fetch the pinned upstream binaries at build time.
#
# WHY    ~360 MB of binaries that no Debian package ships. Committing them is impossible; the
#        node needs them offline; and they must match the kubelet package exactly, or the
#        control plane and the kubelet disagree about the API. So the versions are pinned here,
#        every file is verified against the checksum upstream publishes (dl.k8s.io serves
#        '<sha256>  <file>', etcd serves a SHA256SUMS file), and the build fails on any drift.
# SAFE   Writes only into the destination directory, and only after a checksum matches.
set -eu

DEST=${1:?usage: fetch-upstream.sh <bin-dir>}
KUBE_VERSION=${KUBE_VERSION:-v1.37.2}
ETCD_VERSION=${ETCD_VERSION:-v3.6.5}
BINARIES="kube-apiserver kube-controller-manager kube-scheduler kube-proxy"

log() { printf 'fetch-upstream: %s\n' "$*"; }
die() { printf 'fetch-upstream: ERROR: %s\n' "$*" >&2; exit 1; }

install -d "$DEST"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fetch() {
    _i=0
    while [ "$_i" -lt 4 ]; do
        _i=$((_i + 1))
        if curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors -o "$2" "$1"; then
            return 0
        fi
        log "attempt $_i/4 failed: $1"
        [ "$_i" -lt 4 ] && sleep 5
    done
    return 1
}

# --- the Kubernetes binaries: dl.k8s.io publishes '<sha256>  <name>' -----------
for bin in $BINARIES; do
    url="https://dl.k8s.io/${KUBE_VERSION}/bin/linux/amd64/${bin}"
    log "fetching $url"
    fetch "$url" "$WORK/$bin" || die "could not download $bin"
    fetch "$url.sha256" "$WORK/$bin.sha256" || die "could not download the $bin checksum"
    want=$(awk '{print $1}' "$WORK/$bin.sha256")
    got=$(sha256sum "$WORK/$bin" | cut -d' ' -f1)
    [ "$want" = "$got" ] || die "$bin checksum mismatch
    expected $want
    got      $got"
    install -m 0755 "$WORK/$bin" "$DEST/$bin"
done

# --- etcd: the release ships a SHA256SUMS file -------------------------------
TARBALL="etcd-${ETCD_VERSION}-linux-amd64.tar.gz"
BASE="https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}"
log "fetching $BASE/$TARBALL"
fetch "$BASE/$TARBALL" "$WORK/$TARBALL" || die "could not download $TARBALL"
fetch "$BASE/SHA256SUMS" "$WORK/SHA256SUMS" || die "could not download etcd's SHA256SUMS"
( cd "$WORK" && grep " $TARBALL\$" SHA256SUMS > etcd.sum && sha256sum -c etcd.sum ) \
    || die "etcd checksum mismatch"
tar -xzf "$WORK/$TARBALL" -C "$WORK"
for bin in etcd etcdctl; do
    install -m 0755 "$WORK/etcd-${ETCD_VERSION}-linux-amd64/$bin" "$DEST/$bin"
done

# --- prove what we shipped ---------------------------------------------------
for bin in $BINARIES; do
    case "$("$DEST/$bin" --version 2>/dev/null || true)" in
        *"$KUBE_VERSION"*) log "$bin $KUBE_VERSION ok" ;;
        *) die "$bin does not report $KUBE_VERSION" ;;
    esac
done
case "$("$DEST/etcd" --version 2>/dev/null | head -n 2 | tr '\n' ' ')" in
    *"${ETCD_VERSION#v}"*) log "etcd $ETCD_VERSION ok" ;;
    *) die "etcd does not report $ETCD_VERSION" ;;
esac
