--
-- Copyright 2011 University of Zagreb.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions
-- are met:
-- 1. Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
-- 2. Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
--
-- THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
-- FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
-- DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
-- OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
-- HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
-- LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
-- OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
-- SUCH DAMAGE.
--

-- $Id$

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

use work.f32c_pack.all;


entity glue is
    generic (
	-- Main clock: 50, 62, 75, 81, 87, 100, 112, 125, 137, 150 MHz
	C_clk_freq: integer := 81;

	-- ISA options
	C_big_endian: boolean := false;
	C_mult_enable: boolean := true;
	C_branch_likely: boolean := true;
	C_sign_extend: boolean := true;
	C_ll_sc: boolean := true;
	C_PC_mask: std_logic_vector(31 downto 0) := x"800fffff";

	-- COP0 options
	C_cop0_count: boolean := true;
	C_cop0_config: boolean := true;

	-- CPU core configuration options
	C_branch_prediction: boolean := false;
	C_result_forwarding: boolean := true;
	C_load_aligner: boolean := true;
	C_register_technology: string := "lattice";

	-- This may negatively influence timing closure:
	C_movn_movz: boolean := false; -- true: +16 LUT4, -DMIPS, incomplete

	-- Debugging / testing options (should be turned off)
	C_debug: boolean := false; -- true: +883 LUT4, -Fmax
	C_prng_imem_delay: boolean := false;

	-- SoC configuration options
	C_cpus: integer := 2;
	C_bram_size: integer := 2;
	C_sram: boolean := true;
	C_sram_wait_cycles: integer := 4; -- ISSI, OK do 87.5 MHz
	C_sio: boolean := true;
	C_gpio: boolean := true;
	C_flash: boolean := true;
	C_sdcard: boolean := true;
	C_pcmdac: boolean := true;
	C_framebuffer: boolean := true;
	C_ddsfm: boolean := false
    );
    port (
	clk_25m: in std_logic;
	rs232_tx: out std_logic;
	rs232_rx: in std_logic;
	flash_so: in std_logic;
	flash_cen, flash_sck, flash_si: out std_logic;
	sdcard_so: in std_logic;
	sdcard_cen, sdcard_sck, sdcard_si: out std_logic;
	p_ring: out std_logic;
	p_tip: out std_logic_vector(3 downto 0);
	led: out std_logic_vector(7 downto 0);
	btn_left, btn_right, btn_up, btn_down, btn_center: in std_logic;
	sw: in std_logic_vector(3 downto 0);
	j1: out std_logic_vector(23 downto 20);
	j2: out std_logic_vector(5 downto 2);
	sram_a: out std_logic_vector(18 downto 0);
	sram_d: inout std_logic_vector(15 downto 0);
	sram_oel: out std_logic; -- XXX the old ULXP2 board needs this!
	sram_wel, sram_lbl, sram_ubl: out std_logic
    );
end glue;

