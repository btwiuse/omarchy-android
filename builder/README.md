# Clean build pipeline

The host and guest graphics stacks are built separately because Termux uses
Android/Bionic while the PRoot guest uses Arch Linux ARM/glibc.

- `host/build-weston.sh` builds the patched nested X11 backend in Termux.
- `guest/build-graphics.sh` runs inside a disposable Arch Linux ARM builder and
stages the pinned Mesa/KGSL, Aquamarine, and Hyprland builds under
`/opt/omarchy-android`. `guest/audit-graphics.sh` rejects missing/non-ARM64
drivers, incorrect package prefixes, a misplaced Turnip ICD, and unexpected
Aquamarine linkage before checksums are emitted.

Both scripts refuse to reuse build directories. Source checkouts must already
be at the revisions in `manifest/components.lock`. Hyprland's tree pins its
Git submodules; the orchestrated build verifies the Glaze FetchContent
revision (currently `b518eec7a22e56ffa238b072c07f47efa7cea97f`, the commit
Hyprland's CMakeLists.txt resolves `GLAZE_VERSION v7.2.0` to) and forces the
pinned fetch instead of accepting a coincidentally compatible system package.
A scoped pkg-config wrapper likewise forces Hyprland's protocol XML to come
from its pinned submodule while delegating every other lookup to Arch. Release assembly invokes
these scripts in a fresh builder;
it never compiles inside or copies files from a user's existing Omarchy guest.

Run `host/prepare-guest-builder.sh` from Termux to create the disposable,
native-ARM64 Arch builder and install the dependencies in `guest/packages.txt`.
The bootstrap also applies the pacman 7 settings required under PRoot; it does
not modify the user's Omarchy container. The source image and its primary OCI
layer digest are pinned to `ghcr.io/btwiuse/arch:base` in `manifest/oci-images.lock`;
the builder refuses a mismatched base.

Then run `host/build-guest-graphics.sh`. It mounts only this project, the
separate local forks, and the artifact destination into an isolated PRoot
session. The guest creates disposable writable source clones, checks out the
locked upstream revisions, initializes pinned
submodules, and performs a clean build. Its default output is ignored under
`.work/guest-artifacts/graphics`.

The host runtime uses Termux's packaged Weston executable and GL renderer. The
builder therefore compiles and installs only the patched `x11-backend.so`
module used through `WESTON_MODULE_MAP`; unrelated Weston backends, clients,
and renderers are not release artifacts.

`host/build-release.sh VERSION` assembles a local OCI image of the sanitized
rootfs using the same `builder/ci/Dockerfile.release` that CI uses (run via
`proot-distro build`), requires the exact `manifest/packages-aarch64-VERSION.lock`
package closure, builds the host payload from the patched Weston module and
the two native helpers, and emits a local OCI image tarball plus a host
payload tarball under `.work/releases/`. No host bind mounts or proot login
into a disposable builder is required: the OCI build runs the entire release
recipe inside an isolated proot session driven by the Dockerfile.

## GitHub Actions image rebuild

`.github/workflows/build-image.yml` performs a clean, native ARM64 rebuild on
GitHub's `ubuntu-24.04-arm` runner. It verifies the locked OCI base image
digest from `manifest/oci-images.lock`, fetches only the pinned source
revisions, rebuilds Mesa/Aquamarine/Hyprland
inside `builder/ci/Dockerfile.release`, scrubs the result, pushes the OCI image
to `ghcr.io`, and uploads these workflow artifacts:

- the OCI image-layout tarball produced by `docker save`;
- its exact generated package inventory;
- the OCI image manifest and SHA-256 checksums.

The generated closure must exactly match
`manifest/packages-aarch64-edge.lock`. If Arch Linux ARM changes, CI fails and
uploads the newly resolved inventory as a small `package-drift-*` artifact for
review; it never silently publishes a different image.

Every push to `main` rebuilds the OCI image. A semantic release tag such as
`v0.1.1` additionally downloads the checksum-pinned Android/Bionic host payload,
assembles the host bundle, publishes the bundle and SHA-256 sidecar as a GitHub
Release asset, and verifies that the published OCI image is byte-identical to
the one CI built by digest. The installer on the phone picks the latest
release via the `/releases/latest` redirect - this pipeline never writes to
the repo's default branch.
End users only pull the published OCI image and download the small host payload;
they do not run this build pipeline.

The host payload contains only the patched Weston module, two small Termux
helpers, and their required license texts. It was extracted and byte-verified
from the accepted `v0.1.0` release by `host/package-host-bootstrap.sh`; its URL,
checksum, and source-bundle checksum are locked in
`manifest/host-artifacts.lock`. Future host changes must be rebuilt and tested
from Termux before publishing and pinning a new payload.
