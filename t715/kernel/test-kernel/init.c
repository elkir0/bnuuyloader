/* The only program of the first arm64 boot test's initramfs. It writes what it finds into the
   kernel log (which the sec_log console mirrors into Samsung's RAM ring, where S-Boot's own log
   goes too), then restarts the tablet by software. No shell, no busbox: one static binary. */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int kmsg;

static void say(const char *text) {
    write(kmsg, text, strlen(text));
}

/* The watchdog ioctls, without the kernel's header. */
#define WDIOC_SETTIMEOUT _IOWR('W', 6, int)
#define WDIOC_KEEPALIVE _IOR('W', 5, int)

static void sayf(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void sayf(const char *format, ...) {
    char buffer[2048];
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(buffer, sizeof(buffer), format, arguments);
    va_end(arguments);
    if (length > 0) {
        write(kmsg, buffer, (size_t)length);
    }
}

/* The content of a file, each line preceded by a tag, or only the lines holding one of the words. */
static void show(const char *path, const char *const *words) {
    int file = open(path, O_RDONLY);
    if (file < 0) {
        sayf("<6>T715-ARM64: %s: not readable (%m)\n", path);
        return;
    }
    char buffer[65536];
    char line[4096];
    size_t used = 0;
    ssize_t got;
    int shown = 0;
    while ((got = read(file, buffer, sizeof(buffer))) > 0) {
        for (ssize_t i = 0; i < got; i++) {
            if (buffer[i] != '\n' && used < sizeof(line) - 1) {
                line[used++] = buffer[i];
                continue;
            }
            line[used] = 0;
            used = 0;
            if (!line[0]) {
                continue;
            }
            int wanted = 1;
            for (const char *const *word = words; words && *word; word++) {
                wanted = strstr(line, *word) != NULL;
                if (wanted) {
                    break;
                }
            }
            if (wanted) {
                sayf("<6>T715-ARM64:   %s\n", line);
                shown = 1;
            }
        }
    }
    close(file);
    if (!shown) {
        sayf("<6>T715-ARM64:   (no line shown from %s)\n", path);
    }
}

static void read_into(const char *path, char *out, size_t size) {
    out[0] = 0;
    int file = open(path, O_RDONLY);
    if (file < 0) {
        return;
    }
    ssize_t got = read(file, out, size - 1);
    close(file);
    if (got > 0) {
        out[got] = 0;
        for (char *p = out; *p; p++) {
            if (*p == '\n') {
                *p = 0;
                break;
            }
        }
    } else {
        out[0] = 0;
    }
}

/* ---- The load test (only with t715.load=N on the command line, N seconds, at most 60) ----
   One process pinned to each CPU spins; every second the thermal zones are read and logged; the
   load stops early when a zone reaches LOAD_STOP_MC.  Nothing here changes a clock or a voltage:
   the cores stay where S-Boot left them.  The busy time each CPU accumulated (/proc/stat) shows
   that every core ran code, not only that the kernel counted it as online. */
#define LOAD_MAX_CPUS 8
#define LOAD_MAX_ZONES 8
#define LOAD_STOP_MC 75000

static int load_seconds(void) {
    char line[4096];
    read_into("/proc/cmdline", line, sizeof(line));
    const char *at = strstr(line, "t715.load=");
    if (!at) {
        return 0;
    }
    int seconds = atoi(at + strlen("t715.load="));
    if (seconds < 0) {
        seconds = 0;
    }
    return seconds > 60 ? 60 : seconds;
}

/* busy and idle jiffies of cpuN from /proc/stat; returns 0 when the line is missing */
static int cpu_times(int cpu, unsigned long long *busy, unsigned long long *idle) {
    char buffer[8192];
    int file = open("/proc/stat", O_RDONLY);
    if (file < 0) {
        return 0;
    }
    ssize_t got = read(file, buffer, sizeof(buffer) - 1);
    close(file);
    if (got <= 0) {
        return 0;
    }
    buffer[got] = 0;
    char tag[16];
    snprintf(tag, sizeof(tag), "\ncpu%d ", cpu);
    const char *line = strstr(buffer, tag);
    if (!line) {
        return 0;
    }
    unsigned long long user, nice, system, idle_time, iowait, irq, softirq;
    if (sscanf(line + strlen(tag), "%llu %llu %llu %llu %llu %llu %llu", &user, &nice, &system, &idle_time, &iowait, &irq,
               &softirq) != 7) {
        return 0;
    }
    *busy = user + nice + system + irq + softirq;
    *idle = idle_time + iowait;
    return 1;
}

static int read_zone(int zone, long *millicelsius) {
    char path[96], text[64];
    snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/temp", zone);
    read_into(path, text, sizeof(text));
    if (!text[0]) {
        return 0;
    }
    *millicelsius = atol(text);
    return 1;
}

static void spin_until(time_t deadline) {
    volatile unsigned long long x = 0x9e3779b97f4a7c15ull;
    struct timespec now;
    for (;;) {
        for (int i = 0; i < 1000000; i++) {
            x = x * 6364136223846793005ull + 1442695040888963407ull;
        }
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec >= deadline) {
            _exit(0);
        }
    }
}

