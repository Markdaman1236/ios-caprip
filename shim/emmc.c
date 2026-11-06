/*
 * Minimal read-only eMMC driver for SM6115 "bengal" (caprip).
 *
 * Host is sdhci@4744000, "qcom,sdhci-msm-v5" + "qcom,sdhci-msm-cqe":
 *   hc_mem    0x04744000 0x1000   standard SDHCI register block
 *   cqhci_mem 0x04745000 0x1000   command queue (unused here)
 *   cqhci_ice 0x04748000 0x8000   inline crypto (unused here)
 *
 * Deliberately narrow, because on a bring-up every extra feature is one
 * more way to hang with no debugger:
 *
 *   - PIO only. No ADMA, no DMA descriptors, no 64-bit addressing.
 *   - No CQE. Command queueing needs the cqhci block and an ADMA ring.
 *   - No tuning, no HS200/HS400, no voltage switch. Whatever speed the
 *     bootloader left configured is fast enough to read a root image.
 *   - Read only. Nothing in this file can write to the device.
 *
 * The Qualcomm power-IRQ handshake is avoided rather than implemented.
 * In Linux's sdhci-msm, __sdhci_msm_check_write() raises a power request
 * for exactly three registers: SDHCI_HOST_CONTROL2 (signalling voltage),
 * SDHCI_POWER_CONTROL, and SDHCI_SOFTWARE_RESET when RESET_ALL is set.
 * The controller then stalls until software acks via core_pwrctl_ctl.
 * This driver writes none of the three -- it resets only the CMD and DAT
 * circuits, never RESET_ALL -- so no handshake is needed. If the reset
 * path ever grows, it must poll core_pwrctl_status (0x240), write
 * core_pwrctl_clear (0x248), then ack core_pwrctl_ctl (0x24c).
 */
#include <stdint.h>
#include "console.h"
#include "emmc.h"

#define EMMC_BASE		0x04744000UL

/* Standard SDHCI registers (SD Host Controller Simplified Spec 3.00). */
#define SDHCI_BLOCK_SIZE	0x04	/* 16 */
#define SDHCI_BLOCK_COUNT	0x06	/* 16 */
#define SDHCI_ARGUMENT		0x08	/* 32 */
#define SDHCI_TRANSFER_MODE	0x0c	/* 16 */
#define SDHCI_COMMAND		0x0e	/* 16 */
#define SDHCI_RESPONSE		0x10	/* 4 x 32 */
#define SDHCI_BUFFER		0x20	/* 32, PIO data port */
#define SDHCI_PRESENT_STATE	0x24	/* 32 */
#define SDHCI_HOST_CONTROL	0x28	/* 8  */
#define SDHCI_POWER_CONTROL	0x29	/* 8  -- never written here */
#define SDHCI_CLOCK_CONTROL	0x2c	/* 16 */
#define SDHCI_TIMEOUT_CONTROL	0x2e	/* 8  */
#define SDHCI_SOFTWARE_RESET	0x2f	/* 8  */
#define SDHCI_INT_STATUS	0x30	/* 32 */
#define SDHCI_INT_ENABLE	0x34	/* 32 */
#define SDHCI_SIGNAL_ENABLE	0x38	/* 32 */
#define SDHCI_CAPABILITIES	0x40	/* 32 */
#define SDHCI_CAPABILITIES_1	0x44	/* 32 */
#define SDHCI_HOST_VERSION	0xfe	/* 16 */

/* Qualcomm v5 vendor block (Linux sdhci_msm_v5_offset). */
#define CORE_VENDOR_SPEC	0x20c
#define CORE_PWRCTL_STATUS	0x240
#define CORE_PWRCTL_MASK	0x244
#define CORE_PWRCTL_CLEAR	0x248
#define CORE_PWRCTL_CTL		0x24c
#define CORE_MCI_VERSION	0x318

