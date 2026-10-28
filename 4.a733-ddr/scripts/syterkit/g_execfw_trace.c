/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * Drop-in replacement for Allwinner libdram's dwc_ddrphy_phyinit_G_execFW()
 * (A733 / sun60iw2, Synopsys LPDDR5/4X PHY). The vendor version starts the
 * PMU training firmware with HdtCtrl = 0xff and reads ONE mailbox message.
 * This one sets a chattier HdtCtrl, logs every message (stage ends and
 * streaming messages with their arguments) over UART, then optionally dumps
 * the DMEM message block. Same register sequence and return value as the
 * vendor code (lo | hi << 16 of the final message; 0x07 = pass, 0xff = fail).
 *
 * Use with SyterKit's FEL app soc/sun60iw2/app_efex/init_dram:
 *   1. make the vendor symbol weak so this strong definition wins at link:
 *        arm-none-eabi-objcopy --weaken-symbol=dwc_ddrphy_phyinit_G_execFW \
 *            soc/sun60iw2/lib/libdram-lpddr5.a
 *   2. add this file to the app's sources, build, run via FEL (xfel).
 * UNTESTED on hardware.
 */
#include <stdint.h>

extern int printf(const char *fmt, ...);

#define PHY_BASE 0x0A900000u
#ifndef A733_HDTCTRL
#define A733_HDTCTRL 0xfe      /* 0xff vendor (pass/fail only), 0xfe stage ends, 0xc8 NXP, 0x05/0x04 detailed */
#endif
#ifndef A733_DUMP_DMEM_WORDS
#define A733_DUMP_DMEM_WORDS 0x200
#endif

static inline volatile uint16_t *csr(uint32_t n)
{
	return (volatile uint16_t *)(uintptr_t)(PHY_BASE + 2u * n);
}
static inline uint16_t rd(uint32_t n) { return *csr(n); }
static inline void wr(uint32_t n, uint16_t v) { *csr(n) = v; }

/* one mailbox message: wait (UctShadowRegs bit0 == 0), read, ack */
static uint32_t mb_get(int want32)
{
	uint32_t v;

	while (rd(0xd0004) & 1)
		;
	v = rd(0xd0032);
	if (want32)
		v |= (uint32_t)rd(0xd0034) << 16;
	wr(0xd0031, 0);
	while (!(rd(0xd0004) & 1))
		;
	wr(0xd0031, 1);
	return v;
}

static const char *major_name(uint32_t m)
{
	switch (m) {
	case 0x00: return "end of initialization";
	case 0x01: return "end of fine write leveling";
	case 0x02: return "end of read enable training";
	case 0x03: return "end of read delay center";
	case 0x04: return "end of write delay center";
	case 0x05: return "end of 2D read delay/voltage center";
	case 0x06: return "end of 2D write delay/voltage center";
	case 0x07: return "TRAINING PASSED";
	case 0x09: return "end of max read latency training";
	case 0x0a: return "end of read DQ deskew";
	case 0x0d: return "end of CA training";
	case 0xfd: return "end of MPR read delay center";
	case 0xfe: return "end of write leveling coarse delay";
	case 0xff: return "TRAINING FAILED";
	default:   return "?";
	}
}

int dwc_ddrphy_phyinit_G_execFW(void)
{
	uint32_t mail, n;

	/* message block was written by F_loadDMEM; raise the debug level */
	wr(0xd0000, 0);                                   /* MicroContMuxSel: APB */
	wr(0x58009, (uint16_t)((rd(0x58009) & 0xff00) | (A733_HDTCTRL & 0xff)));

	/* vendor sequence: hand CSRs to the PMU, reset/start it, open mailbox */
	wr(0xd0000, 1);
	wr(0xd0099, 9);
	wr(0xd0099, 1);
	wr(0xd0099, 0);
	wr(0xd0031, 1);
	wr(0xd0033, 1);

	for (;;) {
		while (rd(0xd0004) & 1)
			;
		mail = rd(0xd0032) | ((uint32_t)rd(0xd0034) << 16);
		wr(0xd0031, 0);
		while (!(rd(0xd0004) & 1))
			;
		wr(0xd0031, 1);

		if ((mail & 0xffff) == 0x08) {            /* streaming: id, then nargs args */
			uint32_t id = mb_get(1);

			printf("pmu: stream %08x", (unsigned)id);
			for (n = id & 0xffff; n; n--)
				printf(" %08x", (unsigned)mb_get(1));
			printf("\n");
			continue;
		}
		printf("pmu: major 0x%02x %s\n", (unsigned)(mail & 0xff), major_name(mail & 0xff));
		if ((mail & 0xff) == 0x07 || (mail & 0xff) == 0xff)
			break;
	}

	wr(0xd0099, 1);                                   /* stall the PMU, as the vendor does */

#if A733_DUMP_DMEM_WORDS
	wr(0xd0000, 0);
	printf("pmu: DMEM message block after training:\n");
	for (n = 0; n < A733_DUMP_DMEM_WORDS; n++) {
		if (n % 16 == 0)
			printf("%s0x%05x:", n ? "\n" : "", (unsigned)(0x58000 + n));
		printf(" %04x", (unsigned)rd(0x58000 + n));
	}
	printf("\n");
	wr(0xd0000, 1);                                   /* leave the mux as the vendor code expects */
#endif
	return (int)mail;
}