/* returns the watchdog's descriptor, kept open and fed during the load (or -1) */
static int load_test(int seconds) {
    int watchdog = open("/dev/watchdog", O_WRONLY);
    int timeout = 30;
    if (watchdog >= 0 && ioctl(watchdog, WDIOC_SETTIMEOUT, &timeout) == 0) {
        sayf("<6>T715-ARM64: load: init holds the watchdog (timeout %d s) and feeds it during the load\n", timeout);
    } else {
        say("<4>T715-ARM64: load: init could not take the watchdog; the load runs without it\n");
    }
    for (int zone = 0; zone < LOAD_MAX_ZONES; zone++) {
        char path[96], type[64];
        snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/type", zone);
        read_into(path, type, sizeof(type));
        if (type[0]) {
            sayf("<6>T715-ARM64: load: zone %d is %s\n", zone, type);
        }
    }
    unsigned long long busy0[LOAD_MAX_CPUS] = {0}, idle0[LOAD_MAX_CPUS] = {0};
    int counted[LOAD_MAX_CPUS] = {0};
    for (int cpu = 0; cpu < LOAD_MAX_CPUS; cpu++) {
        counted[cpu] = cpu_times(cpu, &busy0[cpu], &idle0[cpu]);
    }
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    time_t deadline = start.tv_sec + seconds;
    pid_t children[LOAD_MAX_CPUS] = {0};
    int started = 0;
    for (int cpu = 0; cpu < LOAD_MAX_CPUS; cpu++) {
        if (!counted[cpu]) {
            continue;
        }
        pid_t child = fork();
        if (child == 0) {
            cpu_set_t set;
            CPU_ZERO(&set);
            CPU_SET(cpu, &set);
            if (sched_setaffinity(0, sizeof(set), &set) != 0) {
                _exit(2);
            }
            spin_until(deadline);
        }
        if (child > 0) {
            children[cpu] = child;
            started++;
        }
    }
    sayf("<5>T715-ARM64: load: %d spinning processes, one per online CPU, for %d s (stop at %ld mC)\n", started, seconds,
         (long)LOAD_STOP_MC);
    long hottest = 0;
    int stopped_hot = 0;
    for (int second = 1; second <= seconds; second++) {
        struct timespec pause = {1, 0};
        nanosleep(&pause, NULL);
        if (watchdog >= 0) {
            ioctl(watchdog, WDIOC_KEEPALIVE, 0);
        }
        char line[512];
        int used = snprintf(line, sizeof(line), "<6>T715-ARM64: load t=%2d s: mC", second);
        for (int zone = 0; zone < LOAD_MAX_ZONES; zone++) {
            long temperature;
            if (read_zone(zone, &temperature)) {
                used += snprintf(line + used, sizeof(line) - (size_t)used, " %ld", temperature);
                if (temperature > hottest) {
                    hottest = temperature;
                }
                if (temperature >= LOAD_STOP_MC) {
                    stopped_hot = 1;
                }
            }
        }
        snprintf(line + used, sizeof(line) - (size_t)used, "\n");
        say(line);
        if (stopped_hot) {
            sayf("<4>T715-ARM64: load: a zone reached %ld mC: the load stops at %d s\n", hottest, second);
            break;
        }
    }
    for (int cpu = 0; cpu < LOAD_MAX_CPUS; cpu++) {
        if (children[cpu] > 0) {
            kill(children[cpu], SIGKILL);
        }
    }
    for (int cpu = 0; cpu < LOAD_MAX_CPUS; cpu++) {
        if (children[cpu] > 0) {
            int status = 0;
            waitpid(children[cpu], &status, 0);
            if (WIFEXITED(status) && WEXITSTATUS(status) == 2) {
                sayf("<4>T715-ARM64: load: cpu%d refused the affinity\n", cpu);
            }
        }
    }
    for (int cpu = 0; cpu < LOAD_MAX_CPUS; cpu++) {
        unsigned long long busy, idle;
        if (counted[cpu] && cpu_times(cpu, &busy, &idle)) {
            sayf("<6>T715-ARM64: load: cpu%d busy %llu idle %llu jiffies during the load\n", cpu, busy - busy0[cpu],
                 idle - idle0[cpu]);
        }
    }
    sayf("<5>T715-ARM64: load: over; hottest zone %ld mC%s\n", hottest, stopped_hot ? " (stopped early)" : "");
    return watchdog;
}

/* ---- The CPU frequency and cooling test (only with t715.cpufreq=1) ----
   Stage 1 of the owner's docs/hardware/CPUFREQ.md (section 9, written for the 32-bit port), on the
   arm64 kernel: both clusters capped at 1.2 GHz, where S-Boot leaves them (scaling_max_freq, before
   the governor can choose anything); each level checked (the clock as the clock driver reads it, the
   rail against this chip's own OPP voltage, a hash on every core of the cluster); transitions under
   load; the cooling maps through emulated temperatures; then a real eight-core load with the cooling
   acting, its passive trips lowered for the test (68 and 75 degrees) so that it acts well below the
   project's 85-degree limit.  Any wrong hash, clock or rail ends the test at once. */

#define CF_WORDS (1 << 18)                       /* 2 MiB of 64-bit words, per process */
#define CF_SEED 0x7e5e7026ull
#define CF_ROUNDS 100                            /* one hash: about 0.2 s at 1.2 GHz */
#define CF_SHORT 10
#define CF_STOP_MC 85000                         /* the project's rule for any zone */
#define CF_MAX_KHZ 1200000                       /* stage 1: no level above 1.2 GHz is used */

static uint64_t cf_buffer[CF_WORDS];
static int cf_watchdog = -1;
static int cf_failed;
static uint64_t cf_ref, cf_ref_short;
static volatile int *cf_stop;

struct cf_policy {
    const char *name;
    int first_cpu, ncpus;
    const char *rail;
    char dir[96], rail_path[400], cdev[320];
};