/* core_pwrctl_status: what the hardware is asking software to do. */
#define PWRCTL_BUS_OFF		(1u << 0)
#define PWRCTL_BUS_ON		(1u << 1)
#define PWRCTL_IO_LOW		(1u << 2)
#define PWRCTL_IO_HIGH		(1u << 3)
#define PWRCTL_REQ_MASK		0x0fu
/* core_pwrctl_ctl: how software answers. */
#define PWRCTL_BUS_SUCCESS	(1u << 0)
#define PWRCTL_BUS_FAIL		(1u << 1)
#define PWRCTL_IO_SUCCESS	(1u << 2)
#define PWRCTL_IO_FAIL		(1u << 3)

/* SDHCI_POWER_CONTROL */
#define POWER_ON		(1u << 0)
#define POWER_180		(0x5u << 1)	/* bus voltage select 1.8 V */
#define POWER_300		(0x6u << 1)
#define POWER_330		(0x7u << 1)

/* SDHCI_CAPABILITIES */
#define CAP_BASE_CLK_SHIFT	8
#define CAP_BASE_CLK_MASK	0xffu
#define CAP_VDD_330		(1u << 24)
#define CAP_VDD_300		(1u << 25)
#define CAP_VDD_180		(1u << 26)

/* PRESENT_STATE */
#define STATE_CMD_INHIBIT	(1u << 0)
#define STATE_DAT_INHIBIT	(1u << 1)

/* INT_STATUS */
#define INT_CMD_COMPLETE	(1u << 0)
#define INT_XFER_COMPLETE	(1u << 1)
#define INT_BUF_READ_RDY	(1u << 5)
#define INT_ERROR		(1u << 15)
#define INT_ALL			0xffffffffu

/* CLOCK_CONTROL */
#define CLK_INTERNAL_EN		(1u << 0)
#define CLK_INTERNAL_STABLE	(1u << 1)
#define CLK_CARD_EN		(1u << 2)

/* SOFTWARE_RESET -- RESET_ALL (bit 0) is deliberately never used. */
#define RESET_CMD		(1u << 1)
#define RESET_DATA		(1u << 2)

/* COMMAND register */
#define CMD_RESP_NONE		0x00
#define CMD_RESP_136		0x01
#define CMD_RESP_48		0x02
#define CMD_RESP_48_BUSY	0x03
#define CMD_CRC_CHECK		0x08
#define CMD_IDX_CHECK		0x10
#define CMD_DATA_PRESENT	0x20

/* TRANSFER_MODE */
#define TRNS_READ		(1u << 4)

#define MMC_RCA			1u

static inline uint8_t rd8(uintptr_t o)
{
	return *(volatile uint8_t *)(EMMC_BASE + o);
}
static inline uint16_t rd16(uintptr_t o)
{
	return *(volatile uint16_t *)(EMMC_BASE + o);
}
static inline uint32_t rd32(uintptr_t o)
{
	return *(volatile uint32_t *)(EMMC_BASE + o);
}
static inline void wr8(uintptr_t o, uint8_t v)
{
	*(volatile uint8_t *)(EMMC_BASE + o) = v;
}
static inline void wr16(uintptr_t o, uint16_t v)
{
	*(volatile uint16_t *)(EMMC_BASE + o) = v;
}
static inline void wr32(uintptr_t o, uint32_t v)
{
	*(volatile uint32_t *)(EMMC_BASE + o) = v;
}

static uint64_t ticks(void)
{
	uint64_t v;
	__asm__ volatile("isb" ::: "memory");
	__asm__ volatile("mrs %0, cntpct_el0" : "=r"(v));
	return v;
}

static uint64_t tick_hz(void)
{
	uint64_t v;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
	return v;
}

static void udelay(uint32_t us)
{
	uint64_t end = ticks() + (tick_hz() / 1000000) * us;
	while (ticks() < end)
		;
}

static int wait_clear(uint32_t mask, uint32_t ms)
{
	uint64_t end = ticks() + (tick_hz() / 1000) * ms;

	while (rd32(SDHCI_PRESENT_STATE) & mask)
		if (ticks() > end)
			return -1;
	return 0;
}

