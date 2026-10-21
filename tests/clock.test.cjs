const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

test('native clock notifications: cancellation, timezone writes, and atomic replacement', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'backlight-clock-test-'));
  try {
    const source = `
      #define main watcher_main
      #define read test_read
      #define puts test_puts
      #include ${JSON.stringify(path.resolve(__dirname, '../src/watch-session.c'))}
      #undef main
      #undef read
      #undef puts
      #include <assert.h>
      #include <sys/syscall.h>

      static bool cancel_clock;
      static int clock_messages;
      ssize_t test_read(int fd, void *buffer, size_t size) {
        if (cancel_clock) { cancel_clock = false; errno = ECANCELED; return -1; }
        return syscall(SYS_read, fd, buffer, size);
      }
      int test_puts(const char *line) {
        if (!strcmp(line, "clock")) clock_messages++;
        return 0;
      }
      static void write_file(const char *path) {
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        assert(fd >= 0);
        assert(write(fd, "zone", 4) == 4);
        close(fd);
      }
      int main(int argc, char **argv) {
        assert(argc == 2);
        int clock_fd = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC);
        assert(clock_fd >= 0 && arm_clock_watch(clock_fd) == 0);
        assert(clock_events(clock_fd) == 0); // EAGAIN: no spurious clock event.
        assert(clock_messages == 0);
        // Simulate the kernel's ECANCELED read without changing the host clock.
        cancel_clock = true;
        assert(clock_events(clock_fd) == 0);
        assert(clock_messages == 1);
        struct itimerspec armed;
        assert(timerfd_gettime(clock_fd, &armed) == 0);
        assert(armed.it_value.tv_sec > 86400);
        assert(armed.it_interval.tv_sec == 0 && armed.it_interval.tv_nsec == 0);

        int zone_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
        char localtime[1024], unrelated[1024], replacement[1024];
        snprintf(localtime, sizeof(localtime), "%s/localtime", argv[1]);
        snprintf(unrelated, sizeof(unrelated), "%s/unrelated", argv[1]);
        snprintf(replacement, sizeof(replacement), "%s/new-zone", argv[1]);
        write_file(localtime);
        assert(watch_timezone(zone_fd, argv[1], localtime) == 0);
        write_file(unrelated);
        assert(timezone_events(zone_fd, argv[1], localtime) == 0);
        assert(clock_messages == 1);
        write_file(localtime);
        assert(timezone_events(zone_fd, argv[1], localtime) == 0);
        assert(clock_messages == 2);
        write_file(replacement);
        assert(rename(replacement, localtime) == 0);
        assert(timezone_events(zone_fd, argv[1], localtime) == 0);
        assert(clock_messages == 3);
        // Rearming must subscribe to the replacement inode, too.
        write_file(localtime);
        assert(timezone_events(zone_fd, argv[1], localtime) == 0);
        assert(clock_messages == 4);
        close(zone_fd);
        close(clock_fd);
        return 0;
      }
    `;
    const binary = path.join(dir, 'test');
    execFileSync('cc', ['-std=c11', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror',
      '-x', 'c', '-', '-lwayland-client', '-lsystemd', '-o', binary], { input: source });
    execFileSync(binary, [dir]);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
