# Release process

Use Xcode 27 or later with a valid Developer ID Application certificate and Apple Developer account. The project enables hardened runtime and uses bundle ID `com.mingistech.BlackBox`. API keys are never bundled.

1. Run the unit tests and Debug terminal smoke test documented in the repository README.
2. Archive the Release configuration for generic macOS with `ARCHS='arm64 x86_64'`, `ONLY_ACTIVE_ARCH=NO`, manual Developer ID signing, and a secure timestamp. Keep archives outside the repository.
3. Submit the archive with `xcodebuild -exportArchive`, `-exportOptionsPlist Release/ExportOptions.plist`, and your signed-in Xcode account. Alternatively, export the signed app locally, ZIP it with `ditto -c -k --keepParent`, and submit that ZIP with `xcrun notarytool submit --keychain-profile YOUR_PROFILE`. Store credentials in Keychain, never in this repository.
4. Wait for Apple's Accepted result and inspect the notarization log. Export the notarized archive with `xcodebuild -exportNotarizedApp`, or staple the accepted app with `xcrun stapler staple`.
5. Verify the app with `codesign --verify --deep --strict`, `xcrun stapler validate`, and `spctl --assess --type execute`. Confirm both architectures and the version in the final bundle.
6. Package the stapled app as `BlackBox-VERSION-macOS.zip` using `ditto -c -k --sequesterRsrc --keepParent`. Generate a SHA-256 checksum for the final ZIP.
7. Commit the corresponding source, tag that commit, and publish the GitHub release with the ZIP, checksum, and versioned release notes. Do not publish an unnotarized substitute if notarization fails.

The bundle-ID transition preserves development-build model choices and favorites. API keys remain in the same provider-specific Keychain entries; macOS may request authorization when the signed application first accesses existing keys.
