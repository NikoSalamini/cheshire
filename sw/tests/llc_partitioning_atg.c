// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Niko Salamini <nikosalamini@santannapisa.it>

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
    printf("Writing at offset %d\r\n", offs);
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
    printf("Writing at offset %d\r\n", offs);
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

    // configure tagger partitions
    // TO FIX: ATG HAVE THE SAME ADDRESS FOR NOW!
    configure_tagger_addr(0, 1, 0xC0000000); // cva6 0x0-0xBffffff
    configure_tagger_addr(1, 1, 0xD0000000); // 0xC0000000-0xD0000000 (ATG1)
    configure_tagger_addr(2, 1, 0xE0000000); // 0xD0000000-           (ATG2)

    // configure tagger patid
    configure_tagger_patid(0, 1); // cva6 core (tagged as the first atg)
    configure_tagger_patid(1, 1); // atg1
    configure_tagger_patid(2, 2); // atg2

    // configure LLC
    LLC_RW_TEST_REG(AXI_LLC_CFG_SET_PARTITION_LOW_0_REG_OFFSET, 0x00808000); // 128 sets per ATG
    LLC_RW_TEST_REG(AXI_LLC_CFG_SET_PARTITION_LOW_1_REG_OFFSET, 0x00000000);
    LLC_W_TEST_REG(AXI_LLC_COMMIT_PARTITION_CFG_REG_OFFSET, 0x00000001);
    printf("Configuring LLC partitions \n\r");
    uart_write_flush(&__base_uart); 

    // set memory configuration to cache and not SPM
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

    // Enable and configure AXI REALM
    printf("AXI_RT configuration starts \n\r");
    __axirt_claim(1, 1);
    __axirt_set_len_limit_group(2, 0);
    printf("Claimed access to the axi_realm \n\r");
    uart_write_flush(&__base_uart);

    // Configure AXI-RT
    // With Vga=0: core=0,dbg=1,dma=2,slink=3,atg=4,atg2=5  -> atg_id = NUM_INT_HARTS+3
    int chs_dma_id = *reg32(&__base_regs, CHESHIRE_NUM_INT_HARTS_REG_OFFSET) + 1;
    int chs_atg_id = *reg32(&__base_regs, CHESHIRE_NUM_INT_HARTS_REG_OFFSET) + 3;
    printf("ID dma: %d, ID ATG: %d\n\r", chs_dma_id, chs_atg_id);

    /* -------- ATG1 -------- */
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

    /* -------- ATG2 -------- */
    // new chs ID for the next ATG
    chs_atg_id += 1; 
    
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
    printf("Configured ATGs \n\r");
    uart_write_flush(&__base_uart);

    // Enable RT unit for core+ATG1+ATG2  (bit4 | bit5 = 0x31, Vga=0)
    printf("Enabling axi_rt \n\r");
    uart_write_flush(&__base_uart);
    __axirt_enable(0x30); // disabled for CVA6

    // // start counting 
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

    // start ATGs
    asm volatile(
        "li t0, 0x00001000\n"
        "lw %0, 0(t0)\n"
        : "=r"(dummy)
        :
        : "t0", "memory"
    );
    printf("ATGs: started\n\r");
    uart_write_flush(&__base_uart);

    return 0;
}
