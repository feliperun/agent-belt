#include "ext_mic.h"

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

struct mk_ext_mic {
    int fd;
    mk_ext_mic_handlers handlers;
    void *context;
};

// Sessions one after another: a second client waits in the backlog until the
// first one lets go, as a second press of a held key would be ignored.
static void *mk_ext_mic_serve(void *arg) {
    struct mk_ext_mic *mic = arg;
    unsigned char buffer[4096];
    for (;;) {
        int client = accept(mic->fd, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            break;
        }
        mic->handlers.on_start(mic->context);
        for (;;) {
            ssize_t n = read(client, buffer, sizeof(buffer));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            mic->handlers.on_pcm(mic->context, buffer, (size_t)n);
        }
        close(client);
        mic->handlers.on_stop(mic->context);
    }
    close(mic->fd);
    free(mic);
    return NULL;
}

int mk_ext_mic_listen(const char *path, mk_ext_mic_handlers handlers, void *context) {
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (strlen(path) >= sizeof(addr.sun_path)) return -ENAMETOOLONG;
    strcpy(addr.sun_path, path);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -errno;
    unlink(path);  // a socket left by a previous daemon
    // Created owner-only: no window where another user could connect.
    mode_t old_mask = umask(0077);
    int bound = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    umask(old_mask);
    if (bound != 0 || chmod(path, 0600) != 0 || listen(fd, 1) != 0) {
        int err = errno;
        close(fd);
        return -err;
    }

    struct mk_ext_mic *mic = malloc(sizeof(*mic));
    if (!mic) {
        close(fd);
        return -ENOMEM;
    }
    *mic = (struct mk_ext_mic){.fd = fd, .handlers = handlers, .context = context};
    pthread_t thread;
    if (pthread_create(&thread, NULL, mk_ext_mic_serve, mic) != 0) {
        close(fd);
        free(mic);
        return -EAGAIN;
    }
    pthread_detach(thread);
    return 0;
}
