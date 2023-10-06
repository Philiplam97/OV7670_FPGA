-------------------------------------------------------------------------------
-- Title      : OV7670 Wrapper
-- Project    : OV7670
-------------------------------------------------------------------------------
-- File       : OV7670_wrapper.vhd
-- Author     : Philip
-- Created    : 02-03-2023
-------------------------------------------------------------------------------
-- Description: A wrapper for modules interfacing with the OV7670 module
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.OV7670_util_pkg.ceil_log2;
use work.OV7670_regs_pkg.all;

entity OV7670_wrapper is
  generic (
    G_BIT_DEPTH_R  : natural := 5;
    G_BIT_DEPTH_G  : natural := 6;
    G_BIT_DEPTH_B  : natural := 5;
    G_FRAME_HEIGHT : natural := 480;  -- VGA 640x480                                               
    G_FRAME_WIDTH  : natural := 640;
    G_CLK_FREQ     : natural := 100e6
    );
  port (
    pclk : in std_logic;  --pixel clock                                                 
    prst : in std_logic;

    SCCB_clk : in std_logic;
    SCCB_rst : in std_logic;

    i_start_config : in std_logic;

    -- OV7670 interface                                                                               
    i_data  : in std_logic_vector(7 downto 0);
    i_vsync : in std_logic;
    i_href  : in std_logic;

    o_pxl_r   : out std_logic_vector(G_BIT_DEPTH_R - 1 downto 0);
    o_pxl_g   : out std_logic_vector(G_BIT_DEPTH_G - 1 downto 0);
    o_pxl_b   : out std_logic_vector(G_BIT_DEPTH_B - 1 downto 0);
    o_pxl_vld : out std_logic;
    o_sof     : out std_logic;  -- start of frame                                             
    o_eos     : out std_logic;  -- end of stream, after last valid pixel in frame                      

    -- SCCB interface
    o_SIO_C  : out   std_logic;
    io_SIO_D : inout std_logic
    );

end entity OV7670_wrapper;

architecture rtl of OV7670_wrapper is
  type t_config_state is (IDLE, RESET, CONFIG);
  signal config_state : t_config_state               := IDLE;
  signal sccb_addr    : unsigned(7 downto 0);
  signal sccb_vld     : std_logic;
  signal sccb_rdy     : std_logic;
  signal sccb_id      : std_logic_vector(6 downto 0) := "0100001";  --0x21
  signal sccb_data    : std_logic_vector(7 downto 0);
  signal config_cnt   : unsigned(7 downto 0);                       -- TODO

  signal sreg : std_logic_vector(15 downto 0);

  --1ms counter
  constant C_CNT_1MS_THRESHOLD : natural := G_CLK_FREQ / 1000 - 1;
  signal cnt_1ms               : unsigned(ceil_log2(C_CNT_1MS_THRESHOLD + 1) - 1 downto 0);
begin

  capture_1 : entity work.capture
    generic map (
      G_BIT_DEPTH_R  => G_BIT_DEPTH_R,
      G_BIT_DEPTH_G  => G_BIT_DEPTH_G,
      G_BIT_DEPTH_B  => G_BIT_DEPTH_B,
      G_FRAME_HEIGHT => G_FRAME_HEIGHT,
      G_FRAME_WIDTH  => G_FRAME_WIDTH)
    port map (
      pclk      => pclk,
      rst       => prst,
      i_data    => i_data,
      i_vsync   => i_vsync,
      i_href    => i_href,
      o_pxl_r   => o_pxl_r,
      o_pxl_g   => o_pxl_g,
      o_pxl_b   => o_pxl_b,
      o_pxl_vld => o_pxl_vld,
      o_sof     => o_sof,
      o_eos     => o_eos);

  sccb_id <= "0100001";                 --0x21 OV7670 address

  SCCB_1 : entity work.SCCB
    generic map (
      G_CLK_FREQ => G_CLK_FREQ)
    port map (
      clk       => SCCB_clk,
      rst       => sccb_rst,
      i_data    => sccb_data,
      i_subaddr => std_logic_vector(sccb_addr),
      i_id      => sccb_id,
      i_vld     => sccb_vld,
      o_rdy     => sccb_rdy,
      o_SIO_C   => o_SIO_C,
      io_SIO_D  => io_SIO_D);

  -- OV7670 Register configuration
  -- Need to investigate these further. TODO add a uart interface to set the
  -- registers manually to test some stuff.
  p_config : process(SCCB_clk)
  begin
    if rising_edge(SCCB_clk) then
      case config_state is
        when IDLE =>
          sccb_vld   <= '0';
          config_cnt <= (others => '0');
          cnt_1ms    <= (others => '0');
          if i_start_config = '1' then
            config_state <= RESET;
            sccb_vld     <= '1';
            sccb_addr    <= C_REGS_ADDR(COM7);
            sccb_data    <= x"80";      -- Issue reset
          end if;
        when RESET =>
          if sccb_vld = '1' and sccb_rdy = '1' then
            sccb_vld <= '0';
          end if;
          -- Wait 1ms from reset to writing the next registers
          cnt_1ms <= cnt_1ms + 1;
          if cnt_1ms = C_CNT_1MS_THRESHOLD then
            sccb_vld  <= '1';
            sccb_addr <= C_REGS_ADDR(COM7);
            sccb_data <= x"04";
          end if;
        when CONFIG =>
          if sccb_vld = '1' and sccb_rdy = '1' then
            config_cnt <= config_cnt + 1;
            case to_integer(config_cnt) is
              when 0 =>
                sccb_addr <= C_REGS_ADDR(CLKRC);
                sccb_data <= x"40"; 
              when 1 =>
                sccb_addr <= C_REGS_ADDR(COM15);
                sccb_data <= x"D0";     -- Full output range, RGB565
              when 2 =>
                sccb_addr <= C_REGS_ADDR(COM13);
                sccb_data <= x"C0";  -- UV saturation level - auto adjustment?
              when others =>
                config_state <= IDLE;
                sccb_addr    <= (others => '0');
                sccb_vld     <= '0';
            end case;
          end if;
      end case;
      if SCCB_rst = '1' then
        config_state <= IDLE;
        sccb_vld     <= '0';
        cnt_1ms      <= (others => '0');
      end if;
    end if;
  end process;
end architecture;
