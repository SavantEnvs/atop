/* Linked with -Wl,--wrap=isatty into the file-input tools. Mayhem runs the target with a pty on stdout, so
 * atop's plain "-r file" mode takes its interactive branch: initscr() and then getch() until the Mayhem
 * timeout, with no input ever arriving (about 10 s per valid raw file). Report "not a terminal" so it
 * takes the same code path as "atop -r file > out", the non-interactive use. */
int __wrap_isatty(int fd)
{
	(void)fd;
	return 0;
}