/* Returns the status word, or 0 on timeout. */
static uint32_t wait_int(uint32_t mask, uint32_t ms)
{
	uint64_t end = ticks() + (tick_hz() / 1000) * ms;

	for (;;) {
		uint32_t s = rd32(SDHCI_INT_STATUS);

		if (s & (mask | INT_ERROR))
			return s;
		if (ticks() > end)
			return 0;
	}
}

static uint32_t last_err;

/*
 * Reset just the CMD and DAT circuits. Never RESET_ALL: that is one of the
 * three writes that raise a Qualcomm power request, and it would also undo
 * the bus power this driver has to set up.
 */
static void reset_cmd_dat(void)
{
	wr8(SDHCI_SOFTWARE_RESET, RESET_CMD | RESET_DATA);
	for (int i = 0; i < 10000; i++) {
		if (!(rd8(SDHCI_SOFTWARE_RESET) & (RESET_CMD | RESET_DATA)))
			break;
		udelay(10);
	}
}

/*
 * Service one Qualcomm power request, polled.
 *
 * Writing SDHCI_POWER_CONTROL (or HOST_CONTROL2, or SOFTWARE_RESET with
 * RESET_ALL) makes the hardware raise a request in core_pwrctl_status and
 * then stall until software answers. Linux does this from the pwr_irq
 * handler; there are no interrupts here, so poll instead.
 *
 * The answer is just an ack. On a phone the rails behind the request are
 * PMIC regulators that Linux would switch through the regulator framework,
 * which does not exist here -- the bet is that the bootloader left vmmc and
 * vqmmc enabled (Android was running moments ago, and ABL itself boots off
 * this eMMC), so only the host controller's own power state needs changing.
 * If that bet is wrong, CMD1 will still never see an OCR and the rails have
 * to be driven directly over SPMI to PM6125.
 *
 * Returns the request that was serviced, or 0 if none appeared.
 */
static uint32_t pwrctl_service(uint32_t ms)
{
	uint64_t end = ticks() + (tick_hz() / 1000) * ms;
	uint32_t req, ack = 0;

	for (;;) {
		req = rd32(CORE_PWRCTL_STATUS) & PWRCTL_REQ_MASK;
		if (req)
			break;
		if (ticks() > end)
			return 0;
	}

	/*
	 * Clear first, then ack. The clear pulse can be lost if a reset races
	 * it, so re-clear until the status register actually drops the bits
	 * (Linux retries ten times for the same reason).
	 */
	for (int i = 0; i < 10; i++) {
		wr32(CORE_PWRCTL_CLEAR, req);
		if (!(rd32(CORE_PWRCTL_STATUS) & req))
			break;
		udelay(10);
	}

	if (req & (PWRCTL_BUS_ON | PWRCTL_BUS_OFF))
		ack |= PWRCTL_BUS_SUCCESS;
	if (req & (PWRCTL_IO_HIGH | PWRCTL_IO_LOW))
		ack |= PWRCTL_IO_SUCCESS;
	wr32(CORE_PWRCTL_CTL, ack);
	return req;
}

/*
 * Turn on SD bus power. The probe found SDHCI_POWER_CONTROL == 0 after the
 * bootloader handed off, which is why every command timed out: an unpowered
 * card answers nothing.
 */
static uint32_t power_on(void)
{
	uint32_t caps = rd32(SDHCI_CAPABILITIES);
	uint8_t v;

	/* caprip reports 1.8 V only (caps bit 26), slot type "embedded". */
	if (caps & CAP_VDD_180)
		v = POWER_180;
	else if (caps & CAP_VDD_300)
		v = POWER_300;
	else
		v = POWER_330;

	wr8(SDHCI_POWER_CONTROL, v);		/* select voltage, still off */
	udelay(100);
	wr8(SDHCI_POWER_CONTROL, v | POWER_ON);	/* raises the pwr request */
	return pwrctl_service(500);
}

