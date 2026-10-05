/*
 * nanosleep: sleeps for the BEAM, which can't sleep for less than a millisecond.
 *
 * Nanosleep starts it as a port with {packet, 2}. Each request is the number of
 * nanoseconds to sleep, a signed 64-bit big-endian integer; once that has passed, by the
 * system's monotonic clock, it answers with the nanoseconds it slept, in the same form. A
 * sleep of zero or less answers at once. It exits when its stdin closes, which is when the
 * port closes or the BEAM goes away, and on a request it doesn't understand.
 *
 * Unless started with --no-realtime, it asks to be scheduled as a real-time thread, so that
 * it wakes when it should rather than when the system gets round to it: the time
 * constraint policy on macOS, which anyone may have, SCHED_FIFO at the lowest real-time
 * priority on Linux, which takes root, CAP_SYS_NICE or an rtprio limit, and time critical
 * thread priority on Windows. Where
 * that's refused it sleeps as an ordinary process. It never runs for long: it sleeps,
 * and writes ten bytes.
 */

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <fcntl.h>
#include <io.h>
#include <windows.h>
typedef long long ssize_t;
#define read _read
#define write _write
#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#endif

#if defined(__linux__)
#define _GNU_SOURCE
#include <sched.h>
#include <sys/prctl.h>
#endif

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#endif

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#if !defined(_WIN32)
#include <unistd.h>
#endif

#define NS 1000000000LL

#if defined(_WIN32)
static LARGE_INTEGER frequency;
static HANDLE timer;
#endif

static int64_t now(void) {
#if defined(_WIN32)
  LARGE_INTEGER count;
  QueryPerformanceCounter(&count);
  return (int64_t)(count.QuadPart / frequency.QuadPart * NS +
                   count.QuadPart % frequency.QuadPart * NS / frequency.QuadPart);
#elif defined(__APPLE__)
  /* The clock mach_wait_until counts in. */
  return (int64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * NS + ts.tv_nsec;
#endif
}

/* Sleeps until a point in time rather than for a while, so that a signal or a slow wake
 * from one attempt doesn't add to the next. */
static void sleep_until(int64_t deadline) {
#if defined(_WIN32)
  /* A waitable timer counts in 100 ns units, negative for a relative wait; a high
   * resolution one wakes far closer to its time than Sleep's milliseconds. */
  int64_t left = deadline - now();
  if (left <= 0) return;
  LARGE_INTEGER due = {.QuadPart = -(left + 99) / 100};
  if (timer && SetWaitableTimer(timer, &due, 0, NULL, NULL, FALSE))
    WaitForSingleObject(timer, INFINITE);
  else
    Sleep((DWORD)((left + 999999) / 1000000));
#elif defined(__APPLE__)
  static mach_timebase_info_data_t timebase;
  if (timebase.denom == 0) mach_timebase_info(&timebase);
  mach_wait_until((uint64_t)deadline * timebase.denom / timebase.numer);
#else
  struct timespec ts = {.tv_sec = deadline / NS, .tv_nsec = deadline % NS};
  while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL) == EINTR) {
  }
#endif
}

static void realtime(void) {
#if defined(__APPLE__)
  mach_timebase_info_data_t timebase;
  mach_timebase_info(&timebase);
  uint64_t us = 1000ULL * timebase.denom / timebase.numer;
  thread_time_constraint_policy_data_t policy = {
      .period = 0, .computation = (uint32_t)(50 * us), .constraint = (uint32_t)(100 * us),
      .preemptible = 1};
  thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&policy,
                    THREAD_TIME_CONSTRAINT_POLICY_COUNT);
#elif defined(__linux__)
  struct sched_param param = {.sched_priority = sched_get_priority_min(SCHED_FIFO)};
  sched_setscheduler(0, SCHED_FIFO, &param);
#elif defined(_WIN32)
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
#endif
}

/* All of `length` bytes, or 0 at the end of input or on an error. */
static int read_all(unsigned char *buffer, size_t length) {
  while (length > 0) {
    ssize_t got = read(STDIN_FILENO, buffer, length);
    if (got < 0 && errno == EINTR) continue;
    if (got <= 0) return 0;
    buffer += got;
    length -= (size_t)got;
  }
  return 1;
}

static int write_all(const unsigned char *buffer, size_t length) {
  while (length > 0) {
    ssize_t put = write(STDOUT_FILENO, buffer, length);
    if (put < 0 && errno == EINTR) continue;
    if (put <= 0) return 0;
    buffer += put;
    length -= (size_t)put;
  }
  return 1;
}

int main(int argc, char **argv) {
#if defined(__linux__)
  /* By default Linux may wake a sleeper up to 50 us late, to save power. */
  prctl(PR_SET_TIMERSLACK, 1UL);
#endif
#if defined(_WIN32)
  QueryPerformanceFrequency(&frequency);
  /* Windows 10 1803 and later; older ones sleep with Sleep, in milliseconds. */
  timer = CreateWaitableTimerExW(NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                                 TIMER_ALL_ACCESS);
  _setmode(STDIN_FILENO, _O_BINARY);
  _setmode(STDOUT_FILENO, _O_BINARY);
#else
  /* A write to a closed port ends the program through write_all, not a signal. */
  signal(SIGPIPE, SIG_IGN);
#endif
  if (!(argc > 1 && strcmp(argv[1], "--no-realtime") == 0)) realtime();

  unsigned char request[10], answer[10] = {0, 8};

  for (;;) {
    if (!read_all(request, 2)) return 0;
    if (request[0] != 0 || request[1] != 8 || !read_all(request + 2, 8)) return 2;

    uint64_t bits = 0;
    for (int i = 2; i < 10; i++) bits = bits << 8 | request[i];
    int64_t duration = (int64_t)bits;

    int64_t start = now();
    if (duration > 0) sleep_until(start + duration);
    uint64_t slept = (uint64_t)(now() - start);

    for (int i = 9; i >= 2; i--, slept >>= 8) answer[i] = (unsigned char)slept;
    if (!write_all(answer, sizeof answer)) return 0;
  }
}
