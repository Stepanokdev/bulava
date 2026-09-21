# The two small binaries the screenshot harness needs, and why each exists.
#
#   disclaim    — starts the demo Bulava as a process responsible for itself
#   windowshot  — photographs one window, run by a process that holds the grant
#
# Both are build products and neither is in git.
all: disclaim windowshot

disclaim: disclaim.c
	clang -O2 -o $@ $<

windowshot: windowshot.swift
	swiftc -O -o $@ $<

clean:
	rm -f disclaim windowshot

# The three gameplay clips on the download page, recorded against the live results. Not part of
# `all`: it needs the network, it takes a minute and a half, and the clips only change when the
# games do.
gameplay:
	bash gameplay.sh
