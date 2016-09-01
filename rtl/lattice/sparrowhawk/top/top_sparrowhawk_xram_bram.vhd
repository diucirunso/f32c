-- (c)EMARD
-- License=BSD

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

use work.f32c_pack.all;

entity sparrowhawk is
  generic (
    -- ISA: either ARCH_MI32 or ARCH_RV32
    C_arch: integer := ARCH_MI32;
    C_debug: boolean := false;

    -- Main clock: 50, 62, 75, 81, 87, 100, 112, 125, 137, 150 MHz
    C_clk_freq: integer := 100;

    -- SoC configuration options
    C_bram_size: integer := 2;
    C_icache_size: integer := 2;
    C_dcache_size: integer := 2;
    C_sram8: boolean := false;
    C_branch_prediction: boolean := false;
    C_sio: integer := 2;
    C_spi: integer := 2;
    C_simple_io: boolean := true;
    C_gpio: integer := 32;
    C_gpio_pullup: boolean := false;
    C_gpio_adc: integer := 0; -- number of analog ports for ADC (on A0-A5 pins)

    -- video parameters common for vgahdmi and vgatext
    C_dvid_ddr: boolean := false; -- generate HDMI with DDR
    C_video_mode: integer := 1; -- 0:640x360, 1:640x480, 2:800x480, 3:800x600, 5:1024x768

    C_vgahdmi: boolean := false;
    C_vgahdmi_cache_size: integer := 8;
    -- normally this should be  actual bits per pixel
    C_vgahdmi_fifo_data_width: integer range 8 to 32 := 8;

    -- VGA textmode and graphics, full featured
    C_vgatext: boolean := false;    -- Xark's feature-rich bitmap+textmode VGA
    C_vgatext_label: string := "FleaFPGA-Uno f32c: 50MHz MIPS-compatible soft-core, 512KB SRAM";
    C_vgatext_bits: integer := 4;   -- 4096 possible colors
    C_vgatext_bram_mem: integer := 8;   -- 8KB text+font  memory
    C_vgatext_external_mem: integer := 0; -- 0KB external SRAM/SDRAM
    C_vgatext_reset: boolean := true;   -- reset registers to default with async reset
    C_vgatext_palette: boolean := true;  -- no color palette
    C_vgatext_text: boolean := true;    -- enable optional text generation
    C_vgatext_font_bram8: boolean := true;    -- font in separate bram8 file (for Lattice XP2 BRAM or non power-of-two BRAM sizes)
    C_vgatext_char_height: integer := 16;   -- character cell height
    C_vgatext_font_height: integer := 16;    -- font height
    C_vgatext_font_depth: integer := 8;     -- font char depth, 7=128 characters or 8=256 characters
    C_vgatext_font_linedouble: boolean := true;   -- double font height by doubling each line (e.g., so 8x8 font fills 8x16 cell)
    C_vgatext_font_widthdouble: boolean := false;   -- double font width by doubling each pixel (e.g., so 8 wide font is 16 wide cell)
    C_vgatext_monochrome: boolean := false;    -- true for 2-color text for whole screen, else additional color attribute byte per character
    C_vgatext_finescroll: boolean := true;   -- true for pixel level character scrolling and line length modulo
    C_vgatext_cursor: boolean := true;    -- true for optional text cursor
    C_vgatext_cursor_blink: boolean := true;    -- true for optional blinking text cursor
    C_vgatext_bus_read: boolean := true; -- true: allow reading vgatext BRAM from CPU bus (may affect fmax). false: write only
    C_vgatext_reg_read: boolean := false; -- true: allow reading vgatext BRAM from CPU bus (may affect fmax). false: write only
    C_vgatext_text_fifo: boolean := true;  -- disable text memory FIFO
      C_vgatext_text_fifo_step: integer := (82*2)/4; -- step for the FIFO refill and rewind
      C_vgatext_text_fifo_width: integer := 6;  -- width of FIFO address space (default=4) length = 2^width * 4 bytes
    C_vgatext_bitmap: boolean := true;     -- true for optional bitmap generation
    C_vgatext_bitmap_depth: integer := 8;   -- 8-bpp 16-color bitmap
    C_vgatext_bitmap_fifo: boolean := true;  -- disable bitmap FIFO
    -- step=horizontal width in pixels
    C_vgatext_bitmap_fifo_step: integer := 640;
    -- height=vertical height in pixels
    C_vgatext_bitmap_fifo_height: integer := 480;
    -- output data width 8bpp
    C_vgatext_bitmap_fifo_data_width: integer := 8; -- should be equal to bitmap depth
    -- bitmap width of FIFO address space length = 2^width * 4 byte
    C_vgatext_bitmap_fifo_addr_width: integer := 11
  );
  port (
  clk_100_p, clk_100_n: in std_logic;  -- main clock input from 100MHz clock source
  cy_clkout: in std_logic;  -- cypress CPU clock, firmware configurable 12/24/48MHz clock source
  --sys_reset   : in    std_logic;  --

  Shield_reset : inout    std_logic;  -- Buffered reset signal out to GPIO header

  -- UART0 (USB slave serial)
  tx: out   std_logic;
  rx: in    std_logic;

  -- UART1 (Optional WiFi interface)
  wifi_rx_i   : out   std_logic;
  wifi_tx_o   : in    std_logic;

  LVDS_Red    : out   std_logic;
  LVDS_Green  : out   std_logic;
  LVDS_Blue   : out   std_logic;
  LVDS_ck     : out   std_logic;

  led: out std_logic_vector(7 downto 0);

  User_LED1   : inout std_logic;
  User_LED2   : out   std_logic;
  User_n_PB1  : in    std_logic;

  GPIO_wordport : inout std_logic_vector(15 downto 0);
  GPIO_pullup   : inout std_logic_vector(15 downto 0);

  ADC_Comp_in   : inout std_logic_vector(5 downto 0);
  ADC_Error_out : inout std_logic_vector(5 downto 0);
  
  -- SD card
  sd_dat3_csn, sd_cmd_di, sd_dat0_do, sd_dat1_irq, sd_dat2: inout std_logic;
  sd_clk, sd_pwrn: out std_logic;
  sd_cdn, sd_wp: in std_logic;

  -- SPI1 to Flash ROM
  spi1_miso   : in      std_logic;
  spi1_mosi   : out     std_logic;
  spi1_clk    : out     std_logic;
  spi1_cs     : out     std_logic
  );
