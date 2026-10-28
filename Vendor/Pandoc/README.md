# Bundled Pandoc

The application uses the unmodified Apple Silicon executable from the official
[Pandoc 3.13 release](https://github.com/jgm/pandoc/releases/tag/3.13).
The ZIP is kept compressed because its executable exceeds GitHub's single-file
size limit. No download or system installation takes place at application startup.

- Archive: `pandoc-3.13-arm64-macOS.zip`
- Upstream: https://github.com/jgm/pandoc/releases/download/3.13/pandoc-3.13-arm64-macOS.zip
- Archive SHA-256: `f436d18bebbfb3ddd326597686dacab9fac5dc23bd060495020f35a28a43a7c3`
- Version-specific copyright notices and GPL text are copied unchanged into
  `LacEditor/Resources/Pandoc/COPYRIGHT` and `COPYING` and included in the app.

Run `sh Scripts/prepare-pandoc.sh` before a Swift Package Manager build. Xcode
runs it as a build phase. The generated executable is ignored by Git and is
copied to `Contents/MacOS/pandoc` in the Xcode app, with code signing on copy.
Swift Package Manager copies it into its resource bundle instead.

Pandoc is GPL-2.0-or-later with the additional notices listed in `COPYRIGHT`.
The corresponding upstream source is at https://github.com/jgm/pandoc/tree/3.13
and https://hackage.haskell.org/package/pandoc-3.13/pandoc-3.13.tar.gz.
Before distributing a release containing the binary, provide the complete
corresponding source, including required dependency sources and build scripts,
or another distribution arrangement compliant with GPL section 3. The links
above and a license copy alone are not a substitute for that requirement.
This task does not publish a release or make a source offer on the user's behalf.

To update Pandoc, replace the pinned official archive, verify its release digest,
update the version and checksum in `Scripts/prepare-pandoc.sh`, refresh both
license files, and run the import/export and packaged-app checks on macOS.
