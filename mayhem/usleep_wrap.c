/* Linked with -Wl,--wrap=usleep into the file-input tools. rawlog.c polls a raw file's size for up to
 * 2 s (40 x usleep(50000)) when a record claims more data than the file holds, waiting for a writer
 * that does not exist on a fuzz input; the poll can only end the same way, so skip the wait. */
int __wrap_usleep(unsigned int usec)
{
	(void)usec;
	return 0;
}