static struct cf_policy cf_policies[2] = {
    {"A53", 0, 4, "vdd_kfc", "/sys/devices/system/cpu/cpufreq/policy0", "", ""},
    {"A57", 4, 4, "vdd_eagle", "/sys/devices/system/cpu/cpufreq/policy4", "", ""},
};

/* This chip's own OPPs (ASV group 1, the board's -cpufreq.dtsi), for the levels the steps use */
static const long cf_a53_khz[] = {400000, 800000, 1200000}, cf_a53_uv[] = {875000, 1000000, 1162500};
static const long cf_a57_khz[] = {800000, 1000000, 1200000}, cf_a57_uv[] = {987500, 1012500, 1062500};

static void cf_feed(void) {
    if (cf_watchdog >= 0) {
        ioctl(cf_watchdog, WDIOC_KEEPALIVE, 0);
    }
}

static void cf_rest(int ms) {
    while (ms > 0) {
        int step = ms > 500 ? 500 : ms;
        struct timespec pause = {step / 1000, (long)(step % 1000) * 1000000L};
        nanosleep(&pause, NULL);
        cf_feed();
        ms -= step;
    }
}

static long read_long(const char *path) {
    char text[64];
    read_into(path, text, sizeof(text));
    return text[0] ? atol(text) : -1;
}

static int write_text(const char *path, const char *text) {
    int file = open(path, O_WRONLY);
    if (file < 0) {
        sayf("<4>T715-ARM64: cpufreq: cannot open %s (%m)\n", path);
        return -1;
    }
    ssize_t done = write(file, text, strlen(text));
    int saved = errno;
    close(file);
    if (done < 0) {
        errno = saved;
        sayf("<4>T715-ARM64: cpufreq: writing '%s' to %s failed (%m)\n", text, path);
        return -1;
    }
    return 0;
}

static int write_long(const char *path, long number) {
    char text[32];
    snprintf(text, sizeof(text), "%ld", number);
    return write_text(path, text);
}

static void policy_file(const struct cf_policy *p, const char *file, char *out, size_t size) {
    snprintf(out, size, "%s/%s", p->dir, file);
}

static long policy_long(const struct cf_policy *p, const char *file) {
    char path[320];
    policy_file(p, file, path, sizeof(path));
    return read_long(path);
}

static int policy_write(const struct cf_policy *p, const char *file, const char *text) {
    char path[320];
    policy_file(p, file, path, sizeof(path));
    return write_text(path, text);
}

static int policy_write_long(const struct cf_policy *p, const char *file, long number) {
    char path[320];
    policy_file(p, file, path, sizeof(path));
    return write_long(path, number);
}

/* the sysfs directory of the first entry of `class` whose `name_file` reads `wanted` */
static int find_in_class(const char *class, const char *prefix, const char *name_file, const char *wanted, char *out,
                         size_t size) {
    DIR *dir = opendir(class);
    if (!dir) {
        return 0;
    }
    struct dirent *entry;
    int found = 0;
    while (!found && (entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, prefix, strlen(prefix)) != 0) {
            continue;
        }
        char path[600], text[96];
        snprintf(path, sizeof(path), "%s/%s/%s", class, entry->d_name, name_file);
        read_into(path, text, sizeof(text));
        if (strcmp(text, wanted) == 0) {
            snprintf(out, size, "%s/%s", class, entry->d_name);
            found = 1;
        }
    }
    closedir(dir);
    return found;
}

static int zone_index(const char *type) {
    char dir[320];
    if (!find_in_class("/sys/class/thermal", "thermal_zone", "type", type, dir, sizeof(dir))) {
        return -1;
    }
    return atoi(strrchr(dir, '/') + strlen("/thermal_zone"));
}

static void zones_text(char *out, size_t size, long *hottest) {
    int used = snprintf(out, size, "mC");
    for (int zone = 0; zone < LOAD_MAX_ZONES; zone++) {
        long temperature;
        if (read_zone(zone, &temperature)) {
            used += snprintf(out + used, size - (size_t)used, " %ld", temperature);
            if (hottest && temperature > *hottest) {
                *hottest = temperature;
            }
        }
    }
}

static long cdev_state(const struct cf_policy *p) {
    char path[400];
    snprintf(path, sizeof(path), "%s/cur_state", p->cdev);
    return p->cdev[0] ? read_long(path) : -1;
}

static uint64_t cf_work(uint64_t seed, int rounds) {
    uint64_t x = seed, h = 0xcbf29ce484222325ull;
    for (int r = 0; r < rounds; r++) {
        for (int i = 0; i < CF_WORDS; i++) {
            x = x * 6364136223846793005ull + 1442695040888963407ull;
            cf_buffer[i] = x ^ (x >> 29);
        }
        for (int i = 0; i < CF_WORDS; i++) {
            h = (h ^ cf_buffer[i]) * 0x100000001b3ull;
            h = ((h << 7) | (h >> 57)) + cf_buffer[(i * 7919u) & (CF_WORDS - 1)];
        }
    }
    return h;
}

static int pin(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    return sched_setaffinity(0, sizeof(set), &set);
}

