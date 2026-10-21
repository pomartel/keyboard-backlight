// SPDX-License-Identifier: MIT
// Wait for Wayland output-power, Omarchy lock journal, and keyboard LED events.
// No periodic timers, sleep loops, or periodic state queries.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/timerfd.h>
#include <systemd/sd-journal.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

// Wire definitions from wlr-output-power-management-unstable-v1 (version 1).
// The watcher only subscribes; it never sends set_mode.
static const struct wl_message power_requests[] = {{"set_mode", "u", NULL}, {"destroy", "", NULL}};
static const struct wl_message power_events[] = {{"mode", "u", NULL}, {"failed", "", NULL}};
static const struct wl_interface power_interface = {
    "zwlr_output_power_v1", 1, 2, power_requests, 2, power_events};
static const struct wl_interface *get_power_types[] = {&power_interface, &wl_output_interface};
static const struct wl_message manager_requests[] = {
    {"get_output_power", "no", get_power_types}, {"destroy", "", NULL}};
static const struct wl_interface manager_interface = {
    "zwlr_output_power_manager_v1", 1, 2, manager_requests, 0, NULL};

struct output {
    uint32_t name;
    struct wl_output *output;
    struct wl_proxy *power;
    bool failed;
    struct output *next;
};
static struct output *outputs;
static struct wl_proxy *manager;
static uint32_t manager_name;
static bool manager_removed;

static void changed(void) {
    puts("change");
    fflush(stdout);
}

static void clock_changed(void) {
    puts("clock");
    fflush(stdout);
}

static void output_availability(void) {
    for (struct output *output = outputs; output; output = output->next) {
        if (output->failed) {
            puts("outputs-blocked");
            fflush(stdout);
            return;
        }
    }
    puts("outputs-ready");
    fflush(stdout);
}

static int arm_clock_watch(int fd) {
    struct itimerspec timer = {0};
    if (clock_gettime(CLOCK_REALTIME, &timer.it_value) < 0) return -1;
    // This one-shot stays dormant for a century. The kernel cancels it on a
    // clock step, which wakes poll immediately without periodic comparisons.
    timer.it_value.tv_sec += (time_t)100 * 366 * 86400;
    return timerfd_settime(fd, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET, &timer, NULL);
}

static int clock_events(int fd) {
    uint64_t expirations;
    ssize_t count = read(fd, &expirations, sizeof(expirations));
    if (count == -1 && (errno == EAGAIN || errno == EINTR)) return 0;
    if (count != sizeof(expirations) && !(count == -1 && errno == ECANCELED)) return -1;
    if (arm_clock_watch(fd) < 0) return -1;
    clock_changed();
    return 0;
}

static int timezone_file_watch = -1;

static int watch_timezone(int fd, const char *directory, const char *localtime) {
    if (inotify_add_watch(fd, directory, IN_CREATE | IN_MOVED_TO | IN_MOVED_FROM |
                          IN_DELETE | IN_CLOSE_WRITE | IN_ATTRIB) < 0) return -1;
    // Also notice writes through the symlink and replacement of its target.
    // A missing /etc/localtime is valid (UTC); the directory watch catches creation.
    int replacement = inotify_add_watch(fd, localtime, IN_CLOSE_WRITE | IN_ATTRIB |
                                       IN_MOVE_SELF | IN_DELETE_SELF);
    if (replacement < 0 && errno != ENOENT) return -1;
    if (timezone_file_watch >= 0 && timezone_file_watch != replacement)
        inotify_rm_watch(fd, timezone_file_watch);
    timezone_file_watch = replacement;
    return 0;
}

static int timezone_events(int fd, const char *directory, const char *localtime) {
    char buffer[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
    bool changed_zone = false;
    ssize_t count;
    while ((count = read(fd, buffer, sizeof(buffer))) > 0) {
        for (char *entry = buffer; entry < buffer + count;) {
            struct inotify_event *event = (struct inotify_event *)entry;
            if (event->mask & IN_Q_OVERFLOW) changed_zone = true;
            else if (!(event->mask & IN_IGNORED) &&
                     (!event->len || !strcmp(event->name, "localtime") || !strcmp(event->name, "timezone")))
                changed_zone = true;
            entry += sizeof(*event) + event->len;
        }
    }
    if (count < 0 && errno != EAGAIN && errno != EINTR) return -1;
    if (changed_zone) {
        if (watch_timezone(fd, directory, localtime) < 0) return -1;
        clock_changed();
    }
    return 0;
}

static void power_mode(void *data, struct wl_proxy *power, uint32_t mode) {
    (void)data; (void)power; (void)mode;
    changed();
}

static void power_failed(void *data, struct wl_proxy *power) {
    struct output *output = data;
    wl_proxy_marshal_flags(power, 1, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
    output->power = NULL;
    output->failed = true;
    // failed can precede global_remove during a normal unplug. Keep the
    // journal, clock, and other outputs alive; the keyboard stays off until
    // the defunct output is removed from the registry.
    output_availability();
}

static void (*power_listener[])(void) = {
    (void (*)(void))power_mode, (void (*)(void))power_failed};

static void watch_output(struct output *output) {
    if (!manager || output->power || output->failed) return;
    output->power = wl_proxy_marshal_flags(manager, 0, &power_interface, 1, 0, NULL, output->output);
    wl_proxy_add_listener(output->power, power_listener, output);
}

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, manager_interface.name)) {
        manager_name = name;
        manager = wl_registry_bind(registry, name, &manager_interface, 1);
        for (struct output *output = outputs; output; output = output->next) watch_output(output);
    } else if (!strcmp(interface, wl_output_interface.name)) {
        struct output *output = calloc(1, sizeof(*output));
        if (!output) exit(EXIT_FAILURE);
        output->name = name;
        output->output = wl_registry_bind(registry, name, &wl_output_interface, 1);
        output->next = outputs;
        outputs = output;
        watch_output(output);
        changed();
    }
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry;
    if (name == manager_name) manager_removed = true;
    for (struct output **entry = &outputs; *entry; entry = &(*entry)->next) {
        struct output *output = *entry;
        if (output->name != name) continue;
        if (output->power) wl_proxy_marshal_flags(output->power, 1, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
        wl_output_destroy(output->output);
        *entry = output->next;
        free(output);
        output_availability();
        break;
    }
    changed();
}

