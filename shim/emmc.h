#pragma once
#include <stdint.h>

/* Probe the host, report on the panel. 0 if a block was read back. */
int emmc_probe(void);
/* Read one 512-byte block. 0 on success. */
int emmc_read_block(uint32_t lba, void *buf);
/* Read n blocks. Returns how many were actually read. */
uint32_t emmc_read_blocks(uint32_t lba, void *buf, uint32_t n);