/* one hash on each of `n` CPUs from `first`, at once: how many came out right */
static int cf_hash_on(int first, int n, double *seconds) {
    int pipes[LOAD_MAX_CPUS][2];
    pid_t kids[LOAD_MAX_CPUS];
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int k = 0; k < n; k++) {
        kids[k] = -1;
        if (pipe(pipes[k]) != 0) {
            continue;
        }
        kids[k] = fork();
        if (kids[k] == 0) {
            if (pin(first + k) != 0) {
                _exit(2);
            }
            uint64_t h = cf_work(CF_SEED, CF_ROUNDS);
            ssize_t ignored = write(pipes[k][1], &h, sizeof(h));
            (void)ignored;
            _exit(0);
        }
        close(pipes[k][1]);
    }
    int right = 0;
    for (int k = 0; k < n; k++) {
        if (kids[k] < 0) {
            continue;
        }
        uint64_t h = 0;
        if (read(pipes[k][0], &h, sizeof(h)) == (ssize_t)sizeof(h) && h == cf_ref) {
            right++;
        }
        close(pipes[k][0]);
        waitpid(kids[k], NULL, 0);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    *seconds = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;
    cf_feed();
    return right;
}

/* a worker for the storm and the load: short hashes until the deadline or the stop flag; it writes
   how many it ran and how many were wrong */
static pid_t cf_worker(int cpu, time_t deadline, int fd) {
    pid_t kid = fork();
    if (kid != 0) {
        return kid;
    }
    uint64_t counts[2] = {0, 0};
    if (pin(cpu) != 0) {
        counts[1] = 1;
    } else {
        struct timespec now;
        do {
            if (cf_work(CF_SEED, CF_SHORT) != cf_ref_short) {
                counts[1]++;
            }
            counts[0]++;
            clock_gettime(CLOCK_MONOTONIC, &now);
        } while (now.tv_sec < deadline && !*cf_stop);
    }
    ssize_t ignored = write(fd, counts, sizeof(counts));
    (void)ignored;
    _exit(0);
}

struct cf_crew {
    pid_t kids[LOAD_MAX_CPUS];
    int fds[LOAD_MAX_CPUS];
    int n;
};

static void crew_start(struct cf_crew *crew, int first, int n, time_t deadline) {
    *cf_stop = 0;
    crew->n = 0;
    for (int k = 0; k < n; k++) {
        int p[2];
        if (pipe(p) != 0) {
            continue;
        }
        crew->kids[crew->n] = cf_worker(first + k, deadline, p[1]);
        close(p[1]);
        crew->fds[crew->n++] = p[0];
    }
}

/* stops the crew; returns the wrong hashes (and the runs in *runs) */
static unsigned long long crew_finish(struct cf_crew *crew, unsigned long long *runs) {
    *cf_stop = 1;
    unsigned long long wrong = 0;
    *runs = 0;
    for (int k = 0; k < crew->n; k++) {
        uint64_t counts[2] = {0, 1};
        if (read(crew->fds[k], counts, sizeof(counts)) != (ssize_t)sizeof(counts)) {
            counts[0] = 0;
            counts[1] = 1;
        }
        *runs += counts[0];
        wrong += counts[1];
        close(crew->fds[k]);
        waitpid(crew->kids[k], NULL, 0);
        cf_feed();
    }
    return wrong;
}

static void cf_fail(const char *what) {
    cf_failed = 1;
    sayf("<3>T715-ARM64: cpufreq: FAIL: %s: the test stops here\n", what);
}

static void cf_readout(void) {
    static const char *const files[] = {"scaling_driver", "related_cpus", "cpuinfo_min_freq", "cpuinfo_max_freq",
                                        "scaling_available_frequencies", "scaling_governor", "scaling_min_freq",
                                        "scaling_max_freq", "scaling_cur_freq", "cpuinfo_cur_freq", NULL};
    for (int i = 0; i < 2; i++) {
        const struct cf_policy *p = &cf_policies[i];
        for (const char *const *file = files; *file; file++) {
            char path[320], text[512];
            policy_file(p, *file, path, sizeof(path));
            read_into(path, text, sizeof(text));
            sayf("<6>T715-ARM64: cpufreq: %s %s: %s\n", p->name, *file, text[0] ? text : "(none)");
        }
        sayf("<6>T715-ARM64: cpufreq: %s rail %s: %ld uV; cooling device %s, state %ld of %ld\n", p->name, p->rail,
             read_long(p->rail_path), p->cdev[0] ? strrchr(p->cdev, '/') + 1 : "(none)", cdev_state(p),
             p->cdev[0] ? ({
                 char path[400];
                 snprintf(path, sizeof(path), "%s/max_state", p->cdev);
                 read_long(path);
             })
                        : -1);
    }
    /* each CPU zone's passive trips, and the cooling devices bound to each of them */
    static const char *const zones[] = {"atlas0-thermal", "atlas1-thermal", "apollo-thermal", NULL};
    for (const char *const *zone = zones; *zone; zone++) {
        int z = zone_index(*zone);
        if (z < 0) {
            sayf("<4>T715-ARM64: cpufreq: no zone %s\n", *zone);
            continue;
        }
        for (int trip = 0; trip < 16; trip++) {
            char path[320], type[32];
            snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/trip_point_%d_type", z, trip);
            read_into(path, type, sizeof(type));
            if (!type[0]) {
                break;
            }
            if (strcmp(type, "active") == 0) {
                continue;
            }
            snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/trip_point_%d_temp", z, trip);
            long temperature = read_long(path);
            char bound[256] = "";
            int used = 0;
            for (int c = 0; c < 32; c++) {
                char link[320], target[320];
                snprintf(link, sizeof(link), "/sys/class/thermal/thermal_zone%d/cdev%d_trip_point", z, c);
                if (read_long(link) != trip) {
                    continue;
                }
                snprintf(link, sizeof(link), "/sys/class/thermal/thermal_zone%d/cdev%d", z, c);
                ssize_t got = readlink(link, target, sizeof(target) - 1);
                if (got <= 0) {
                    continue;
                }
                target[got] = 0;
                char type_path[400], cdev_type[64];
                snprintf(type_path, sizeof(type_path), "/sys/class/thermal/thermal_zone%d/cdev%d/type", z, c);
                read_into(type_path, cdev_type, sizeof(cdev_type));
                used += snprintf(bound + used, sizeof(bound) - (size_t)used, " %s", cdev_type);
            }
            sayf("<6>T715-ARM64: cpufreq: zone %s trip %d: %s at %ld mC, bound:%s\n", *zone, trip, type, temperature,
                 bound[0] ? bound : " nothing");
        }
    }
}

