# Third-party notices

Bulava ships one third-party component inside the application bundle. Its licence travels with it,
which is the whole point of this file: a binary in a repository with no licence beside it is a
binary nobody downstream can legally ship.

## Sparkle 2.9.6

`Frameworks/Sparkle.framework` — the framework that checks for updates, verifies their signature
and installs them. https://sparkle-project.org

Copyright (c) 2006 Andy Matuschak
Copyright (c) 2015-2026 Sparkle Project contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Sparkle also bundles portions of bspatch/bsdiff (Colin Percival, BSD 2-clause) and Ed25519
reference code; see https://github.com/sparkle-project/Sparkle for the full set.

## Gradle Wrapper (`bulava-mobile/gradle/wrapper/gradle-wrapper.jar`)

The Gradle project's own launcher, committed so the phone app builds with exactly the Gradle it
names (9.5.1). It is part of the build, not of any app. Apache License 2.0: the text is inside the
jar (`META-INF/LICENSE`) and at https://www.apache.org/licenses/LICENSE-2.0.

## What Bulava does not bundle

Claude Code and the Codex CLI are not included, not vendored and not redistributed. Bulava runs
whichever copies are already on your machine, under your own accounts.

The phone app's libraries are not in this repository either: Gradle fetches them when it builds —
Kotlin and kotlinx (coroutines, serialization), Compose Multiplatform and its Material 3,
AndroidX (AppCompat, Activity, Lifecycle, CameraX, Glance), OkHttp, ML Kit's barcode scanner and
a Markdown renderer for Compose — each under its own licence. The
two Go services, `server/report-inbox` and `bulava-mobile/push-relay`, use Go's standard library
only.


## Trademarks

“Bulava”, the mace mark, and the bulava.app domain are the author's. The licence covers the code,
not the name: a fork is welcome, a fork calling itself Bulava is not.
