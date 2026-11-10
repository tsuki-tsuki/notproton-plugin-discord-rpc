// Start the standalone relay only when NotProton loads this plugin.
#define _DARWIN_C_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static void start_bridge(void) __attribute__((constructor));
static void start_bridge(void)
{
    const char *enabled = getenv("NOTPROTON_DISCORD_PLUGIN");
    const char *root = getenv("CX_ROOT");
    const char *prefix = getenv("WINEPREFIX");
    if (!enabled || strcmp(enabled, "1") || !root || root[0] != '/' ||
        !prefix || prefix[0] != '/') return;

    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size)) return;
    const char *name = strrchr(executable, '/');
    if (!name || strcmp(name, "/wine")) return;

    Dl_info info;
    if (!dladdr((const void *)start_bridge, &info)) return;
    const char *slash = strrchr(info.dli_fname, '/');
    if (!slash || info.dli_fname[0] != '/') return;
    int length = (int)(slash - info.dli_fname);

#ifdef __arm64__
    const char *loader_suffix = "/lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine";
#else
    const char *loader_suffix = "/lib/wine/x86_64-unix/wine";
#endif
    char host[PATH_MAX], helper[PATH_MAX], loader[PATH_MAX], parent[32];
    if (snprintf(host, sizeof(host), "%.*s/host", length, info.dli_fname) >= (int)sizeof(host) ||
        snprintf(helper, sizeof(helper), "%.*s/notproton-discord.exe", length, info.dli_fname) >= (int)sizeof(helper) ||
        snprintf(loader, sizeof(loader), "%s%s", root, loader_suffix) >= (int)sizeof(loader) ||
        access(host, X_OK) || access(helper, R_OK) || access(loader, X_OK)) return;

    size_t count = 0;
    while (environ[count]) ++count;
    char **env = calloc(count + 1, sizeof(*env));
    if (!env) return;
    size_t kept = 0;
    for (size_t i = 0; i < count; ++i) {
        const char *entry = environ[i];
        if (!strncmp(entry, "DYLD_", 5) ||
            !strncmp(entry, "NOTPROTON_DISCORD_PLUGIN=", 25) ||
            !strncmp(entry, "NOTPROTON_FEATURE_DYLIBS=", 25) ||
            !strncmp(entry, "WINELOADER=", 11) ||
            !strncmp(entry, "WINEDLLPATH=", 12)) continue;
        env[kept++] = environ[i];
    }

    snprintf(parent, sizeof(parent), "%ld", (long)getpid());
    char *argv[] = {host, parent, loader, helper, NULL};
    pid_t child;
    int error = posix_spawn(&child, host, NULL, NULL, argv, env);
    free(env);
    if (!error) unsetenv("NOTPROTON_DISCORD_PLUGIN");
    else fprintf(stderr, "NotProton Discord: could not start bridge: %s\n", strerror(error));
}