/* one policy, its levels low to high; returns 0 if every level is as it must be */
static int cf_steps(const struct cf_policy *p, const long *khz, const long *uv, int levels) {
    for (int i = 0; i < levels; i++) {
        if (policy_write_long(p, "scaling_setspeed", khz[i]) != 0) {
            cf_fail("scaling_setspeed refused");
            return -1;
        }
        cf_rest(300);
        long clock = policy_long(p, "cpuinfo_cur_freq"), set = policy_long(p, "scaling_cur_freq");
        long rail = read_long(p->rail_path);
        double seconds = 0;
        int right = cf_hash_on(p->first_cpu, p->ncpus, &seconds);
        char zones[160];
        zones_text(zones, sizeof(zones), NULL);
        int ok = clock == khz[i] && set == khz[i] && rail == uv[i] && right == p->ncpus;
        sayf("<6>T715-ARM64: cpufreq: step %s %ld kHz: clock %ld kHz (policy %ld), rail %ld uV (OPP %ld), %d/%d hashes "
             "right in %.2f s, %s: %s\n",
             p->name, khz[i], clock, set, rail, uv[i], right, p->ncpus, seconds, zones, ok ? "ok" : "WRONG");
        if (!ok) {
            cf_fail("a level is not as its OPP says, or a hash is wrong");
            return -1;
        }
    }
    return 0;
}

/* flips between two levels every 50 ms for `seconds`, the cluster loaded and checking its hashes */
static int cf_storm(const struct cf_policy *p, long low, long high, int seconds) {
    long before = policy_long(p, "stats/total_trans");
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    struct cf_crew crew;
    crew_start(&crew, p->first_cpu, p->ncpus, now.tv_sec + seconds + 5);
    int flips = 0;
    for (int i = 0; i < seconds * 10; i++) {
        policy_write_long(p, "scaling_setspeed", (i & 1) ? high : low);
        cf_rest(50);
        policy_write_long(p, "scaling_setspeed", (i & 1) ? low : high);
        cf_rest(50);
        flips += 2;
    }
    policy_write_long(p, "scaling_setspeed", high);
    unsigned long long runs, wrong = crew_finish(&crew, &runs);
    long after = policy_long(p, "stats/total_trans");
    sayf("<6>T715-ARM64: cpufreq: storm %s %ld <-> %ld kHz: %d requests, %ld transitions counted, %llu hashes, %llu "
         "wrong; at %ld kHz after: %s\n",
         p->name, low, high, flips, after - before, runs, wrong, policy_long(p, "cpuinfo_cur_freq"),
         wrong == 0 && runs > 0 ? "ok" : "WRONG");
    if (wrong != 0 || runs == 0) {
        cf_fail("a hash went wrong during the transitions");
        return -1;
    }
    return 0;
}

/* an emulated temperature on one zone: the caps the maps give, then the release */
static int cf_emulate(const char *zone, long mc, long want_a53, long want_a57) {
    int z = zone_index(zone);
    char path[320];
    snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/emul_temp", z);
    if (z < 0 || write_long(path, mc) != 0) {
        cf_fail("no temperature emulation");
        return -1;
    }
    cf_rest(1500);
    long a53 = policy_long(&cf_policies[0], "scaling_cur_freq"), a57 = policy_long(&cf_policies[1], "scaling_cur_freq");
    long s53 = cdev_state(&cf_policies[0]), s57 = cdev_state(&cf_policies[1]);
    write_text(path, "0");
    cf_rest(1500);
    long r53 = policy_long(&cf_policies[0], "scaling_cur_freq"), r57 = policy_long(&cf_policies[1], "scaling_cur_freq");
    int ok = a53 == want_a53 && a57 == want_a57 && r53 == CF_MAX_KHZ && r57 == CF_MAX_KHZ;
    sayf("<6>T715-ARM64: cpufreq: emulated %s at %ld mC: A53 %ld kHz (state %ld, %ld wanted), A57 %ld kHz (state %ld, "
         "%ld wanted); released: A53 %ld kHz (state %ld), A57 %ld kHz (state %ld): %s\n",
         zone, mc, a53, s53, want_a53, a57, s57, want_a57, r53, cdev_state(&cf_policies[0]), r57,
         cdev_state(&cf_policies[1]), ok ? "ok" : "WRONG");
    if (!ok) {
        cf_fail("the cooling maps did not cap as they say, or did not release");
        return -1;
    }
    return 0;
}

/* the passive trips of the test: on each CPU zone, `from` becomes `to` (old values kept to restore) */
struct cf_trip {
    int zone, trip;
    long old_mc;
};
static struct cf_trip cf_moved[8];
static int cf_nmoved;