architecture Behavioral of glue is
    constant C_io_ports: integer := C_cpus + 1;

    -- types for signals going to / from f32c core(s)
    type f32c_addr_bus is array(0 to (C_cpus - 1)) of
      std_logic_vector(31 downto 2);
    type f32c_byte_sel is array(0 to (C_cpus - 1)) of
      std_logic_vector(3 downto 0);
    type f32c_data_bus is array(0 to (C_cpus - 1)) of
      std_logic_vector(31 downto 0);
    type f32c_std_logic is array(0 to (C_cpus - 1)) of std_logic;
    type f32c_debug_addr is array(0 to (C_cpus - 1)) of
      std_logic_vector(5 downto 0);

    -- types for interfacing to multi-port SRAM controller
    type sram_port_multi is array(0 to (3 * C_cpus - 1)) of sram_port_type;
    type sram_ready_multi is array(0 to (3 * C_cpus - 1)) of std_logic;


    -- global clock
    signal clk: std_logic;

    -- signals to / from f32c cores(s)
    signal res, intr: f32c_std_logic;
    signal imem_addr, dmem_addr: f32c_addr_bus;
    signal final_to_cpu_i, final_to_cpu_d, cpu_to_dmem: f32c_data_bus;
    signal imem_addr_strobe, dmem_addr_strobe, dmem_write: f32c_std_logic;
    signal imem_data_ready, dmem_data_ready: f32c_std_logic;
    signal dmem_byte_sel: f32c_byte_sel;

    -- SRAM
    signal to_sram: sram_port_multi;
    signal sram_ready: sram_ready_multi;
    signal from_sram: std_logic_vector(31 downto 0);
    signal snoop_cycle: std_logic;
    signal snoop_addr: std_logic_vector(31 downto 2);

    -- Block RAM
    signal imem_to_cpu, dmem_to_cpu: std_logic_vector(31 downto 0);
    signal bram_i_ready, bram_d_ready, dmem_bram_enable: std_logic;

    -- I/O
    signal io_write: std_logic;
    signal io_byte_sel: std_logic_vector(3 downto 0);
    signal io_addr: std_logic_vector(31 downto 2);
    signal cpu_to_io, io_to_cpu: std_logic_vector(31 downto 0);
    signal from_sio, from_flash, from_sdcard: std_logic_vector(31 downto 0);
    signal sio_txd, sio_ce, flash_ce, sdcard_ce: std_logic;
    signal io_addr_strobe: std_logic_vector((C_io_ports - 1) downto 0);
    signal next_io_port: integer range 0 to (C_io_ports - 1);
    signal R_cur_io_port: integer range 0 to (C_io_ports - 1);
    signal R_led: std_logic_vector(7 downto 0);
    signal R_sw: std_logic_vector(3 downto 0);
    signal R_btns: std_logic_vector(4 downto 0);
    signal R_fb_mode: std_logic;
    signal R_dac_in_l, R_dac_in_r: std_logic_vector(15 downto 2);
    signal R_dac_acc_l, R_dac_acc_r: std_logic_vector(16 downto 2);

    -- CPU reset control
    signal R_cpu_reset: std_logic_vector(15 downto 0) := x"fffe";

    -- debugging only
    signal trace_addr: f32c_debug_addr;
    signal trace_data: f32c_data_bus;
    signal debug_txd: std_logic;
    signal R_prng: std_logic_vector(8 downto 0);

    -- FM TX DDS
    signal clk_dds, dds_out: std_logic;
    signal R_dds_cnt, R_dds_div, R_dds_div1: std_logic_vector(21 downto 0);

    -- Video framebuffer
    signal video_dac: std_logic_vector(3 downto 0);
    signal fb_addr_strobe, fb_data_ready: std_logic;
    signal fb_addr: std_logic_vector(19 downto 2);

