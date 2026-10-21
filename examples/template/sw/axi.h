/*
 * axi.h — talk to AXI-Lite registers in the PL from a FreeBSD user program via /dev/mem.
 *
 * The PS reaches the fabric through its HPM0_LPD port; whatever the block design placed at
 * an address (te0820::axi_slave / te0820::axi_gpio in project.tcl) is read and written here
 * as plain 32-bit MMIO. Root only. The mapping is uncached device memory, so every access
 * really goes to the fabric.
 *
 * WARNING: an access to an address with no AXI slave behind it (bitstream not loaded, or a
 * design without that block) never completes and hangs the CPU. Load the .bin first.
 */
#ifndef AXI_H
#define AXI_H
#include <sys/mman.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct { volatile uint32_t *regs; size_t len; } axi_t;

/* Map `len` bytes (page multiple) of PL address space starting at `phys`. Exits on failure. */
static inline axi_t axi_open(uintptr_t phys, size_t len)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem (run as root)"); exit(1); }
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
    close(fd);
    if (p == MAP_FAILED) { perror("mmap"); exit(1); }
    return (axi_t){ .regs = (volatile uint32_t *)p, .len = len };
}

static inline void axi_close(axi_t a) { munmap((void *)a.regs, a.len); }

/* Register access by byte offset, as the IP's register map documents it. */
static inline uint32_t axi_rd(axi_t a, uint32_t off) { return a.regs[off / 4]; }
static inline void     axi_wr(axi_t a, uint32_t off, uint32_t v) { a.regs[off / 4] = v; }

#endif
