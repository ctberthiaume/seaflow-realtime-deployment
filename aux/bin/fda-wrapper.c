// fda-wrapper.c
// A simple wrapper to run a binary with the necessary entitlements for full disk access on macOS.
// Compile with:
// clang -O2 -o fda-wrapper fda-wrapper.c
// Sign with:
// codesign -s - fda-wrapper
// Then grant "Full Disk Access" to the fda-wrapper binary in System Preferences.
// Now any binary executed via fda-wrapper will inherit the full disk access permissions,
// even if wrapped binaries change and have not been granted full disk access themselves.
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: fda-wrapper <path-to-binary> [args...]\n");
        return 1;
    }

    // Replace this process with the target process.
    execvp(argv[1], &argv[1]);

    // If execvp returns, there was an error:
    perror("execvp");
    return 1;
}