begin

    --
    -- Clock synthesizer
    --
    clkgen: entity work.clkgen
    generic map (
	C_clk_freq => C_clk_freq,
	C_debug => C_debug
    )
    port map (
	clk_25m => clk_25m, clk => clk, clk_325m => clk_dds,
	sel => sw(2), key => btn_down, res => '0'
    );

    --
    -- f32c core(s)
    --
    G_CPU: for i in 0 to (C_cpus - 1) generate
    begin
    intr(i) <= '0';
    res(i) <= sw(i) or R_cpu_reset(i) when C_debug else R_cpu_reset(i);
    cpu: entity work.cache
    generic map (
	C_cpuid => i, C_clk_freq => C_clk_freq,
	C_big_endian => C_big_endian, C_branch_likely => C_branch_likely,
	C_sign_extend => C_sign_extend, C_movn_movz => C_movn_movz,
	C_mult_enable => C_mult_enable, C_PC_mask => C_PC_mask,
	C_cop0_count => C_cop0_count, C_cop0_config => C_cop0_config,
	C_branch_prediction => C_branch_prediction,
	C_result_forwarding => C_result_forwarding,
	C_load_aligner => C_load_aligner,
	C_register_technology => C_register_technology,
	C_ll_sc => C_ll_sc,
	-- debugging only
	C_debug => C_debug
    )
    port map (
	clk => clk, reset => res(i), intr => intr(i),
	imem_addr => imem_addr(i), imem_data_in => final_to_cpu_i(i),
	imem_addr_strobe => imem_addr_strobe(i),
	imem_data_ready => imem_data_ready(i),
	dmem_addr_strobe => dmem_addr_strobe(i),
	dmem_addr => dmem_addr(i),
	dmem_write => dmem_write(i), dmem_byte_sel => dmem_byte_sel(i),
	dmem_data_in => final_to_cpu_d(i), dmem_data_out => cpu_to_dmem(i),
	dmem_data_ready => dmem_data_ready(i),
	snoop_cycle => snoop_cycle, snoop_addr => snoop_addr,
	trace_addr => trace_addr(i), trace_data => trace_data(i)
    );
    end generate;

    --
    -- RS232 sio
    --
    G_sio:
    if C_sio generate
    sio: entity work.sio
    generic map (
	C_big_endian => C_big_endian,
	C_clk_freq => C_clk_freq
    )
    port map (
	clk => clk, ce => sio_ce, txd => sio_txd, rxd => rs232_rx,
	bus_write => io_write, byte_sel => io_byte_sel,
	bus_in => cpu_to_io, bus_out => from_sio
    );
    sio_ce <= io_addr_strobe(R_cur_io_port) when
      io_addr(4 downto 2) = "001" else '0';
    end generate;

    --
    -- On-board SPI flash
    --
    G_flash:
    if C_flash generate
    flash: entity work.spi
    generic map (
	C_turbo_mode => true
    )
    port map (
	clk => clk, ce => flash_ce,
	bus_write => io_write, byte_sel => io_byte_sel,
	bus_in => cpu_to_io, bus_out => from_flash,
	spi_sck => flash_sck, spi_cen => flash_cen,
	spi_si => flash_si, spi_so => flash_so
    );
    flash_ce <= io_addr_strobe(R_cur_io_port) when
      io_addr(4 downto 2) = "100" else '0';
    end generate;

    --
    -- MicroSD card
    --
    G_sdcard:
    if C_sdcard generate
    sdcard: entity work.spi
    port map (
	clk => clk, ce => sdcard_ce,
	bus_write => io_write, byte_sel => io_byte_sel,
	bus_in => cpu_to_io, bus_out => from_sdcard,
	spi_sck => sdcard_sck, spi_cen => sdcard_cen,
	spi_si => sdcard_si, spi_so => sdcard_so
    );
    sdcard_ce <= io_addr_strobe(R_cur_io_port) when
      io_addr(4 downto 2) = "101" else '0';
    end generate;

    --
    -- PCM stereo 1-bit DAC
    --
    G_pcmdac:
    if C_pcmdac generate
    process(clk)
    begin
	if rising_edge(clk) then
	    R_dac_acc_l <= (R_dac_acc_l(16) & R_dac_in_l) + R_dac_acc_l;
	    R_dac_acc_r <= (R_dac_acc_r(16) & R_dac_in_r) + R_dac_acc_r;
	end if;
    end process;
    end generate;

    p_tip(3) <= video_dac(3) when C_framebuffer and sw(3) = '1'
      else R_dac_acc_l(16);
    p_tip(2) <= video_dac(2) when C_framebuffer and sw(3) = '1'
      else R_dac_acc_l(16);
    p_tip(1) <= video_dac(1) when C_framebuffer and sw(3) = '1'
      else R_dac_acc_l(16);
    p_tip(0) <= video_dac(0) when C_framebuffer and sw(3) = '1'
      else R_dac_acc_l(16);
    p_ring <= R_dac_acc_r(16);

    -- I/O port map:
    -- 0x8*******: (4B, RW) * SRAM
    -- 0xf*****00: (4B, RW) * GPIO (LED, switches/buttons)
    -- 0xf*****04: (4B, RW) * SIO
    -- 0xf*****08: (1B, WR) * CPU reset bitmap
    -- 0xf*****0c: (4B, WR) * PCM signal
    -- 0xf*****10: (1B, RW) * SPI Flash
    -- 0xf*****14: (1B, RW) * SPI MicroSD
    -- 0xf*****18: (1B, WR) * Framebuffer
    -- 0xf*****1c: (4B, WR) * FM DDS register

    --
    -- I/O arbiter
    --
    process(R_cur_io_port, dmem_addr, dmem_addr_strobe)
	variable i, j, t, cpu: integer;
    begin
	for cpu in 0 to (C_cpus - 1) loop
	    if dmem_addr(cpu)(31 downto 28) = x"f" then
		io_addr_strobe(cpu) <= dmem_addr_strobe(cpu);
	    else
		io_addr_strobe(cpu) <= '0';
	    end if;
	end loop;
	io_addr_strobe(C_cpus) <= '0'; -- XXX TODO: DMA port
	t := R_cur_io_port;
	for i in 0 to (C_io_ports - 1) loop
	    for j in 1 to C_io_ports loop
		if R_cur_io_port = i then
		    t := (i + j) mod C_io_ports;
		    if io_addr_strobe(t) = '1' then
			exit;
		    end if;
		end if;
	    end loop;
	end loop;
	next_io_port <= t;
    end process;

    --
    -- I/O access
    --
    io_write <= dmem_write(R_cur_io_port);
    io_addr <=  dmem_addr(R_cur_io_port);
    io_byte_sel <= dmem_byte_sel(R_cur_io_port);
    cpu_to_io <= cpu_to_dmem(R_cur_io_port);
    process(clk)
    begin
	if rising_edge(clk) then
	    R_cur_io_port <= next_io_port;
	end if;
	if rising_edge(clk) and io_addr_strobe(R_cur_io_port) = '1'
	  and io_write = '1' then
	    -- GPIO
	    if C_gpio and io_addr(4 downto 2) = "000" then
		R_led <= cpu_to_io(7 downto 0);
	    end if;
	    -- CPU reset control
	    if C_cpus /= 1 and io_addr(4 downto 2) = "010" then
		R_cpu_reset <= cpu_to_io(15 downto 0);
	    end if;
	    -- PCMDAC
	    if C_pcmdac and io_addr(4 downto 2) = "011" then
		if io_byte_sel(2) = '1' then
		    if C_big_endian then
			R_dac_in_l <= cpu_to_io(23 downto 16) &
			  cpu_to_io(31 downto 26);
		    else
			R_dac_in_l <= cpu_to_io(31 downto 18);
		    end if;
		end if;
		if io_byte_sel(0) = '1' then
		    if C_big_endian then
			R_dac_in_r <= cpu_to_io(7 downto 0) &
			  cpu_to_io(15 downto 10);
		    else
			R_dac_in_r <= cpu_to_io(15 downto 2);
		    end if;
		end if;
	    end if;
	    -- Framebuffer
	    if C_framebuffer and io_addr(4 downto 2) = "110" then
		R_fb_mode <= cpu_to_io(0);
	    end if;
	    -- DDS
	    if C_ddsfm and io_addr(4 downto 2) = "111" then
		if C_big_endian then
		    R_dds_div <= cpu_to_io(15 downto 10) & 
		      cpu_to_io(23 downto 16) &
		      cpu_to_io(31 downto 24);
		else
		    R_dds_div <= cpu_to_io(21 downto 0);
		end if;
	    end if;
	end if;
	if C_gpio and rising_edge(clk) then
	    R_sw <= sw;
	    R_btns <= btn_center & btn_up & btn_down & btn_left & btn_right;
	end if;
    end process;
    led <= R_led when C_gpio else "--------";

    -- XXX replace with a balanced multiplexer
    process(io_addr, R_sw, R_btns, from_sio, from_flash, from_sdcard)
    begin
	case io_addr(4 downto 2) is
	when "000"  =>
	    io_to_cpu <="----------------" & "----" & R_sw & "---" & R_btns;
	when "001"  =>
	    if C_sio then
		io_to_cpu <= from_sio;
	    else
		io_to_cpu <= "--------------------------------";
	    end if;
	when "100"  =>
	    if C_flash then
		io_to_cpu <= from_flash;
	    else
		io_to_cpu <= "--------------------------------";
	    end if;
	when "101"  =>
	    if C_sdcard then
		io_to_cpu <= from_sdcard;
	    else
		io_to_cpu <= "--------------------------------";
	    end if;
	when others =>
	    io_to_cpu <= "--------------------------------";
	end case;
    end process;

    --
    -- Block RAM (only CPU #0)
    --
    dmem_bram_enable <= dmem_addr_strobe(0) when dmem_addr(0)(31) /= '1'
      else '0';
    bram: entity work.bram
    generic map (
	C_mem_size => C_bram_size
    )
    port map (
	clk => clk, imem_addr_strobe => imem_addr_strobe(0),
	imem_addr => imem_addr(0), imem_data_out => imem_to_cpu,
	imem_data_ready => bram_i_ready, dmem_data_ready => bram_d_ready,
	dmem_addr_strobe => dmem_bram_enable, dmem_write => dmem_write(0),
	dmem_byte_sel => dmem_byte_sel(0), dmem_addr => dmem_addr(0),
	dmem_data_out => dmem_to_cpu, dmem_data_in => cpu_to_dmem(0)
    );

    --
    -- SRAM
    --
    sram_oel <= '0'; -- XXX the old ULXP2 board needs this!

    process(imem_addr, dmem_addr, dmem_byte_sel, cpu_to_dmem, dmem_write,
      dmem_addr_strobe, imem_addr_strobe, fb_addr_strobe, fb_addr,
      sram_ready, io_to_cpu, from_sram)
	variable data_port, instr_port, fb_port: integer;
	variable sram_data_strobe, sram_instr_strobe: std_logic;
    begin
	for cpu in 0 to (C_cpus - 1) loop
	    data_port := cpu;
	    instr_port := C_cpus + cpu;
	    if dmem_addr(cpu)(31 downto 28) = x"8" then
		sram_data_strobe := dmem_addr_strobe(cpu);
	    else
		sram_data_strobe := '0';
	    end if;
	    if imem_addr(cpu)(31 downto 28) = x"8" then
		sram_instr_strobe := imem_addr_strobe(cpu);
	    else
		sram_instr_strobe := '0';
	    end if;
	    if cpu = 0 then
		-- CPU, data bus
		if io_addr_strobe(cpu) = '1' then
		    if R_cur_io_port = cpu then
			dmem_data_ready(cpu) <= '1';
		    else
			dmem_data_ready(cpu) <= '0';
		    end if;
		    final_to_cpu_d(cpu) <= io_to_cpu;
		elsif sram_data_strobe = '1' then
		    dmem_data_ready(cpu) <= sram_ready(data_port);
		    final_to_cpu_d(cpu) <= from_sram;
		else
		    dmem_data_ready(cpu) <= bram_d_ready;
		    final_to_cpu_d(cpu) <= dmem_to_cpu; -- BRAM
		end if;
		-- CPU, instruction bus
		if sram_instr_strobe = '1' then
		    imem_data_ready(cpu) <= sram_ready(instr_port);
		    final_to_cpu_i(cpu) <= from_sram;
		elsif R_prng(8) = '0' or imem_addr_strobe(cpu) = '0' then
		    imem_data_ready(cpu) <= '0';
		    final_to_cpu_i(cpu) <= x"deadc0de"; -- XXX testing
		else
		    imem_data_ready(cpu) <= bram_i_ready;
		    final_to_cpu_i(cpu) <= imem_to_cpu; -- BRAM
		end if;
	    else -- CPU #1, CPU #2...
		-- CPU, data bus
		if io_addr_strobe(cpu) = '1' then
		    if R_cur_io_port = cpu then
			dmem_data_ready(cpu) <= '1';
		    else
			dmem_data_ready(cpu) <= '0';
		    end if;
		    final_to_cpu_d(cpu) <= io_to_cpu;
		elsif sram_data_strobe = '1' then
		    dmem_data_ready(cpu) <= sram_ready(data_port);
		    final_to_cpu_d(cpu) <= from_sram;
		else
		    -- XXX assert address eror signal?
		    dmem_data_ready(cpu) <= '1';
		    final_to_cpu_d(cpu) <= (others => '-');
		end if;
		-- CPU, instruction bus
		if sram_instr_strobe = '1' then
		    imem_data_ready(cpu) <= sram_ready(instr_port);
		    final_to_cpu_i(cpu) <= from_sram;
		else
		    -- XXX assert address eror signal?
		    -- XXX hack for avoiding a deadlock in i-cache FSM
		    imem_data_ready(cpu) <= imem_addr_strobe(cpu);
		    final_to_cpu_i(cpu) <= (others => '-');
		end if;
	    end if;
	    -- CPU, data bus
	    to_sram(data_port).addr_strobe <= sram_data_strobe;
	    to_sram(data_port).write <= dmem_write(cpu);
	    to_sram(data_port).byte_sel <= dmem_byte_sel(cpu);
	    to_sram(data_port).addr <= dmem_addr(cpu)(19 downto 2);
	    to_sram(data_port).data_in <= cpu_to_dmem(cpu);
	    -- CPU, instruction bus
	    to_sram(instr_port).addr_strobe <= sram_instr_strobe;
	    to_sram(instr_port).addr <= imem_addr(cpu)(19 downto 2);
	    to_sram(instr_port).data_in <= (others => '-');
	    to_sram(instr_port).write <= '0';
	    to_sram(instr_port).byte_sel <= x"f";
	end loop;
	-- video framebuffer
	fb_port := 2 * C_cpus;
	to_sram(fb_port).addr_strobe <= fb_addr_strobe;
	to_sram(fb_port).write <= '0';
	to_sram(fb_port).byte_sel <= x"f";
	to_sram(fb_port).addr <= fb_addr;
	to_sram(fb_port).data_in <= (others => '-');
	fb_data_ready <= sram_ready(fb_port);
    end process;

    sram: entity work.sram
    generic map (
	C_ports => 2 * C_cpus + 1,
	C_prio_port => 2 * C_cpus, -- framebuffer
	C_wait_cycles => C_sram_wait_cycles,
	C_pipelined_read => not C_debug
    )
    port map (
	clk => clk, sram_a => sram_a, sram_d => sram_d,
	sram_wel => sram_wel, sram_lbl => sram_lbl, sram_ubl => sram_ubl,
	data_out => from_sram,
	snoop_cycle => snoop_cycle, snoop_addr => snoop_addr,
	-- Multi-port connections:
	bus_in => to_sram, ready_out => sram_ready
    );

    --
    -- debugging design instance
    --
    G_debug:
    if C_debug generate
    debug: entity work.serial_debug
    port map (
	clk => clk_25m, rs232_txd => debug_txd,
	trace_addr => trace_addr(0), trace_data => trace_data(0)
    );
    end generate;

    rs232_tx <= debug_txd when C_debug and sw(3) = '1' else sio_txd;

    --
    -- DDS FM transmitter
    --
    G_ddsfm:
    if C_ddsfm generate
    process(clk_dds)
    begin
	if (rising_edge(clk_dds)) then
	    R_dds_div1 <= R_dds_div; -- Cross clock domain
	    R_dds_cnt <= R_dds_cnt + R_dds_div1;
	end if;
    end process;
    dds_out <= R_dds_cnt(21);
    end generate;

    -- more pins radiate more RF power
    j1(20) <= dds_out when C_ddsfm else 'Z';
    j1(21) <= dds_out when C_ddsfm else 'Z';
    j1(22) <= dds_out when C_ddsfm else 'Z';
    j1(23) <= dds_out when C_ddsfm else 'Z';
    j2(2) <= not dds_out when C_ddsfm else 'Z';
    j2(3) <= not dds_out when C_ddsfm else 'Z';
    j2(4) <= not dds_out when C_ddsfm else 'Z';
    j2(5) <= not dds_out when C_ddsfm else 'Z';

    --
    -- Video framebuffer
    --
    G_framebuffer:
    if C_framebuffer generate
    fb: entity work.fb
    port map (
	clk => clk, clk_dac => clk_dds,
	addr_strobe => fb_addr_strobe,
	addr_out => fb_addr,
	data_ready => fb_data_ready,
	data_in => from_sram,
	mode => R_fb_mode,
	dac_out => video_dac
    );
    end generate;

    G_prng_imem_delay:
    if C_prng_imem_delay generate
    process(clk)
    begin
	if falling_edge(clk) then
	    R_prng(6 downto 0) <= R_prng(7 downto 1);
	    R_prng(7) <=
	      not R_prng(0) xor R_prng(2) xor R_prng(3) xor R_prng(4);
	    R_prng(8) <= R_prng(7) and imem_addr_strobe(0);
	end if;
    end process;
    end generate;
    R_prng(8) <= '1' when not C_prng_imem_delay;

end Behavioral;