/*
 * Set the card clock. SDHCI 3.0 ten-bit divided mode: f = base / (2 * n),
 * n == 0 meaning "base, undivided".
 *
 * sdhci-msm marks the capabilities clock base broken in Linux, so this is
 * only as good as that field -- but it reads 200 MHz here, which is the
 * right order for the SDCC core clock, and init only needs to land under
 * 400 kHz rather than hit it exactly.
 */
static void set_clock(uint32_t want_hz)
{
	uint32_t caps = rd32(SDHCI_CAPABILITIES);
	uint32_t base = ((caps >> CAP_BASE_CLK_SHIFT) & CAP_BASE_CLK_MASK) * 1000000u;
	uint32_t n = 0;
	uint16_t v;

	if (!base)
		base = 200000000u;
	if (want_hz < base)
		for (n = 1; n < 0x3ff; n++)
			if (base / (2 * n) <= want_hz)
				break;

	wr16(SDHCI_CLOCK_CONTROL, 0);		/* stop the clock to retime */
	v = (uint16_t)(((n & 0xff) << 8) | (((n >> 8) & 0x3) << 6) |
		       CLK_INTERNAL_EN);
	wr16(SDHCI_CLOCK_CONTROL, v);
	for (int i = 0; i < 10000; i++) {
		if (rd16(SDHCI_CLOCK_CONTROL) & CLK_INTERNAL_STABLE)
			break;
		udelay(10);
	}
	wr16(SDHCI_CLOCK_CONTROL, v | CLK_CARD_EN);
	udelay(1000);
}

/*
 * Issue one command. resp[] takes up to four response words.
 * 0 on success, -1 on timeout, -2 on a controller error.
 */
static int cmd(uint8_t idx, uint32_t arg, uint8_t flags, uint32_t *resp)
{
	uint32_t inhibit = STATE_CMD_INHIBIT;
	uint32_t s;

	if ((flags & 0x03) == CMD_RESP_48_BUSY || (flags & CMD_DATA_PRESENT))
		inhibit |= STATE_DAT_INHIBIT;
	if (wait_clear(inhibit, 1000) < 0) {
		last_err = 0xb0000000u;		/* inhibit never cleared */
		return -1;
	}

	wr32(SDHCI_INT_STATUS, INT_ALL);	/* write-1-to-clear */
	wr32(SDHCI_ARGUMENT, arg);
	wr16(SDHCI_COMMAND, (uint16_t)((idx << 8) | flags));

	s = wait_int(INT_CMD_COMPLETE, 1000);
	if (!s) {
		/*
		 * Timed out. The command is still latched, so CMD_INHIBIT
		 * stays set and every later command fails before it is even
		 * issued -- which is how the first probe turned one CMD13
		 * timeout into "inhibit never cleared" on CMD0. Clear it.
		 */
		last_err = 0x70000000u;		/* no CMD_COMPLETE */
		reset_cmd_dat();
		return -1;
	}
	if (s & INT_ERROR) {
		last_err = s;
		wr32(SDHCI_INT_STATUS, INT_ALL);
		reset_cmd_dat();
		return -2;
	}
	wr32(SDHCI_INT_STATUS, INT_CMD_COMPLETE);
	if (resp) {
		resp[0] = rd32(SDHCI_RESPONSE + 0);
		if ((flags & 0x03) == CMD_RESP_136) {
			resp[1] = rd32(SDHCI_RESPONSE + 4);
			resp[2] = rd32(SDHCI_RESPONSE + 8);
			resp[3] = rd32(SDHCI_RESPONSE + 12);
		}
	}
	return 0;
}

