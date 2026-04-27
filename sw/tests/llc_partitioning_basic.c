// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Robert Balas <balasr@iis.ee.ethz.ch>
// Enrico Zelioli <ezelioli@iis.ee.ethz.ch>

// Basic testing of the cache partitioning's configuration registers

#include <stdint.h>
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "regs/cheshire.h"
#include "regs/axi_llc.h"
#include "regs/tagger.h"
#include "util.h"
#include "printf.h"

/* Function prototypes */
static int probe_rw(void *base, int offs, uint32_t val);
static int probe_w(void *base, int offs, uint32_t val);
extern char __base_tagger[];

static int probe_rw(void *base, int offs, uint32_t val) {
    *(volatile uint32_t *)((uint8_t *)base + offs) = val;
    uint32_t ret = *reg32(base, offs);
    return !(ret == val);
}

static int probe_w(void *base, int offs, uint32_t val) {
    *(volatile uint32_t *)((uint8_t *)base + offs) = val;
    return 0;
}

static uint32_t probe_r(void *base, int offs) {
    return *reg32(base, offs);
}

#define LLC_RW_TEST_REG(NAME, VAL) \
    err = probe_rw(&__base_llc, NAME, VAL); \
    if (err) { \
        printf("error: rw " #NAME "\n"); \
        uart_write_flush(&__base_uart); \
        return 1; \
    }

#define LLC_W_TEST_REG(NAME, VAL) \
    err = probe_w(&__base_llc, NAME, VAL); \
    if (err) { \
        printf("error: w " #NAME "\n"); \
        uart_write_flush(&__base_uart); \
        return 1; \
    }

#define TAGGER_RW_TEST_REG(NAME, VAL) \
    err = probe_rw(&__base_tagger, NAME, VAL); \
    if (err) { \
        printf("error: rw " #NAME "\n"); \
        uart_write_flush(&__base_uart); \
        return 1; \
    }

#define TAGGER_W_TEST_REG(NAME, VAL) \
    err = probe_w(&__base_tagger, NAME, VAL); \
    if (err) { \
        printf("error: w " #NAME "\n"); \
        uart_write_flush(&__base_uart); \
        return 1; \
    }

#define TAGGER_R_TEST_REG(NAME) \
    probe_r(&__base_tagger, NAME);  


int configure_tagger_addr (unsigned int idx, unsigned int mode, uint64_t addr) {
	/* Validate index bounds */
	if (idx >= TAGGER_REG_PAT_ADDR_MULTIREG_COUNT) {
		printf("error: tagger idx %u out of bounds (max %d)\n", 
		       idx, TAGGER_REG_PAT_ADDR_MULTIREG_COUNT - 1);
		uart_write_flush(&__base_uart);
		return 1;
	}
 
	/* Encode address for HW: drop lower 2 bits (PMP-style >> 2).
	 * Conservative check: ensure it fits in 32 bits after >>2.
	 */
	if (addr >> 34) {
		printf("error: address 0x%llx too large (>34 bits)\n", addr);
		uart_write_flush(&__base_uart);
		return 1;
	}

    /* Encode address for HW: drop lower 2 bits (PMP-style). */
    int err = TAGGER_RW_TEST_REG(TAGGER_REG_PAT_ADDR_0_REG_OFFSET + idx*4, 
        (uint32_t)(addr >> 2)); 
    if (err) {
		printf("error: failed to write TAGGER_REG_PAT_ADDR_%u\n", idx);
		uart_write_flush(&__base_uart);
		return 1;
	}

    /* Update mode bits in addr_conf register (2 bits per entry). */
    uint32_t addr_conf = TAGGER_R_TEST_REG(TAGGER_REG_ADDR_CONF_REG_OFFSET);
    unsigned int shift = (idx % 16) * 2;
    uint32_t mask = 0x3u << shift;

    addr_conf = (addr_conf & ~mask) | ((mode & 0x3u) << shift);
    err = TAGGER_RW_TEST_REG(TAGGER_REG_ADDR_CONF_REG_OFFSET, addr_conf);
    if (err) {
		printf("error: failed to write TAGGER_REG_ADDR_CONF\n");
		uart_write_flush(&__base_uart);
		return 1;
	}

    /* Commit the configuration */
    TAGGER_W_TEST_REG(TAGGER_REG_PAT_COMMIT_COMMIT_0_BIT, 0x00000001)

    /* Print the config */
    printf("configured tagger[%u]: mode=%u addr=0x%016llx (encoded=0x%08x)\n",
	       idx, mode, addr, (uint32_t)(addr >> 2));
	uart_write_flush(&__base_uart);
    
    /* return err */
    return 0;
}

int configure_tagger_patid(unsigned int idx, uint32_t patid) {
    /* Validate index bounds */
	if (idx >= TAGGER_REG_PATID_MULTIREG_COUNT) {
		printf("error: tagger patid idx %u out of bounds (max %d)\n",
		       idx, TAGGER_REG_PATID_MULTIREG_COUNT - 1);
		uart_write_flush(&__base_uart);
		return 1;
	}

    /* Write the PATID register: patid[idx] = patid */
	int err = TAGGER_RW_TEST_REG(TAGGER_REG_PATID_0_REG_OFFSET + idx * 4, patid);
    if (err) {
		printf("error: failed to write TAGGER_REG_PATID_%u\n", idx);
		uart_write_flush(&__base_uart);
		return 1;
	}

    /* Commit the configuration */
    TAGGER_W_TEST_REG(TAGGER_REG_PAT_COMMIT_REG_OFFSET, 0x00000001);

    /* Print tagger patid */
    printf("configured tagger patid[%u] = 0x%08x\n", idx, patid);
	uart_write_flush(&__base_uart);
    
    /* ret */
	return 0;
}

int main(void) {
    int err = 0;

    printf("base_tagger = 0x%08X\n", __base_tagger);
    uart_write_flush(&__base_uart);

    // Init UART
    uint32_t rtc_freq = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__base_uart, reset_freq, 115200);

    // Read LLC version register
    uint32_t low = *reg32(&__base_llc, AXI_LLC_VERSION_LOW_REG_OFFSET);
    uint32_t high = *reg32(&__base_llc, AXI_LLC_VERSION_HIGH_REG_OFFSET);
    uint64_t version = ((uint64_t)high << 32) | ((uint64_t)low);

    // Run basic register rw tests
    LLC_RW_TEST_REG(AXI_LLC_CFG_FLUSH_PARTITION_LOW_REG_OFFSET, 0xcafedead);
    LLC_RW_TEST_REG(AXI_LLC_CFG_FLUSH_PARTITION_HIGH_REG_OFFSET, 0xcafedead);

    // configure LLC
    LLC_RW_TEST_REG(AXI_LLC_CFG_SET_PARTITION_LOW_0_REG_OFFSET, 0x0000007f);
    LLC_RW_TEST_REG(AXI_LLC_CFG_SET_PARTITION_LOW_1_REG_OFFSET, 0x00000000);
    LLC_W_TEST_REG(AXI_LLC_COMMIT_PARTITION_CFG_REG_OFFSET, 0x00000001); // (ADDED)

    // /* configure tagger patid*/
    // configure_tagger_patid(0, 3);

    // /* configure tagger partitions*/
    // configure_tagger_addr(0, 1, 0xC0000000);
    // configure_tagger_addr(1, 1, 0xD0000000);

    // set memory configuration to cache and not SPM (ADDED)
    LLC_RW_TEST_REG(AXI_LLC_CFG_SPM_LOW_REG_OFFSET, 0x00000000);
    LLC_RW_TEST_REG(AXI_LLC_CFG_SPM_HIGH_REG_OFFSET, 0x00000000);
    LLC_W_TEST_REG(AXI_LLC_COMMIT_CFG_COMMIT_BIT, 0x00000001);

    /* memstresser like */
    // Allocate memory
    volatile uint8_t buffer[2048];

    // Initialize buffer (important for read-only mode)
    for (size_t i = 0; i < 2048; i++) {
        buffer[i] = (uint8_t)i;
    }
    
    volatile uint8_t sink = 0;
    for (size_t i = 0; i < 2048; i++) {
        buffer[i] = (uint8_t)i;
    }

    // LLC_RW_TEST_REG(AXI_LLC_CFG_SET_PARTITION_HIGH_0_REG_OFFSET, 0xdeadc0de);
    // LLC_RW_TEST_REG(AXI_LLC_CFG_SET_PARTITION_HIGH_1_REG_OFFSET, 0xdeadc0de);

    // print version
    printf("llc ver = 0x%016X\n", version);
    uart_write_flush(&__base_uart);

    return 0;
}
