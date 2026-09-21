// Start a program that is responsible for itself.
//
// macOS decides a process's privacy rights by its RESPONSIBLE process, which a child inherits
// from whoever spawned it. Bulava holds Screen Recording; a shell does not. So a Bulava started
// from a script inherits the script's lack of a grant, and ScreenCaptureKit answers "the user
// declined" — with the toggle for Bulava plainly switched on in System Settings, because the
// toggle was never the thing being asked about.
//
// `responsibility_spawnattrs_setdisclaim` is how a launcher says "this child answers for itself".
// It is the same mechanism terminal emulators use so that a program they start is asked about by
// its own name rather than theirs.
//
//   disclaim /Applications/Bulava.app/Contents/MacOS/Bulava -AppleLanguages "(en)"
//
// Prints the pid. The environment is passed through, which is what keeps the demo instance
// pointed at its own throwaway state.
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: disclaim <program> [args...]\n");
        return 2;
    }

    posix_spawnattr_t attrs;
    if (posix_spawnattr_init(&attrs) != 0) {
        fprintf(stderr, "disclaim: cannot initialise spawn attributes\n");
        return 3;
    }

    // Resolved at run time rather than linked: it lives in libsystem and is not in a public
    // header, so a direct call would tie this file to one SDK.
    int (*setdisclaim)(posix_spawnattr_t *, int) =
        (int (*)(posix_spawnattr_t *, int))dlsym(RTLD_DEFAULT,
                                                 "responsibility_spawnattrs_setdisclaim");
    if (setdisclaim == NULL) {
        fprintf(stderr, "disclaim: this macOS has no responsibility_spawnattrs_setdisclaim\n");
        return 4;
    }
    if (setdisclaim(&attrs, 1) != 0) {
        fprintf(stderr, "disclaim: the child could not be made responsible for itself\n");
        return 5;
    }

    // The child's standard streams go to DISCLAIM_LOG, or nowhere. Without this it inherits the
    // caller's, and a caller reading our pid through `$( )` waits for a pipe the application will
    // hold open for as long as it runs — which reads exactly like a hang.
    posix_spawn_file_actions_t files;
    posix_spawn_file_actions_init(&files);
    const char *log = getenv("DISCLAIM_LOG");
    if (log == NULL || log[0] == '\0') { log = "/dev/null"; }
    posix_spawn_file_actions_addopen(&files, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&files, STDOUT_FILENO, log, O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_adddup2(&files, STDOUT_FILENO, STDERR_FILENO);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[1], &files, &attrs, &argv[1], environ);
    posix_spawn_file_actions_destroy(&files);
    posix_spawnattr_destroy(&attrs);
    if (rc != 0) {
        fprintf(stderr, "disclaim: %s: %s\n", argv[1], strerror(rc));
        return 6;
    }
    printf("%d\n", pid);
    return 0;
}
