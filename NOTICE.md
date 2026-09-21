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

## What Bulava does not bundle

Claude Code and the Codex CLI are not included, not vendored and not redistributed. Bulava runs
whichever copies are already on your machine, under your own accounts.


## Trademarks

“Bulava”, the mace mark, and the bulava.app domain are the author's. The licence covers the code,
not the name: a fork is welcome, a fork calling itself Bulava is not.