static void cf_move_trip(const char *zone, long from, long to) {
    int z = zone_index(zone);
    for (int trip = 0; z >= 0 && trip < 16; trip++) {
        char path[320], type[32];
        snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/trip_point_%d_type", z, trip);
        read_into(path, type, sizeof(type));
        if (!type[0]) {
            break;
        }
        snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/trip_point_%d_temp", z, trip);
        if (strcmp(type, "passive") != 0 || read_long(path) != from) {
            continue;
        }
        int done = write_long(path, to) == 0 && read_long(path) == to;
        sayf("<6>T715-ARM64: cpufreq: test trip: %s trip %d (passive) %ld -> %ld mC: %s\n", zone, trip, from, to,
             done ? "set" : "NOT SET");
        if (done && cf_nmoved < 8) {
            cf_moved[cf_nmoved++] = (struct cf_trip){z, trip, from};
        }
        return;
    }
    sayf("<4>T715-ARM64: cpufreq: test trip: %s has no passive trip at %ld mC\n", zone, from);
}

static void cf_restore_trips(void) {
    for (int i = 0; i < cf_nmoved; i++) {
        char path[320];
        snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/trip_point_%d_temp", cf_moved[i].zone,
                 cf_moved[i].trip);
        write_long(path, cf_moved[i].old_mc);
    }
    cf_nmoved = 0;
}

static void cf_load(int seconds) {
    cf_move_trip("atlas0-thermal", 95000, 68000);
    cf_move_trip("atlas0-thermal", 100000, 75000);
    cf_move_trip("atlas1-thermal", 95000, 68000);
    cf_move_trip("atlas1-thermal", 100000, 75000);
    cf_move_trip("apollo-thermal", 81000, 68000);
    cf_move_trip("apollo-thermal", 86000, 75000);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    struct cf_crew crew;
    crew_start(&crew, 0, 8, now.tv_sec + seconds + 5);
    sayf("<5>T715-ARM64: cpufreq: load: 8 hashing processes for %d s, the performance governor, the cooling acting "
         "(stop at %d mC)\n",
         seconds, CF_STOP_MC);
    long hottest = 0;
    int stopped = 0;
    for (int second = 1; second <= seconds; second++) {
        cf_rest(1000);
        char zones[160];
        long now_hottest = 0;
        zones_text(zones, sizeof(zones), &now_hottest);
        if (now_hottest > hottest) {
            hottest = now_hottest;
        }
        sayf("<6>T715-ARM64: cpufreq: load t=%2d s: %s; A53 %ld kHz (state %ld), A57 %ld kHz (state %ld)\n", second,
             zones, policy_long(&cf_policies[0], "scaling_cur_freq"), cdev_state(&cf_policies[0]),
             policy_long(&cf_policies[1], "scaling_cur_freq"), cdev_state(&cf_policies[1]));
        if (now_hottest >= CF_STOP_MC) {
            stopped = 1;
            break;
        }
    }
    unsigned long long runs, wrong = crew_finish(&crew, &runs);
    cf_restore_trips();
    sayf("<5>T715-ARM64: cpufreq: load: over%s; hottest %ld mC; %llu hashes, %llu wrong: %s\n",
         stopped ? " (stopped at the limit)" : "", hottest, runs, wrong, wrong == 0 && runs > 0 ? "ok" : "WRONG");
    if (wrong != 0 || runs == 0) {
        cf_fail("a hash went wrong under load");
    }
}

