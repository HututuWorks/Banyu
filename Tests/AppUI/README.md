# Native App UI review

Run `scripts/test-app-ui.sh` on a Mac with full Xcode. The shared script environment
accepts `EHK_XCODE_APP` and `EHK_BUILD_DIR`; no user-specific path is required.

The tool copies the current `App` and `Shared` Swift sources into the build directory,
compiles the actual asset catalog (including `BrandLogo`), and hosts the SwiftUI
screens inside a native Mac Catalyst application. It produces PNGs, bounded
geometry checks, and a source/asset SHA-256 manifest in `build/app-ui/`.

Only the copied sources are substituted: settings use memory, cloud transport
methods fail without sending a request, and Apple language preparation is disabled
with availability stubbed as ready. No API key, Keychain item, or account is needed.
The harness never tests connections or opens system settings.

The selected samples cover the main screens in light/dark mode, small width, and
accessibility-size layout branches. Images are native Mac Catalyst renders, **not
iPhone screenshots**. Catalyst does not reproduce iPhone semantic-font scaling,
keyboard behavior, system chrome, or enabled keyboard registration. Image review
is still needed to assess text clipping and visual quality; geometry checks alone
do not certify those details.

For a targeted rerun, set `BANYU_REVIEW_ONLY` to a substring of a screenshot name,
for example `BANYU_REVIEW_ONLY=about scripts/test-app-ui.sh`. Such a run's report
covers only that subset.
