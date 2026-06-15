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
#include "regs/axi_rt.h"
#include "axirt.h"

/* Function prototypes */
static int probe_rw(void *base, int offs, uint32_t val);
static int probe_w(void *base, int offs, uint32_t val);

static int probe_rw(void *base, int offs, uint32_t val) {
    *(volatile uint32_t *)((uint8_t *)base + offs) = val;
    uint32_t ret = *reg32(base, offs);
    printf("Writing at offset %d\n", offs);
    uart_write_flush(&__base_uart);
    return !(ret == val);
}

static int probe_rw_byte(void *base, int offs, uint8_t val) {
    *(volatile uint8_t *)((uint8_t *)base + offs) = val;
    uint8_t ret = *(volatile uint8_t *)((uint8_t *)base + offs);
    return !(ret == val);
}

__attribute__((noinline))
static int probe_w(void *base, int offs, uint32_t val) {
    uintptr_t addr = (uintptr_t)base + (uintptr_t)offs;

    asm volatile (
        "sw %0, 0(%1)"
        :
        : "r"(val), "r"(addr)
        : "memory"
    );

    // Print write address
    printf("Writing at offset %d\n", offs);
    uart_write_flush(&__base_uart);
    return 0;
}

__attribute__((noinline))
static uint32_t probe_r(void *base, int offs) {
    uintptr_t addr = (uintptr_t)base + (uintptr_t)offs;
    uint32_t ret;

    asm volatile (
        "lw %0, 0(%1)"
        : "=r"(ret)
        : "r"(addr)
        : "memory"
    );

    return ret;
}

