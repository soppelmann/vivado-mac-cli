/*
 * axiled — poke the phase-2 AXI GPIO (LED) from FreeBSD through /dev/mem.
 *
 *   axiled on | off | blink [period_ms] | read [phys_addr_hex]
 *
 * The PL design puts an AXI GPIO at 0x8000_0000 on the PS's HPM0_LPD port;
 * register 0x00 is GPIO_DATA, bit 0 drives hello.force_on -> the LED on Pmod J5.1.
 * `read` works against any AXI slave, e.g. Trenz's axi_reg32 in the boot bitstream.
 *
 * Build on the board:  cc -O2 -Wall -o axiled axiled.c
 * WARNING: an AXI access to an address with no slave behind it (bitstream not
 * loaded, wrong design) never completes and hangs the CPU. Load the .bin first.
 */
#include <sys/mman.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define GPIO_BASE   0x80000000UL   /* SEG_axi_gpio_0_Reg in the block design */
#define GPIO_DATA   0x00           /* AXI GPIO channel 1 data register */
#define PAGE        4096UL

static volatile uint32_t *map_phys(uintptr_t phys)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem (are you root?)"); exit(1); }
    void *p = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)(phys & ~(PAGE - 1)));
    if (p == MAP_FAILED) { perror("mmap"); exit(1); }
    close(fd);
    return (volatile uint32_t *)((char *)p + (phys & (PAGE - 1)));
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s on|off|blink [ms]|read [addr]\n", argv[0]); return 2; }

    if (!strcmp(argv[1], "read")) {
        uintptr_t a = argc > 2 ? strtoul(argv[2], NULL, 16) : GPIO_BASE;
        volatile uint32_t *r = map_phys(a);
        for (int i = 0; i < 4; i++)
            printf("%08lx: %08x\n", (unsigned long)(a + 4 * i), r[i]);
        return 0;
    }

    volatile uint32_t *gpio = map_phys(GPIO_BASE);
    if (!strcmp(argv[1], "on"))  { gpio[GPIO_DATA / 4] = 1; return 0; }
    if (!strcmp(argv[1], "off")) { gpio[GPIO_DATA / 4] = 0; return 0; }
    if (!strcmp(argv[1], "blink")) {
        int ms = argc > 2 ? atoi(argv[2]) : 500;
        printf("blinking every %d ms, Ctrl-C to stop\n", ms);
        for (;;) {
            gpio[GPIO_DATA / 4] ^= 1;
            usleep((useconds_t)ms * 1000);
        }
    }
    fprintf(stderr, "unknown command %s\n", argv[1]);
    return 2;
}
