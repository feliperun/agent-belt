// External microphone: a client connects to the Unix socket, streams PCM and
// closes. The daemon must see start, every byte in order, then stop, and the
// next connection must be served after the first one ends.
#include "ext_mic.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int starts, stops;
static unsigned char received[1 << 16];
static size_t received_len;

static void on_start(void *ctx) {
    (void)ctx;
    pthread_mutex_lock(&lock);
    starts++;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
}

static void on_pcm(void *ctx, const void *pcm, size_t len) {
    (void)ctx;
    pthread_mutex_lock(&lock);
    assert(starts == stops + 1);  // audio only inside a session
    memcpy(received + received_len, pcm, len);
    received_len += len;
    pthread_mutex_unlock(&lock);
}

static void on_stop(void *ctx) {
    (void)ctx;
    pthread_mutex_lock(&lock);
    stops++;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
}

static void wait_stops(int n) {
    pthread_mutex_lock(&lock);
    while (stops < n) pthread_cond_wait(&changed, &lock);
    pthread_mutex_unlock(&lock);
}

static void talk(const char *path, const unsigned char *pcm, size_t len) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(fd >= 0);
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    assert(connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    for (size_t sent = 0; sent < len;) {  // small writes, like a network stream
        size_t n = len - sent < 1000 ? len - sent : 1000;
        assert(write(fd, pcm + sent, n) == (ssize_t)n);
        sent += n;
    }
    close(fd);
}

int main(void) {
    char path[] = "/tmp/agb-ext-mic-test.XXXXXX";
    assert(mkdtemp(path));
    char sock[128];
    snprintf(sock, sizeof(sock), "%s/mic.sock", path);

    mk_ext_mic_handlers handlers = {on_start, on_pcm, on_stop};
    assert(mk_ext_mic_listen(sock, handlers, NULL) == 0);

    struct stat st;
    assert(stat(sock, &st) == 0);
    assert((st.st_mode & 0777) == 0600);  // only this user may speak into the daemon

    unsigned char first[5000], second[3000];
    for (size_t i = 0; i < sizeof(first); i++) first[i] = (unsigned char)(i * 7);
    for (size_t i = 0; i < sizeof(second); i++) second[i] = (unsigned char)(i * 13 + 1);

    talk(sock, first, sizeof(first));
    wait_stops(1);
    talk(sock, second, sizeof(second));
    wait_stops(2);

    pthread_mutex_lock(&lock);
    assert(starts == 2 && stops == 2);
    assert(received_len == sizeof(first) + sizeof(second));
    assert(memcmp(received, first, sizeof(first)) == 0);
    assert(memcmp(received + sizeof(first), second, sizeof(second)) == 0);
    pthread_mutex_unlock(&lock);

    unlink(sock);
    rmdir(path);
    puts("ext_mic_test: ok");
    return 0;
}
