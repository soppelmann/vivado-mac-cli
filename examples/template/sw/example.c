/*
 * example.c — the smallest useful FPGA program: read a register, write a register.
 *
 * Matches the template block design: an AXI GPIO at 0x8000_0000 (te0820::axi_gpio ... 0x80000000).
 * AXI GPIO register map (PG144): 0x00 GPIO_DATA, 0x04 GPIO_TRI (fixed when all-outputs).
 *
 *   ./example            -> prints the current GPIO value
 *   ./example 0x5        -> writes 0x5 to GPIO_DATA, reads it back
 */
#include "axi.h"
#include <string.h>

#define GPIO_BASE 0x80000000UL
#define GPIO_DATA 0x00

int main(int argc, char **argv)
{
    axi_t gpio = axi_open(GPIO_BASE, 4096);
    if (argc > 1) {
        uint32_t v = (uint32_t)strtoul(argv[1], NULL, 0);
        axi_wr(gpio, GPIO_DATA, v);
        printf("wrote 0x%08x\n", v);
    }
    printf("GPIO_DATA = 0x%08x\n", axi_rd(gpio, GPIO_DATA));
    axi_close(gpio);
    return 0;
}