int emmc_read_block(uint32_t lba, void *buf)
{
	uint32_t *p = (uint32_t *)buf;
	uint32_t s;
	int i;

	if (wait_clear(STATE_CMD_INHIBIT | STATE_DAT_INHIBIT, 1000) < 0)
		return -1;

	wr16(SDHCI_BLOCK_SIZE, 512);
	wr16(SDHCI_BLOCK_COUNT, 1);
	wr8(SDHCI_TIMEOUT_CONTROL, 0x0e);
	wr16(SDHCI_TRANSFER_MODE, TRNS_READ);

	/* CMD17 READ_SINGLE_BLOCK, R1, data present. */
	if (cmd(17, lba, CMD_RESP_48 | CMD_CRC_CHECK | CMD_IDX_CHECK |
		CMD_DATA_PRESENT, 0) < 0)
		return -2;

	s = wait_int(INT_BUF_READ_RDY, 1000);
	if (!s || (s & INT_ERROR)) {
		last_err = s;
		return -3;
	}
	wr32(SDHCI_INT_STATUS, INT_BUF_READ_RDY);
	for (i = 0; i < 128; i++)
		p[i] = rd32(SDHCI_BUFFER);

	s = wait_int(INT_XFER_COMPLETE, 1000);
	if (!s || (s & INT_ERROR)) {
		last_err = s;
		return -4;
	}
	wr32(SDHCI_INT_STATUS, INT_ALL);
	return 0;
}

uint32_t emmc_read_blocks(uint32_t lba, void *buf, uint32_t n)
{
	uint8_t *p = (uint8_t *)buf;
	uint32_t done;

	for (done = 0; done < n; done++, p += 512)
		if (emmc_read_block(lba + done, p) != 0)
			break;
	return done;
}

