# Third-Party Notices

This repository's own source code is licensed under the MIT License (see `LICENSE`).
Third-party components keep their own licenses. This file summarizes the packages
resolved in `pubspec.lock` at the time of writing, plus native components downloaded
at build time.

## Components that are not permissive open source

### `syncfusion_flutter_pdf` / `syncfusion_flutter_core` (33.2.10)

These packages are **not** covered by this project's MIT license. They are distributed
under the Syncfusion Essential Studio program and require either a Syncfusion Community
License or a commercial license. The Community License is restricted — for example it
requires gross revenue below 1,000,000 USD per year and fewer than five developers — and
Syncfusion's terms state that the product may not be used without holding one of those
licenses and accepting its terms. If you build, distribute or use this application, you
are responsible for obtaining your own Syncfusion license.

Authoritative license text: <https://www.syncfusion.com/content/downloads/syncfusion_license.pdf>

### `dbus` (transitive dependency, MPL-2.0)

`dbus` is licensed under the Mozilla Public License 2.0 (file-level copyleft). It is used
unmodified. If you modify MPL-covered files, you must publish those modifications.

## Native components downloaded at build time

### PDFium (via the `pdfx` plugin)

The `pdfx` plugin itself is MIT-licensed; its Windows build downloads PDFium binaries
from `bblanchon/pdfium-binaries`. PDFium is licensed under BSD-3-Clause
(Copyright 2014 The PDFium Authors). Keep this notice with any compiled binary you
redistribute.

## Everything else

All remaining packages resolved in `pubspec.lock` are MIT, BSD-2-Clause, BSD-3-Clause or
Apache-2.0 licensed, including the Flutter/Dart SDK packages. Counts at the time of
writing: 101 × BSD-3-Clause, 21 × MIT, 9 × Apache-2.0, 7 × BSD-2-Clause.

The lock file is the authoritative dependency list; each package's own `LICENSE` file in
the pub cache carries the authoritative text.

## Repository content

No exam papers, question banks, OCR outputs or other third-party study documents are
distributed with this repository. See the "Documents and third-party rights" section of
`README.md`.
