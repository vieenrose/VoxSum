# Releasing

1. Bump `versionCode` / `versionName` in `app/build.gradle.kts`.
2. Commit, then tag and push: `git tag vX.Y.Z && git push origin android vX.Y.Z`.
3. `.github/workflows/release.yml` builds a signed release APK and attaches it to a GitHub
   Release named after the tag. Users download it from the
   [latest release](https://github.com/vieenrose/VoxSumDroid/releases/latest); the in-app
   update checker points at the same place.

Signing secrets (repository → Settings → Secrets → Actions): `KEYSTORE_BASE64` (the keystore,
base64), `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`. Without them the workflow still builds
and uploads an unsigned APK as a run artifact (also what **Run workflow** does by hand).
