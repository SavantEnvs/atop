// Leak detection off for every ASan-instrumented binary (SPEC §6.2 item 15).
// ASan and UBSan stay fully active; only LeakSanitizer is disabled.
int __lsan_is_turned_off(void) { return 1; }
