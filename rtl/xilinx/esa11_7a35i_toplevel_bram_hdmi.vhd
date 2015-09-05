--
-- Copyright (c) 2015 Emanuel Stiebler
-- All rights reserved.
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
-- THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
-- FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
-- DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
-- OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
-- HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
-- LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
-- OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
-- SUCH DAMAGE.
--
-- $Id$
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

library unisim;
use unisim.vcomponents.all;

use work.f32c_pack.all;

entity glue is
    generic (
	-- ISA
	C_arch: integer := ARCH_MI32;
	C_debug: boolean := false;

	-- Main clock: N * 10 MHz
	C_clk_freq: integer := 100;

	-- SoC configuration options
	C_mem_size: integer := 16;
	C_vgahdmi: boolean := true;
	C_vgahdmi_mem_kb: integer := 38; -- KB 38K full mono 640x480
	C_sio: integer := 1;   -- 1 UART channel
	C_spi: integer := 2;   -- 2 SPI channels (ch0 not connected, ch1 SD card)
	C_gpio: integer := 32; -- 32 GPIO bits
        C_simple_io: boolean := true -- includes 31 simple inputs and 32 simple outputs
    );
    port (
	i_100MHz_P, i_100MHz_N: in std_logic;
	UART1_TXD: out std_logic;
	UART1_RXD: in std_logic;
	FPGA_SD_SCLK, FPGA_SD_CMD, FPGA_SD_D3: out std_logic;
	FPGA_SD_D0: in std_logic;
	M_EXPMOD0, M_EXPMOD1, M_EXPMOD2, M_EXPMOD3: inout std_logic_vector(7 downto 0); -- EXPMODs
--	seg: out std_logic_vector(7 downto 0); -- 7-segment display
--	an: out std_logic_vector(3 downto 0); -- 7-segment display
	M_LED: out std_logic_vector(7 downto 0);

	VID_D_P, VID_D_N: out std_logic_vector(2 downto 0);
	VID_CLK_P, VID_CLK_N: out std_logic;

	M_BTN: in std_logic_vector(3 downto 0);
	M_HEX: in std_logic_vector(3 downto 0)
    );
end glue;

architecture Behavioral of glue is
    signal clk, sio_break: std_logic;
    signal clk_25MHz, clk_100MHz, clk_250MHz: std_logic;
    signal gpio: std_logic_vector(127 downto 0);
    signal simple_in: std_logic_vector(31 downto 0);
    signal simple_out: std_logic_vector(31 downto 0);
    signal tmds_out_rgb: std_logic_vector(2 downto 0);
    
begin
    -- make single ended clock
    --clk100in: entity work.inp_ds_port
    --port map(i_in_p => i_100MHz_P,
    --       i_in_n => i_100MHz_N,
    --       o_out  => clk);

    -- PLL with differential input: 100MHz
    -- single-ended outputs 250MHz, 100MHz, 25MHz
    pll100in_out250_100_25: entity work.pll_d100M_250M_100M_25M
    port map(clk_in1_p => i_100MHz_P,
             clk_in1_n => i_100MHz_N,
             clk_out1  => clk_250MHz,
             clk_out2  => clk_100MHz,
             clk_out3  => clk_25MHz
             );
    clk <= clk_100MHz;

    -- reset hard-block: Xilinx Spartan-6 specific
--  reset: startup_spartan6
--    port map (
--	   clk => clk, gsr => sio_break, gts => sio_break,
--	   keyclearb => '0'
--  ;
	 -- reset hard-block: Xilinx Artix-7 specific
	 reset: startupe2
    generic map (
		prog_usr => "FALSE"
    )
    port map (
		clk => clk,
		gsr => sio_break,
		gts => '0',
		keyclearb => '0',
		pack => '1',
		usrcclko => clk,
		usrcclkts => '0',
		usrdoneo => '1',
		usrdonets => '0'
   );

    -- generic BRAM glue
    glue_bram: entity work.glue_bram
    generic map (
	C_clk_freq => C_clk_freq,
	C_arch => C_arch,
        C_mem_size => C_mem_size,
        C_gpio => C_gpio,
        C_sio => C_sio,
        C_spi => C_spi,
	C_vgahdmi => C_vgahdmi,
	C_vgahdmi_mem_kb => C_vgahdmi_mem_kb,
        C_debug => C_debug
    )
    port map (
	clk => clk,
	clk_25MHz => clk_25MHz,
	clk_250MHz => clk_250MHz,
	sio_txd(0) => UART1_TXD, 
	sio_rxd(0) => UART1_RXD,
	sio_break(0) => sio_break,
        spi_sck(0)  => open,  spi_sck(1)  => FPGA_SD_SCLK,
        spi_ss(0)   => open,  spi_ss(1)   => FPGA_SD_D3,
        spi_mosi(0) => open,  spi_mosi(1) => FPGA_SD_CMD,
        spi_miso(0) => '-',   spi_miso(1) => FPGA_SD_D0,
	gpio(7 downto 0) => M_EXPMOD0, gpio(15 downto 8) => M_EXPMOD1,
	gpio(23 downto 16) => M_EXPMOD2, gpio(31 downto 24) => M_EXPMOD3,
	gpio(127 downto 32) => open,
	tmds_out_rgb => tmds_out_rgb,
	simple_out(7 downto 0) => M_LED, simple_out(15 downto 8) => open, 
	simple_out(19 downto 16) => open, simple_out(31 downto 20) => open,
	simple_in(0) => M_BTN(0),
	simple_in(1) => M_BTN(1),
        simple_in(2) => M_BTN(2),
        simple_in(3) => M_BTN(3),
        simple_in(4) => '0',     -- will be center button one day,
        simple_in(8 downto 5) => M_HEX,
        simple_in(31 downto 9) => (others => '-')
    );

    -- differential output buffering for HDMI clock and video
    hdmi_output: entity work.hdmi_out
      port map (
        tmds_in_clk => clk_25MHz,
        tmds_out_clk_p => vid_clk_p,
        tmds_out_clk_n => vid_clk_n,
        tmds_in_rgb => tmds_out_rgb,
        tmds_out_rgb_p => vid_d_p,
        tmds_out_rgb_n => vid_d_n
      );

end Behavioral;
