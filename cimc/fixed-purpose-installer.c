#include <unistd.h>

/*
 * Loaded once by the vulnerable CIMC curl process. This intentionally offers
 * no shell, listener, command channel, or user-controlled command string.
 */
__attribute__((constructor)) static void install_fan_controller(void)
{
    execl("/bin/sh", "sh", "/mnt/jffs2/install-fan-controller.sh", (char *)0);
    _exit(127);
}