static const struct wl_registry_listener registry_listener = {global, global_remove};

static bool lock_event(const char *message) {
    const char *prefix = strstr(message, "omarchy lock ");
    if (!prefix) return false;
    // Only state transitions, not authentication attempts or fingerprint logs.
    return strstr(prefix, " lock-requested") || strstr(prefix, " unlocked") ||
           strstr(prefix, " session-locked=") || strstr(prefix, " secure=");
}

static void journal_events(sd_journal *journal) {
    const void *data;
    size_t size;
    while (sd_journal_next(journal) > 0) {
        if (sd_journal_get_data(journal, "MESSAGE", &data, &size) < 0 || size > 4096) continue;
        char message[4097];
        memcpy(message, data, size);
        message[size] = '\0';
        if (lock_event(message)) changed();
    }
}

int main(int argc, char **argv) {
    sd_journal *journal = NULL;
    if (sd_journal_open(&journal, SD_JOURNAL_CURRENT_USER | SD_JOURNAL_LOCAL_ONLY) < 0 ||
        sd_journal_add_match(journal, "_COMM=quickshell", 0) < 0 ||
        sd_journal_seek_tail(journal) < 0) {
        fputs("Cannot subscribe to Omarchy lock journal events\n", stderr);
        return EXIT_FAILURE;
    }
    sd_journal_previous(journal);

    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return EXIT_FAILURE;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager || wl_display_roundtrip(display) < 0) {
        fputs("Cannot subscribe to Wayland output-power events\n", stderr);
        return EXIT_FAILURE;
    }

    int led = argc == 2 ? open(argv[1], O_RDONLY | O_CLOEXEC) : -1;
    int clock_fd = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC);
    int timezone_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (clock_fd < 0 || timezone_fd < 0 || arm_clock_watch(clock_fd) < 0 ||
        watch_timezone(timezone_fd, "/etc", "/etc/localtime") < 0) {
        fputs("Cannot subscribe to system clock changes\n", stderr);
        return EXIT_FAILURE;
    }
    char brightness[32];
    if (led >= 0) (void)pread(led, brightness, sizeof(brightness), 0);
    struct pollfd fds[] = {
        {wl_display_get_fd(display), POLLIN, 0},
        {sd_journal_get_fd(journal), sd_journal_get_events(journal), 0},
        {led, POLLPRI, 0},
        {clock_fd, POLLIN, 0},
        {timezone_fd, POLLIN, 0}};
    clock_changed(); // Refresh QML's timezone cache before the first deadline.
    changed(); // Initial snapshot, after all event subscriptions are in place.

    for (;;) {
        while (wl_display_prepare_read(display) != 0) {
            if (wl_display_dispatch_pending(display) < 0) return EXIT_FAILURE;
        }
        fds[0].events = POLLIN;
        if (wl_display_flush(display) < 0) {
            if (errno != EAGAIN) { wl_display_cancel_read(display); return EXIT_FAILURE; }
            fds[0].events |= POLLOUT;
        }
        int result = poll(fds, 5, -1);
        if (result < 0) {
            wl_display_cancel_read(display);
            if (errno == EINTR) continue;
            return EXIT_FAILURE;
        }
        if (fds[0].revents & POLLIN) {
            if (wl_display_read_events(display) < 0) return EXIT_FAILURE;
        } else wl_display_cancel_read(display);
        if (fds[0].revents & (POLLHUP | POLLERR | POLLNVAL)) return EXIT_FAILURE;
        if (wl_display_dispatch_pending(display) < 0 || manager_removed) return EXIT_FAILURE;
        if (fds[1].revents) {
            if (sd_journal_process(journal) < 0) return EXIT_FAILURE;
            journal_events(journal);
            fds[1].events = sd_journal_get_events(journal);
        }
        if (fds[2].revents & POLLPRI) {
            (void)pread(led, brightness, sizeof(brightness), 0);
            changed();
        } else if (fds[2].revents) {
            close(led);
            fds[2].fd = led = -1;
        }
        if (fds[3].revents && clock_events(clock_fd) < 0) return EXIT_FAILURE;
        if (fds[4].revents && timezone_events(timezone_fd, "/etc", "/etc/localtime") < 0) return EXIT_FAILURE;
    }
}
