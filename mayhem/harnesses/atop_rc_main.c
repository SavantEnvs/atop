/*
 * File-input wrapper for atop's ~/.atoprc parser (atop.c readrc and the
 * per-keyword handlers it dispatches to, e.g. showlinux.c ownprocline /
 * ownsysprcline -> make_sys_prints / make_proc_prints).
 *
 *   atop_rc <atoprc file> [atop arguments...]
 *
 * Without atop arguments it runs "atop 1 1": one live sample of this host,
 * printed as text (stdout is not a tty), so the layouts the rc file defines
 * are rendered.
 *
 * atop only reads "$HOME/.atoprc" (and /etc/atoprc); there is no flag or
 * variable naming the file.  Like atop_gpud_main.c, this wrapper reads the
 * whole fuzz input up front, then points HOME at a made-up directory and
 * wraps libc access() and fopen() (-Wl,--wrap=access,--wrap=fopen,--wrap=sleep;
 * libc only, no atop code is replaced) so that exactly the path
 * "<that HOME>/.atoprc" opens that buffer (fmemopen) instead.  readrc() also
 * does sleep(2) after any warning (an unknown or misplaced tag, i.e. nearly
 * every fuzz input), which would cap the target at 0.5 execs/s; sleep() is
 * wrapped to return at once.  Nothing is written anywhere and every other
 * fopen() goes to the real libc.  Then it runs atop's real main() (atop.c is
 * compiled with -Dmain=atop_main) with the remaining arguments.  Each input
 * is its own process.
 *
 * The input is read in main() before atop starts, and no other regular file
 * is opened: an earlier version opened it lazily from readrc() and replayed a
 * raw log from the image ("atop -r sample.raw"); that ran fine locally but
 * never completed Mayhem's regression/behavior testing (0 edges), while
 * atop_gpud, built the same way, fuzzes.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define	FAKE_HOME	"/nonexistent-atop-fuzz-home"
#define	FAKE_RC		FAKE_HOME "/.atoprc"
#define	MAXINPUT	(256 * 1024)

int atop_main(int argc, char *argv[]);
FILE *__real_fopen(const char *path, const char *mode);
int __real_access(const char *path, int mode);

static char *input;
static size_t inputlen;

unsigned int __wrap_sleep(unsigned int seconds)
{
	(void)seconds;
	return 0;
}

int __wrap_access(const char *path, int mode)
{
	if (input && path && strcmp(path, FAKE_RC) == 0)
		return (mode & W_OK) ? -1 : 0;
	return __real_access(path, mode);
}

FILE *__wrap_fopen(const char *path, const char *mode)
{
	if (input && path && strcmp(path, FAKE_RC) == 0)
		return inputlen ? fmemopen(input, inputlen, "r")
				: __real_fopen("/dev/null", "r");
	return __real_fopen(path, mode);
}

int main(int argc, char *argv[])
{
	FILE *fp;
	char **nargv;
	int i;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <atoprc> [atop args...]\n", argv[0]);
		return 2;
	}
	if (!(fp = __real_fopen(argv[1], "rb"))) {
		perror(argv[1]);
		return 2;
	}
	input = malloc(MAXINPUT);
	if (!input)
		return 2;
	inputlen = fread(input, 1, MAXINPUT, fp);
	fclose(fp);
	setenv("HOME", FAKE_HOME, 1);

	if (argc == 2) {
		static char *dflt[] = {"atop", "1", "1", NULL};
		return atop_main(3, dflt);
	}

	nargv = calloc(argc, sizeof *nargv);
	if (!nargv)
		return 2;
	nargv[0] = "atop";
	for (i = 2; i < argc; i++)
		nargv[i - 1] = argv[i];
	nargv[argc - 1] = NULL;

	return atop_main(argc - 1, nargv);
}