static int cpufreq_test(void) {
    cf_watchdog = open("/dev/watchdog", O_WRONLY);
    int timeout = 30;
    if (cf_watchdog >= 0 && ioctl(cf_watchdog, WDIOC_SETTIMEOUT, &timeout) == 0) {
        sayf("<6>T715-ARM64: cpufreq: init holds the watchdog (timeout %d s) and feeds it during the test\n", timeout);
    }
    cf_stop = mmap(NULL, sizeof(int), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (cf_stop == MAP_FAILED) {
        cf_fail("no shared page");
        return cf_watchdog;
    }
    for (int i = 0; i < 2; i++) {
        struct cf_policy *p = &cf_policies[i];
        char dir[320];
        if (find_in_class("/sys/class/regulator", "regulator.", "name", p->rail, dir, sizeof(dir))) {
            snprintf(p->rail_path, sizeof(p->rail_path), "%s/microvolts", dir);
        }
        char name[32];
        snprintf(name, sizeof(name), "cpufreq-cpu%d", p->first_cpu);
        find_in_class("/sys/class/thermal", "cooling_device", "type", name, p->cdev, sizeof(p->cdev));
        if (policy_long(p, "cpuinfo_max_freq") <= 0 || !p->rail_path[0]) {
            sayf("<3>T715-ARM64: cpufreq: %s: no policy or no rail (%s)\n", p->name, p->dir);
            cf_fail("cpufreq is not there");
        }
    }
    cf_readout();
    /* stage 1: nothing above 1.2 GHz, set before any governor may choose a level */
    for (int i = 0; !cf_failed && i < 2; i++) {
        /* the write updates a QoS request; policy->max follows in a work item (cpufreq_notifier_max ->
           handle_update), so the value read back may lag by a few milliseconds (cpuf2, 2026-11-24) */
        int capped = policy_write_long(&cf_policies[i], "scaling_max_freq", CF_MAX_KHZ) == 0;
        for (int wait = 0; capped && wait < 20 && policy_long(&cf_policies[i], "scaling_max_freq") != CF_MAX_KHZ; wait++) {
            cf_rest(50);
        }
        if (!capped || policy_long(&cf_policies[i], "scaling_max_freq") != CF_MAX_KHZ) {
            cf_fail("the 1.2 GHz cap could not be set");
        }
    }
    if (!cf_failed) {
        sayf("<6>T715-ARM64: cpufreq: both clusters capped at %d kHz\n", CF_MAX_KHZ);
        pin(0);
        cf_ref = cf_work(CF_SEED, CF_ROUNDS);
        cf_ref_short = cf_work(CF_SEED, CF_SHORT);
        cpu_set_t all;
        CPU_ZERO(&all);
        for (int cpu = 0; cpu < LOAD_MAX_CPUS; cpu++) {
            CPU_SET(cpu, &all);
        }
        sched_setaffinity(0, sizeof(all), &all);
        sayf("<6>T715-ARM64: cpufreq: the reference hashes, on cpu0 at the boot clock: %016llx, %016llx\n",
             (unsigned long long)cf_ref, (unsigned long long)cf_ref_short);
    }
    if (!cf_failed) {
        cf_steps(&cf_policies[0], cf_a53_khz, cf_a53_uv, 3);
    }
    if (!cf_failed) {
        cf_steps(&cf_policies[1], cf_a57_khz, cf_a57_uv, 3);
    }
    if (!cf_failed) {
        cf_storm(&cf_policies[1], 800000, 1200000, 4);
    }
    if (!cf_failed) {
        cf_storm(&cf_policies[0], 400000, 1200000, 4);
    }
    for (int i = 0; !cf_failed && i < 2; i++) {
        policy_write(&cf_policies[i], "scaling_governor", "performance");
    }
    if (!cf_failed) {
        cf_rest(500);
        cf_emulate("atlas1-thermal", 101000, 1000000, 900000);
    }
    if (!cf_failed) {
        cf_emulate("apollo-thermal", 87000, 1000000, 900000);
    }
    if (!cf_failed) {
        /* at rest under schedutil: the levels and rails it picks */
        for (int i = 0; i < 2; i++) {
            policy_write(&cf_policies[i], "scaling_governor", "schedutil");
        }
        char zones[160];
        zones_text(zones, sizeof(zones), NULL);
        sayf("<6>T715-ARM64: cpufreq: rest under schedutil, start: %s\n", zones);
        cf_rest(8000);
        zones_text(zones, sizeof(zones), NULL);
        sayf("<6>T715-ARM64: cpufreq: rest under schedutil, 8 s: A53 %ld kHz at %ld uV, A57 %ld kHz at %ld uV; %s\n",
             policy_long(&cf_policies[0], "scaling_cur_freq"), read_long(cf_policies[0].rail_path),
             policy_long(&cf_policies[1], "scaling_cur_freq"), read_long(cf_policies[1].rail_path), zones);
        for (int i = 0; i < 2; i++) {
            policy_write(&cf_policies[i], "scaling_governor", "performance");
        }
        cf_rest(300);
    }
    if (!cf_failed) {
        cf_load(40);
    }
    /* back where S-Boot left both clusters, whatever happened */
    for (int i = 0; i < 2; i++) {
        policy_write(&cf_policies[i], "scaling_governor", "userspace");
        policy_write_long(&cf_policies[i], "scaling_setspeed", CF_MAX_KHZ);
    }
    sayf("<5>T715-ARM64: cpufreq: the test is %s; A53 %ld kHz, A57 %ld kHz\n", cf_failed ? "FAILED" : "over, every check ok",
         policy_long(&cf_policies[0], "cpuinfo_cur_freq"), policy_long(&cf_policies[1], "cpuinfo_cur_freq"));
    return cf_watchdog;
}

int main(void) {
    mkdir("/proc", 0555);
    mkdir("/sys", 0555);
    mkdir("/dev", 0755);
    mkdir("/tmp", 01777);
    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mkdir("/sys/kernel/debug", 0755);
    mount("none", "/sys/kernel/debug", "debugfs", 0, NULL);

    kmsg = open("/dev/kmsg", O_WRONLY);
    if (kmsg < 0) {
        for (;;) {
            sleep(1);
        }
    }
    struct utsname name;
    uname(&name);
    sayf("<5>T715-ARM64: init is running: release %s, machine %s, version %s\n", name.release, name.machine, name.version);

    char text[512];
    read_into("/proc/sys/kernel/tainted", text, sizeof(text));
    sayf("<6>T715-ARM64: tainted=%s\n", text);
    read_into("/sys/devices/system/cpu/online", text, sizeof(text));
    sayf("<6>T715-ARM64: cpus online: %s\n", text);
    read_into("/sys/devices/system/cpu/present", text, sizeof(text));
    sayf("<6>T715-ARM64: cpus present: %s\n", text);
    read_into("/proc/sys/kernel/hostname", text, sizeof(text));
    say("<6>T715-ARM64: --- /proc/cpuinfo (one core):\n");
    static const char *const cpu_words[] = {"processor", "BogoMIPS", "CPU implementer", "CPU architecture", "CPU variant",
                                           "CPU part", "CPU revision", NULL};
    show("/proc/cpuinfo", cpu_words);
    say("<6>T715-ARM64: --- /proc/cmdline:\n");
    static const char *const all[] = {NULL};
    show("/proc/cmdline", all);

    /* The rails: what the kernel sees in the PMIC, to compare with what S-Boot leaves. */
    DIR *regulators = opendir("/sys/class/regulator");
    if (regulators) {
        struct dirent *entry;
        char path[512], regulator_name[128], microvolts[64], minimum[64], maximum[64], state[64];
        while ((entry = readdir(regulators)) != NULL) {
            if (strncmp(entry->d_name, "regulator.", 10) != 0) {
                continue;
            }
            snprintf(path, sizeof(path), "/sys/class/regulator/%s/name", entry->d_name);
            read_into(path, regulator_name, sizeof(regulator_name));
            static const char *const rails[] = {"vdd_", "BUCK", NULL};
            int wanted = 0;
            for (const char *const *rail = rails; *rail; rail++) {
                wanted = strstr(regulator_name, *rail) != NULL;
                if (wanted) {
                    break;
                }
            }
            if (!wanted) {
                continue;
            }
            snprintf(path, sizeof(path), "/sys/class/regulator/%s/microvolts", entry->d_name);
            read_into(path, microvolts, sizeof(microvolts));
            snprintf(path, sizeof(path), "/sys/class/regulator/%s/min_microvolts", entry->d_name);
            read_into(path, minimum, sizeof(minimum));
            snprintf(path, sizeof(path), "/sys/class/regulator/%s/max_microvolts", entry->d_name);
            read_into(path, maximum, sizeof(maximum));
            snprintf(path, sizeof(path), "/sys/class/regulator/%s/state", entry->d_name);
            read_into(path, state, sizeof(state));
            sayf("<6>T715-ARM64: rail %s: %s uV (range %s to %s), %s\n", regulator_name, microvolts[0] ? microvolts : "?",
                 minimum[0] ? minimum : "?", maximum[0] ? maximum : "?", state[0] ? state : "?");
        }
        closedir(regulators);
    } else {
        say("<6>T715-ARM64: no /sys/class/regulator\n");
    }

    /* The clocks: the kernel's view of the clock units. */
    say("<6>T715-ARM64: --- clock rates:\n");
    static const char *const clock_words[] = {"apollo", "atlas", "fout_mem_pll", "fout_bus_pll", "sclk_mif", "fout_g3d_pll",
                                              "cntclk", "oscclk", NULL};
    show("/sys/kernel/debug/clk/clk_summary", clock_words);

    /* Temperatures, the watchdog, memory. */
    say("<6>T715-ARM64: --- temperatures:\n");
    /* one write per line: each write to /dev/kmsg is a record of its own */
    for (int zone = 0; zone < 4; zone++) {
        char path[96], type[64], temperature[64];
        snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/type", zone);
        read_into(path, type, sizeof(type));
        snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/temp", zone);
        read_into(path, temperature, sizeof(temperature));
        sayf("<6>T715-ARM64: thermal zone %d: type %s, temp %s\n", zone, type, temperature);
    }
    say("<6>T715-ARM64: --- watchdog:\n");
    show("/sys/class/watchdog/watchdog0/identity", all);
    show("/sys/class/watchdog/watchdog0/state", all);
    show("/sys/class/watchdog/watchdog0/timeout", all);
    show("/sys/class/watchdog/watchdog0/bootstatus", all);
    show("/sys/class/watchdog/watchdog0/status", all);
    say("<6>T715-ARM64: --- memory:\n");
    static const char *const memory_words[] = {"MemTotal", "MemFree", NULL};
    show("/proc/meminfo", memory_words);
    say("<6>T715-ARM64: --- uptime:\n");
    show("/proc/uptime", all);

    /* What keeps the time: the clocksource, and a second of sleep measured against it.  The
       ARM counter this kernel's delays are normally counted on does not run on this SoC. */
    read_into("/sys/devices/system/clocksource/clocksource0/current_clocksource", text, sizeof(text));
    sayf("<6>T715-ARM64: clocksource: %s\n", text);
    read_into("/sys/devices/system/clocksource/clocksource0/available_clocksource", text, sizeof(text));
    sayf("<6>T715-ARM64: clocksources available: %s\n", text);
    struct timespec before, after;
    struct timespec pause = {1, 0};
    clock_gettime(CLOCK_MONOTONIC, &before);
    nanosleep(&pause, NULL);
    clock_gettime(CLOCK_MONOTONIC, &after);
    sayf("<6>T715-ARM64: one second of sleep took %ld ms\n", (after.tv_sec - before.tv_sec) * 1000 + (after.tv_nsec - before.tv_nsec) / 1000000);

    int watchdog = -1;
    int seconds = load_seconds();
    read_into("/proc/cmdline", text, sizeof(text));
    if (strstr(text, "t715.cpufreq=1")) {
        watchdog = cpufreq_test();
    } else if (seconds > 0) {
        watchdog = load_test(seconds);
    } else {
        pause.tv_sec = 15;
        nanosleep(&pause, NULL);
    }

    /* From here the watchdog belongs to init, and init does not feed it: whether the restart
       call works or not, the tablet restarts by itself. */
    if (watchdog < 0) {
        watchdog = open("/dev/watchdog", O_WRONLY);
    }
    int timeout = 12;
    if (watchdog >= 0 && ioctl(watchdog, WDIOC_SETTIMEOUT, &timeout) == 0) {
        sayf("<5>T715-ARM64: the test is over: init holds the watchdog (timeout %d s) and restarts by software\n", timeout);
    } else {
        say("<5>T715-ARM64: the test is over: init could not take the watchdog, restarting by software\n");
    }
    sync();
    reboot(RB_AUTOBOOT);
    say("<4>T715-ARM64: the restart call returned; trying SysRq b\n");
    int sysrq = open("/proc/sysrq-trigger", O_WRONLY);
    if (sysrq >= 0) {
        write(sysrq, "b", 1);
    }
    for (;;) {
        sleep(1);
    }
}
