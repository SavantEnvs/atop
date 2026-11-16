/*
 * File-input wrapper for atop's atopgpud client protocol (gpucom.c:
 * gpud_init, gpud_statresponse, gputype_parse, gpustat_parse, gpuparse,
 * pidparse, and gpumergeproc in the sample loop).
 *
 *   atop_gpud <response stream file> [atop arguments...]   e.g. -k -P GPU,PRE 1 1
 *
 * atop connects to the atopgpud daemon over the abstract UNIX socket
 * "@atopgpud_nvidia" when started with -k.  This wrapper mocks that socket:
 * connect() is wrapped (-Wl,--wrap=connect; libc only, no atop code is
 * replaced) and, for exactly that address, the caller's socket is replaced by
 * one end of a fresh socketpair whose peer has already been filled with the
 * fuzz input and shut down for writing.  So the input is the daemon's whole
 * reply stream (the 'T' type response followed by the 'S' stat responses,
 * each a 4-byte big-endian prelude + text), and atop sees end-of-connection
 * when it runs out.  Each input gets its own socketpair (no shared
 * abstract-namespace name, so parallel runs cannot collide).  Every other
 * connect() goes to the real libc.  atop.c is compiled with -Dmain=atop_main.
 */
#include <errno.h>
#include <stddef.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define	GPUD_SOCK	"atopgpud_nvidia"
#define	MAXINPUT	(256 * 1024)

int atop_main(int argc, char *argv[]);
int __real_connect(int fd, const struct sockaddr *addr, socklen_t len);

static unsigned char *input;
static size_t inputlen;
static int peer = -1;

int __wrap_connect(int fd, const struct sockaddr *addr, socklen_t len)
{
	const struct sockaddr_un *un = (const struct sockaddr_un *)addr;
	int sv[2], sndbuf = 4 * MAXINPUT;
	size_t off = 0;

	if (!addr || addr->sa_family != AF_UNIX ||
	    len <= offsetof(struct sockaddr_un, sun_path) + 1 ||
	    un->sun_path[0] != '\0' ||
	    strncmp(un->sun_path + 1, GPUD_SOCK, sizeof GPUD_SOCK) != 0)
		return __real_connect(fd, addr, len);

	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
		return -1;
	setsockopt(sv[1], SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof sndbuf);
	fcntl(sv[1], F_SETFL, O_NONBLOCK);
	while (off < inputlen) {
		ssize_t n = write(sv[1], input + off, inputlen - off);
		if (n <= 0)
			break;		/* socket buffer full: the rest is dropped */
		off += n;
	}
	shutdown(sv[1], SHUT_WR);	/* atop reads EOF after the input */
	peer = sv[1];			/* kept open: atop's requests must not EPIPE */

	if (dup2(sv[0], fd) < 0) {
		int e = errno;
		close(sv[0]);
		errno = e;
		return -1;
	}
	close(sv[0]);
	return 0;
}

int main(int argc, char *argv[])
{
	FILE *fp;
	char **nargv;
	int i;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <gpud reply file> [atop args...]\n", argv[0]);
		return 2;
	}
	if (!(fp = fopen(argv[1], "rb"))) {
		perror(argv[1]);
		return 2;
	}
	input = malloc(MAXINPUT);
	if (!input)
		return 2;
	inputlen = fread(input, 1, MAXINPUT, fp);
	fclose(fp);

	nargv = calloc(argc, sizeof *nargv);
	if (!nargv)
		return 2;
	nargv[0] = "atop";
	for (i = 2; i < argc; i++)
		nargv[i - 1] = argv[i];
	nargv[argc - 1] = NULL;

	return atop_main(argc - 1, nargv);
}