static void probe_commit_tagger(void *base, int offs) {
    *(volatile uint8_t *)((uint8_t *)base + offs) = 1;
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


// #define TAGGER_RW_TEST_BYTE(NAME, VAL) \
//     err = probe_rw_byte(&__base_tagger, NAME, VAL); \
//     if (err) { \
//         printf("error: rw " #NAME "\n"); \
//         uart_write_flush(&__base_uart); \
//         return 1; \
//     }


int configure_tagger_addr (unsigned int idx, unsigned int mode, uint64_t addr) {
    /* Printing which entry we are configuring*/
    printf("Configuring TAGGER_REG_PAT_ADDR_%u\n", idx);
    uart_write_flush(&__base_uart);

    printf("address value is 0x%016x", addr);

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
    int err = TAGGER_RW_TEST_REG(TAGGER_REG_PAT_ADDR_0_REG_OFFSET + idx * 4, 
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
    probe_commit_tagger(&__base_tagger, TAGGER_REG_PAT_COMMIT_REG_OFFSET);

    /* Print the config */
    printf("configured tagger[%u]: mode=%u addr=0x%016llx (encoded=0x%08x)\n",
	       idx, mode, addr, (uint32_t)(addr >> 2));
	uart_write_flush(&__base_uart);
    
    /* return err */
    return 0;
}

int configure_tagger_patid(unsigned int idx, uint8_t patid) {
    /* checking max entry index, 4 byte registers, 4 bit entries -> 
    TAGGER_REG_PATID_MULTIREG_COUNT * 32/4 (bit) */
    unsigned int total_entries = TAGGER_REG_PATID_MULTIREG_COUNT * 8;
    if (idx >= total_entries) {
        printf("error: tagger patid idx %u out of bounds (max %d)\n",
               idx, TAGGER_REG_PATID_MULTIREG_COUNT - 1);
        uart_write_flush(&__base_uart);
        return 1;
    }

    /* 8 entries per 32-bit register */
    unsigned int reg_idx = idx / 8;
    unsigned int relative_idx = idx % 8;

    /* Read current register value */
    uint32_t reg_value =
        TAGGER_R_TEST_REG(TAGGER_REG_PATID_0_REG_OFFSET + reg_idx * 4);

    /* Build mask for 4-bit field */
    uint32_t shift = relative_idx * 4;
    uint32_t mask  = ~(0xFu << shift);

    /* Keep only lower 4 bits of patid */
    uint32_t value = ((uint32_t)(patid & 0xF)) << shift;

    /* Clear + insert */
    reg_value = (reg_value & mask) | value;

    /* Write back */
    int err = TAGGER_RW_TEST_REG(
        TAGGER_REG_PATID_0_REG_OFFSET + reg_idx * 4,
        reg_value
    );

    if (err) {
        printf("error: failed to write TAGGER_REG_PATID_%u\n", idx);
        uart_write_flush(&__base_uart);
        return 1;
    }

    /* Commit */
    TAGGER_W_TEST_REG(TAGGER_REG_PAT_COMMIT_REG_OFFSET, 0x00000001);

    printf("configured tagger patid[%u] = 0x%x\n", idx, patid & 0xF);
    uart_write_flush(&__base_uart);

    return 0;
}

// SIM active if this is defined
#define SIM

int main(void) {
    int err = 0;

    // Immediately return an error if AXI_REALM, DMA, or UART are not present
    CHECK_ASSERT(-1, chs_hw_feature_present(CHESHIRE_HW_FEATURES_AXIRT_BIT));
    CHECK_ASSERT(-2, chs_hw_feature_present(CHESHIRE_HW_FEATURES_DMA_BIT));
    CHECK_ASSERT(-3, chs_hw_feature_present(CHESHIRE_HW_FEATURES_UART_BIT));

    // // This test requires at least two subordinate regions
    CHECK_ASSERT(-4, AXI_RT_PARAM_NUM_SUB >= 2);

    // Init UART
    uint32_t rtc_freq = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__base_uart, reset_freq, 115200);

    // Enable and configure AXI REALM
    printf("AXI_RT configuration starts \n\r");
    __axirt_claim(1, 1);
    __axirt_set_len_limit_group(2, 0);
    printf("Claimed access to the axi_realm \n\r");
    uart_write_flush(&__base_uart);

    // Configure AXI-RT CVA6 core 0
    __axirt_set_region(0, 0xffffffff, 0, 0);
    __axirt_set_region(0x100000000, 0xffffffffffffffff, 1, 0);
    __axirt_set_budget(8, 0, 0);
    __axirt_set_budget(8, 1, 0);
    __axirt_set_period(100, 0, 0);
    __axirt_set_period(100, 1, 0);
    printf("Configured cva6 core \n\r");
    uart_write_flush(&__base_uart);

    // Configure AXI-RT ATG
    int chs_dma_id = *reg32(&__base_regs, CHESHIRE_NUM_INT_HARTS_REG_OFFSET) + 1;
    // IN REAL IMPLEMENTATION NEEDS +3, 4 IN SIMULATION
    #ifdef SIM
    int chs_atg_id = *reg32(&__base_regs, CHESHIRE_NUM_INT_HARTS_REG_OFFSET) + 4;
    #else
    int chs_atg_id = *reg32(&__base_regs, CHESHIRE_NUM_INT_HARTS_REG_OFFSET) + 3;
    #endif
    printf("ID dma: %d, ID ATG: %d\n\r", chs_dma_id, chs_atg_id);

    // region
    uart_write_flush(&__base_uart);
    __axirt_set_region(0, 0xffffffff, 0, chs_atg_id);
    printf("Configured region 0 for atg \n\r");
    uart_write_flush(&__base_uart);
    __axirt_set_region(0x100000000, 0xffffffffffffffff, 1, chs_atg_id);
    printf("Configured region 1 for atg \n\r");
    uart_write_flush(&__base_uart);

    // budget
    __axirt_set_budget(8, 0, chs_atg_id);
    printf("Configured budget 0 for atg \n\r");
    __axirt_set_budget(8, 1, chs_atg_id);
    printf("Configured budget 1 for atg \n\r");
    uart_write_flush(&__base_uart);

    // period
    __axirt_set_period(100, 0, chs_atg_id);
    printf("Configured period 0 for atg \n\r");
    uart_write_flush(&__base_uart);
    __axirt_set_period(100, 1, chs_atg_id);
    printf("Configured period 1 for atg \n\r");
    uart_write_flush(&__base_uart);

    // print
    printf("Configured atg \n\r");
    uart_write_flush(&__base_uart);

    // Enable RT unit for ATG (bit 5) and CVA6 core 0 (bit 0)
    // ENABLE 0x11 FOR REAL IMPLEMENTATION, SIMULATION 0x21
    #ifdef SIM
    __axirt_enable(0x21);           
    #else
    __axirt_enable(0x11);
    #endif
    printf("enabled axi_rt \n\r");
    uart_write_flush(&__base_uart);

    // Read LLC version register
    // uint32_t low = *reg32(&__base_llc, AXI_LLC_VERSION_LOW_REG_OFFSET);
    // uint32_t high = *reg32(&__base_llc, AXI_LLC_VERSION_HIGH_REG_OFFSET);
    // uint64_t version = ((uint64_t)high << 32) | ((uint64_t)low);
    // printf("llc ver = 0x%016X\n", version);
    // uart_write_flush(&__base_uart);

    // configure LLC
    LLC_RW_TEST_REG(AXI_LLC_CFG_SET_PARTITION_LOW_0_REG_OFFSET, 0x0000007f);
    LLC_RW_TEST_REG(AXI_LLC_CFG_SET_PARTITION_LOW_1_REG_OFFSET, 0x00000000);
    LLC_W_TEST_REG(AXI_LLC_COMMIT_PARTITION_CFG_REG_OFFSET, 0x00000001); 

    // configure tagger patid
    configure_tagger_patid(0, 0); // cva6 core
    configure_tagger_patid(1, 4); // atg

    // configure tagger partitions
    configure_tagger_addr(0, 1, 0xC0000000); // cva6 0x0-0xBffffff
    configure_tagger_addr(1, 1, 0xD0000000); // 0xC0000000-

    // set memory configuration to cache and not SPM (ADDED)
    LLC_RW_TEST_REG(AXI_LLC_CFG_SPM_LOW_REG_OFFSET, 0x00000000);
    LLC_RW_TEST_REG(AXI_LLC_CFG_SPM_HIGH_REG_OFFSET, 0x00000000);
    LLC_W_TEST_REG(AXI_LLC_COMMIT_CFG_REG_OFFSET, 0x00000001);

    __asm__ volatile ("fence ow, ir" ::: "memory");
    /* Wait for the flush FSM to complete: flushed must read 0 before
     * buffer accesses, otherwise bypass stays active and LLC is never used. */
    while (*reg32(&__base_llc, AXI_LLC_FLUSHED_LOW_REG_OFFSET) != 0)
        ;
    printf("Configured LLC \n\r");
    uart_write_flush(&__base_uart);

    // start counting 
    volatile uint32_t dummy;
    asm volatile(
        "li t0, 0x00003000\n"
        "lw %0, 0(t0)\n"
        : "=r"(dummy)
        :
        : "t0", "memory"
    );
    printf("SC: started\n\r");
    uart_write_flush(&__base_uart);

    // start atg 
    asm volatile(
        "li t0, 0x00001000\n"
        "lw %0, 0(t0)\n"
        : "=r"(dummy)
        :
        : "t0", "memory"
    );
    printf("ATG: started\n\r");
    uart_write_flush(&__base_uart);

    /* memstresser like: buffer must be in DRAM region [0x80000000, 0x100000000)
     * and larger than the LLC (8 ways x 256 sets x 8 blocks x 8B = 128KB) so
     * that sequential accesses evict earlier lines and generate steady misses. */
    #define LLC_SIZE_BYTES  (128 * 1024)
    #define BUF_SIZE        (2 * LLC_SIZE_BYTES)
    #define DRAM_BUF_ADDR   0x80200000UL // this address is valid even in the .spm version of the prorgram

    volatile uint8_t *buffer = (volatile uint8_t *)DRAM_BUF_ADDR;
    volatile uint8_t sink = 0;

    /* Cold init: compulsory misses fill then overflow the LLC */
    for (size_t i = 0; i < BUF_SIZE; i++) {
        buffer[i] = (uint8_t)i;
    }

    /* Second pass: first half was evicted → sustained LLC misses */
    for (size_t i = 0; i < BUF_SIZE; i++) {
        sink ^= buffer[i];
    }

    return 0;
}