end;

architecture Behavioral of sparrowhawk is
  signal clk, rs232_break, rs232_break2: std_logic;
  signal clk_dvi, clk_dvin, clk_pixel: std_logic;
  signal dvid_red, dvid_green, dvid_blue, dvid_clock: std_logic_vector(1 downto 0);
begin
  shield_reset <= 'Z';  -- ignore for now

  -- un-comment following two lines for WiFi option
  -- gpio_pullup(0) <= '1';  -- Wifi gpio

  video_mode_1_640x480: if C_video_mode = 1 generate
  clk_640x480: entity work.clkgen_100_100
  port map(
    CLK         => clk_100_p,
    CLKOP       => clk
--    CLKOP       =>  clk_dvi,
--    CLKOS       =>  clk_dvin,
--    CLKOS2      =>  clk_pixel,
--    CLKOS3      =>  clk
   );
  end generate;

    -- generic BRAM glue
  glue_xram: entity work.glue_xram
  generic map (
    C_arch => C_arch,
    C_clk_freq => C_clk_freq,
    C_bram_size => C_bram_size,
    C_icache_size => C_icache_size,
    C_dcache_size => C_dcache_size,
    C_sram8 => C_sram8,
    C_debug => C_debug,
    C_sio => C_sio,
    C_spi => C_spi,
    C_gpio => C_gpio,
    C_gpio_pullup => C_gpio_pullup,
    C_gpio_adc => C_gpio_adc,
    C_branch_prediction => C_branch_prediction,
    C_dvid_ddr => C_dvid_ddr,
    -- vga simple compositing bitmap only graphics
    C_vgahdmi => C_vgahdmi,
      C_vgahdmi_mode => C_video_mode,
      C_vgahdmi_cache_size => C_vgahdmi_cache_size,
      C_vgahdmi_fifo_data_width => C_vgahdmi_fifo_data_width,
    -- vga textmode + bitmap full feature graphics
    C_vgatext => C_vgatext,
        C_vgatext_label => C_vgatext_label,
        C_vgatext_mode => C_video_mode,
        C_vgatext_bits => C_vgatext_bits,
        C_vgatext_bram_mem => C_vgatext_bram_mem,
        C_vgatext_external_mem => C_vgatext_external_mem,
        C_vgatext_reset => C_vgatext_reset,
        C_vgatext_palette => C_vgatext_palette,
        C_vgatext_bus_read => C_vgatext_bus_read,
        C_vgatext_reg_read => C_vgatext_reg_read,
        C_vgatext_text => C_vgatext_text,
        C_vgatext_font_bram8 => C_vgatext_font_bram8,
        C_vgatext_text_fifo => C_vgatext_text_fifo,
        C_vgatext_text_fifo_step => C_vgatext_text_fifo_step,
        C_vgatext_text_fifo_width => C_vgatext_text_fifo_width,
        C_vgatext_char_height => C_vgatext_char_height,
        C_vgatext_font_height => C_vgatext_font_height,
        C_vgatext_font_depth => C_vgatext_font_depth,
        C_vgatext_font_linedouble => C_vgatext_font_linedouble,
        C_vgatext_font_widthdouble => C_vgatext_font_widthdouble,
        C_vgatext_monochrome => C_vgatext_monochrome,
        C_vgatext_finescroll => C_vgatext_finescroll,
        C_vgatext_cursor => C_vgatext_cursor,
        C_vgatext_cursor_blink => C_vgatext_cursor_blink,
        C_vgatext_bitmap => C_vgatext_bitmap,
        C_vgatext_bitmap_depth => C_vgatext_bitmap_depth,
        C_vgatext_bitmap_fifo => C_vgatext_bitmap_fifo,
        C_vgatext_bitmap_fifo_step => C_vgatext_bitmap_fifo_step,
        C_vgatext_bitmap_fifo_addr_width => C_vgatext_bitmap_fifo_addr_width,
        C_vgatext_bitmap_fifo_data_width => C_vgatext_bitmap_fifo_data_width
  )
  port map (
    clk => clk,
    clk_pixel => clk_pixel,
    clk_pixel_shift => clk_dvi,
    sio_rxd(0) => rx,
    --sio_rxd(1) => open,
    sio_txd(0) => tx,
    --sio_txd(1) => open,
    sio_break(0) => rs232_break,
    sio_break(1) => rs232_break2,

    spi_sck(0)  => open,  spi_sck(1)  => sd_clk,
    spi_ss(0)   => open,  spi_ss(1)   => sd_dat3_csn,
    spi_mosi(0) => open,  spi_mosi(1) => sd_cmd_di,
    spi_miso(0) => open,  spi_miso(1) => sd_dat0_do,

    ADC_Error_out => ADC_Error_out,

    gpio(127 downto 32) => open,

    gpio(24) => GPIO_wordport(0), -- PORTD0 pin D0
    gpio(25) => GPIO_wordport(1), -- PORTD1 pin D1
    gpio(26) => GPIO_wordport(2), -- PORTD2 pin D2
    gpio(27) => GPIO_wordport(3), -- PORTD3 pin D3
    gpio(28) => GPIO_wordport(4), -- PORTD4 pin D4
    gpio(29) => GPIO_wordport(5), -- PORTD5 pin D5
    gpio(30) => GPIO_wordport(6), -- PORTD6 pin D6
    gpio(31) => GPIO_wordport(7), -- PORTD7 pin D7

    gpio(21 downto 16) => ADC_Comp_In,

    gpio(23 downto 22) => open,

    gpio(8) => GPIO_wordport(8),  -- PORTB0 pin D8
    gpio(9) => GPIO_wordport(9),  -- PORTB1 pin D9
    gpio(10) => GPIO_wordport(10),  -- PORTB2 pin D10
    gpio(11) => GPIO_wordport(11),  -- PORTB3 pin D11
    gpio(12) => GPIO_wordport(12),  -- PORTB4 pin D12
    gpio(13) => GPIO_wordport(13),  -- PORTB5 pin D13
    gpio(14) => open,
    gpio(15) => open,

    gpio(7 downto 0) => open,

    simple_out(7 downto 0) => led,
    -- Wifi    simple_out(1) => User_LED2, -- Not available if WiFi option installed
    simple_out(31 downto 8) => open,
    simple_in(0) => NOT User_n_PB1,
    simple_in(31 downto 1) => open,
--    sram_a(18 downto 0) => SRAM_Addr,
--    sram_d(7 downto 0) => SRAM_Data,
--    sram_wel => SRAM_n_we,
    -- Digital Video out (singled ended DDR)
    dvid_red   => dvid_red,
    dvid_green => dvid_green,
    dvid_blue  => dvid_blue,
    dvid_clock => dvid_clock
  );

  -- vendor specific modules to
  -- convert single ended DDR to phyisical output signals
  --G_vgatext_ddrout: entity work.ddr_dvid_out_se
  --port map (
  --  clk       => clk_dvi,
  --  clk_n     => clk_dvin,
  --  in_red    => dvid_red,
  --  in_green  => dvid_green,
  --  in_blue   => dvid_blue,
  --  in_clock  => dvid_clock,
  --  out_red   => LVDS_Red,
  --  out_green => LVDS_Green,
  --  out_blue  => LVDS_Blue,
  --  out_clock => LVDS_ck
  --);
end Behavioral;
