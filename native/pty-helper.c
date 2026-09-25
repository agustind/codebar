// pty-helper — runs a command inside a real pseudo-terminal and relays it
// over plain pipes, because txiki.js can only spawn with pipes.
//
//   pty-helper <rows> <cols> <cwd> <input> <cmd> [args...]
//
// stdout: raw bytes from the pty master (what the terminal should render).
// <input>: path of a FIFO the backend writes to (txiki's spawn stdin stalls
//          after its first write, so input can't ride stdin). Framed so
//          input and control share one channel:
//           'd' <u32 len BE> <bytes>        keystrokes / paste
//           'r' <u32 len=4>  <u16 rows> <u16 cols>   resize (BE)
// While the output is quiet, the helper also reports the working directory of
// the pty's foreground process as OSC 7 (ESC ] 7 ; file://host/path BEL),
// the same sequence shells emit, so the page can show where the session is.
// Exits with the child's status. Closing the FIFO, or the backend dying,
// hangs up the child.

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static pid_t child = -1;

static int finish(void) {
  int status = 0;
  if (child > 0) {
    kill(child, SIGHUP);
    waitpid(child, &status, 0);
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}

static int write_all(int fd, const uint8_t *p, size_t n) {
  while (n > 0) {
    ssize_t w = write(fd, p, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN) {
        struct pollfd pf = {fd, POLLOUT, 0};
        poll(&pf, 1, 50);
        continue;
      }
      return -1;
    }
    p += w;
    n -= (size_t)w;
  }
  return 0;
}

// Emits OSC 7 when the foreground process's cwd differs from the last report.
static void report_cwd(int master) {
  static char last[MAXPATHLEN];
  pid_t pid = tcgetpgrp(master);
  if (pid <= 0) pid = child;
  struct proc_vnodepathinfo vpi;
  if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof vpi) != sizeof vpi) return;
  const char *cwd = vpi.pvi_cdir.vip_path;
  if (!cwd[0] || strcmp(cwd, last) == 0) return;
  strlcpy(last, cwd, sizeof last);

  char host[256] = "";
  gethostname(host, sizeof host);
  char seq[MAXPATHLEN * 3 + 300];
  int n = snprintf(seq, sizeof seq, "\x1b]7;file://%s", host);
  for (const unsigned char *c = (const unsigned char *)cwd; *c && n < (int)sizeof seq - 8; c++) {
    if ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') ||
        strchr("/-._~", *c))
      seq[n++] = (char)*c;
    else
      n += snprintf(seq + n, sizeof seq - n, "%%%02X", *c);
  }
  seq[n++] = '\a';
  write_all(STDOUT_FILENO, (const uint8_t *)seq, (size_t)n);
}

int main(int argc, char **argv) {
  if (argc < 6) {
    fprintf(stderr, "usage: pty-helper <rows> <cols> <cwd> <input> <cmd> [args...]\n");
    return 2;
  }
  struct winsize ws = {0};
  ws.ws_row = (unsigned short)atoi(argv[1]);
  ws.ws_col = (unsigned short)atoi(argv[2]);
  if (!ws.ws_row) ws.ws_row = 24;
  if (!ws.ws_col) ws.ws_col = 80;

  // Blocks until the backend opens the write end.
  int input = open(argv[4], O_RDONLY);
  if (input < 0) {
    perror("open input");
    return 1;
  }

  int master;
  child = forkpty(&master, NULL, NULL, &ws);
  if (child < 0) {
    perror("forkpty");
    return 1;
  }
  if (child == 0) {
    if (chdir(argv[3]) != 0) chdir(getenv("HOME") ? getenv("HOME") : "/");
    setenv("TERM", "xterm-256color", 1);
    setenv("COLORTERM", "truecolor", 1);
    setenv("TERM_PROGRAM", "codebar", 1);
    signal(SIGPIPE, SIG_DFL);
    close(input);
    execvp(argv[5], &argv[5]);
    perror("exec");
    _exit(127);
  }

  signal(SIGPIPE, SIG_IGN);
  fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);

  // Frame reassembly buffer for the input FIFO.
  uint8_t in[65536 + 5];
  size_t have = 0;
  uint8_t out[65536];

  // macOS poll() doesn't report the FIFO's writer closing, so an EOF on the
  // input never arrives when the backend dies. Watch for being reparented
  // instead.
  pid_t parent = getppid();

  for (;;) {
    struct pollfd fds[2] = {{input, POLLIN, 0}, {master, POLLIN, 0}};
    int ready = poll(fds, 2, 250);
    if (ready < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (getppid() != parent) return finish();  // backend went away
    if (ready == 0) {
      // Only between bursts, so the report never lands inside another
      // escape sequence or a split UTF-8 character.
      report_cwd(master);
      continue;
    }

    if (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t n = read(master, out, sizeof out);
      if (n > 0) {
        if (write_all(STDOUT_FILENO, out, (size_t)n) < 0) return finish();
      } else if (n == 0 || (errno != EAGAIN && errno != EINTR)) {
        // Child side closed (EIO on macOS once the last slave fd goes away).
        return finish();
      }
    }

    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t n = read(input, in + have, sizeof in - have);
      if (n <= 0) {
        if (n < 0 && errno == EINTR) continue;
        return finish();  // backend went away
      }
      have += (size_t)n;
      size_t off = 0;
      while (have - off >= 5) {
        uint8_t type = in[off];
        uint32_t len = ((uint32_t)in[off + 1] << 24) | ((uint32_t)in[off + 2] << 16) |
                       ((uint32_t)in[off + 3] << 8) | in[off + 4];
        if (len > 65536) return finish();  // protocol error
        if (have - off - 5 < len) break;
        const uint8_t *p = in + off + 5;
        if (type == 'd') {
          write_all(master, p, len);
        } else if (type == 'r' && len == 4) {
          struct winsize nws = {0};
          nws.ws_row = (unsigned short)((p[0] << 8) | p[1]);
          nws.ws_col = (unsigned short)((p[2] << 8) | p[3]);
          if (nws.ws_row && nws.ws_col) ioctl(master, TIOCSWINSZ, &nws);
        }
        off += 5 + len;
      }
      memmove(in, in + off, have - off);
      have -= off;
    }
  }
  return finish();
}