int emmc_probe(void)
{
	static uint8_t block[512] __attribute__((aligned(8)));
	uint32_t resp[4] = { 0, 0, 0, 0 };
	uint16_t clk;
	int rc;

	con_clear(BLUE);
	con_str("EMMC", "sdhci-msm-v5 @0x4744000");
	con_skip();

	/*
	 * Reads first. If the block is unclocked these fault, and the shim
	 * exception handler prints ESR/ELR/FAR -- which is the answer, not a
	 * crash. The UFS block at 0x04800000 behaves exactly that way on
	 * bengal, which is why there is no UFS node in the ADT.
	 */
	con_hex2("VER", "sdhci=", rd16(SDHCI_HOST_VERSION), "mci=",
		 rd32(CORE_MCI_VERSION));
	con_hex2("CAPS", "lo=", rd32(SDHCI_CAPABILITIES), "hi=",
		 rd32(SDHCI_CAPABILITIES_1));
	con_hex2("STATE", "pstate=", rd32(SDHCI_PRESENT_STATE), "ints=",
		 rd32(SDHCI_INT_STATUS));
	con_hex2("CLK", "ctl=", rd16(SDHCI_CLOCK_CONTROL), "hc=",
		 rd8(SDHCI_HOST_CONTROL));
	con_hex2("PWR", "ctl=", rd8(SDHCI_POWER_CONTROL), "vspec=",
		 rd32(CORE_VENDOR_SPEC));
	con_hex2("PWRIRQ", "stat=", rd32(CORE_PWRCTL_STATUS), "ctl=",
		 rd32(CORE_PWRCTL_CTL));
	con_skip();

	/* Unmask status bits; IRQ delivery (signal enable) stays off. */
	wr32(SDHCI_INT_ENABLE, INT_ALL);
	wr32(SDHCI_SIGNAL_ENABLE, 0);
	/* Let the power request reach core_pwrctl_status rather than an IRQ. */
	wr32(CORE_PWRCTL_MASK, PWRCTL_REQ_MASK);

	/*
	 * The first probe found SDHCI_POWER_CONTROL == 0: the bootloader
	 * handed off with SD bus power off, so every command timed out
	 * against an unpowered card. Power up, then clock, then identify.
	 */
	clk = rd16(SDHCI_CLOCK_CONTROL);
	con_hex2("PRE", "clk=", clk, "pwr=", rd8(SDHCI_POWER_CONTROL));

	reset_cmd_dat();
	uint32_t req = power_on();
	con_hex2("POWER", "req=", req, "pwr=", rd8(SDHCI_POWER_CONTROL));
	con_hex2("PWRIRQ", "stat=", rd32(CORE_PWRCTL_STATUS), "ctl=",
		 rd32(CORE_PWRCTL_CTL));
	udelay(10000);			/* rails settle; spec wants 74 clocks */

	set_clock(400000);		/* identification speed */
	con_hex2("CLK", "ctl=", rd16(SDHCI_CLOCK_CONTROL), "pstate=",
		 rd32(SDHCI_PRESENT_STATE));
	con_skip();

	/*
	 * First try the card where the bootloader left it -- already
	 * selected, in transfer state. CMD13 SEND_STATUS is the cheapest ask.
	 */
	rc = cmd(13, MMC_RCA << 16, CMD_RESP_48 | CMD_CRC_CHECK |
		 CMD_IDX_CHECK, resp);
	con_hex2("CMD13", "rc=", (uint32_t)rc, "status=", resp[0]);

	if (rc != 0) {
		uint32_t ocr = 0;
		int tries;

		con_skip();
		con_str("INIT", "not ready, full init from idle");

		rc = cmd(0, 0, CMD_RESP_NONE, 0);
		con_hex2("CMD0", "rc=", (uint32_t)rc, "err=", last_err);

		/* CMD1 SEND_OP_COND, sector mode, until busy clears. */
		for (tries = 0; tries < 1000; tries++) {
			rc = cmd(1, 0x40ff8080, CMD_RESP_48, resp);
			if (rc != 0)
				break;
			ocr = resp[0];
			if (ocr & 0x80000000u)
				break;
			udelay(1000);
		}
		con_hex2("CMD1", "ocr=", ocr, "tries=", (uint32_t)tries);
		if (!(ocr & 0x80000000u)) {
			con_str("EMMC", "card never left busy");
			return -1;
		}

		rc = cmd(2, 0, CMD_RESP_136 | CMD_CRC_CHECK, resp);
		con_hex2("CMD2", "rc=", (uint32_t)rc, "cid0=", resp[0]);

		rc = cmd(3, MMC_RCA << 16, CMD_RESP_48 | CMD_CRC_CHECK |
			 CMD_IDX_CHECK, resp);
		con_hex2("CMD3", "rc=", (uint32_t)rc, "r=", resp[0]);

		rc = cmd(9, MMC_RCA << 16, CMD_RESP_136 | CMD_CRC_CHECK, resp);
		con_hex2("CMD9", "rc=", (uint32_t)rc, "csd0=", resp[0]);

		rc = cmd(7, MMC_RCA << 16, CMD_RESP_48_BUSY | CMD_CRC_CHECK |
			 CMD_IDX_CHECK, resp);
		con_hex2("CMD7", "rc=", (uint32_t)rc, "r=", resp[0]);

		rc = cmd(16, 512, CMD_RESP_48 | CMD_CRC_CHECK | CMD_IDX_CHECK,
			 resp);
		con_hex2("CMD16", "rc=", (uint32_t)rc, "r=", resp[0]);
	}

	con_skip();
	rc = emmc_read_block(0, block);
	con_hex2("READ0", "rc=", (uint32_t)rc, "err=", last_err);
	if (rc != 0)
		return rc;

	con_hex2("LBA0", "w0=", ((uint32_t *)block)[0], "w1=",
		 ((uint32_t *)block)[1]);
	con_hex2("SIG", "at1fe=", (uint32_t)(block[510] | (block[511] << 8)),
		 "want=", 0xaa55);

	/* LBA1 is the GPT header on caprip: it should read "EFI PART". */
	rc = emmc_read_block(1, block);
	con_hex2("READ1", "rc=", (uint32_t)rc, "err=", last_err);
	if (rc == 0) {
		static const char want[8] = { 'E', 'F', 'I', ' ',
					      'P', 'A', 'R', 'T' };
		int ok = 1;

		for (int i = 0; i < 8; i++)
			if (block[i] != (uint8_t)want[i])
				ok = 0;
		con_hex2("LBA1", "w0=", ((uint32_t *)block)[0], "w1=",
			 ((uint32_t *)block)[1]);
		con_str("GPT", ok ? "EFI PART -- eMMC READS OK" :
				    "no GPT signature");
		return ok ? 0 : -2;
	}
	return rc;
}
