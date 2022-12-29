-------------------------------------------------------------------------------
-- Title      : capture
-- Project    : 
-------------------------------------------------------------------------------
-- File       : capture.vhd
-- Author     : Philip
-- Created    : 27-12-2022
-------------------------------------------------------------------------------
-- Description: Samples pixel value from the OV7670 module, outputs on a video
-- bus. Expects ov7670 module to be set to RGB565 format.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity capture is
  generic (
    G_BIT_DEPTH_R  : natural := 5;
    G_BIT_DEPTH_G  : natural := 6;
    G_BIT_DEPTH_B  : natural := 5;
    G_FRAME_HEIGHT : natural := 480;     -- VGA 640x480 
    G_FRAME_WIDTH  : natural := 640 
    );
  port (
    pclk : in std_logic;                --pixel clock
    rst  : in std_logic;

    -- OV7670 interface
    i_data  : in std_logic_vector(7 downto 0);
    i_vsync : in std_logic;
    i_href  : in std_logic;

    o_pxl_r   : out std_logic_vector(G_BIT_DEPTH_R - 1 downto 0);
    o_pxl_g   : out std_logic_vector(G_BIT_DEPTH_G - 1 downto 0);
    o_pxl_b   : out std_logic_vector(G_BIT_DEPTH_B - 1 downto 0);
    o_pxl_vld : out std_logic;
    o_sof     : out std_logic;          -- start of frame
    o_eos     : out std_logic  -- end of stream, after last valid pixel in frame
    );

end entity capture;

architecture rtl of capture is
  --TODO add to common package
  function ceil_log2(num : natural) return natural is
  begin
    for i in 0 to 31 loop
      if num <= 2**i then
        return i;
      end if;
    end loop;
  end function;

  signal pxl_data : std_logic_vector(G_BIT_DEPTH_R + G_BIT_DEPTH_G + G_BIT_DEPTH_B - 1 downto 0) := (others => '0');

  signal pxl_vld     : std_logic                                        := '0';
  signal second_byte : std_logic                                        := '0';
  signal vsync_d     : std_logic                                        := '0';
  signal sof         : std_logic                                        := '0';
  signal href_d      : std_logic                                        := '0';
  signal line_cnt    : unsigned(ceil_log2(G_FRAME_HEIGHT) - 1 downto 0) := (others => '0');
  signal eos         : std_logic                                        := '0';
begin
  -- The RGB data comes over two byte words over two clocks. Refer to
  -- Figure 11 RGB 565 Output Timing Diagram, in the OV7670 datasheet
  process(pclk)
  begin
    if rising_edge(pclk) then
      pxl_vld <= '0';
      if i_href = '1' then
        -- shift in the data over two clock cycles 
        pxl_data <= pxl_data(7 downto 0) & i_data;
        if second_byte = '1' then
          pxl_vld <= '1';
        end if;
        second_byte <= not second_byte;
      end if;
      if rst = '1' then
        second_byte <= '0';
        pxl_vld     <= '0';
      end if;
    end if;
  end process;

  o_pxl_r   <= pxl_data(pxl_data'high downto pxl_data'high - G_BIT_DEPTH_R + 1);
  o_pxl_g   <= pxl_data(G_BIT_DEPTH_G + G_BIT_DEPTH_B - 1 downto G_BIT_DEPTH_B);
  o_pxl_b   <= pxl_data(G_BIT_DEPTH_B - 1 downto 0);
  o_pxl_vld <= pxl_vld;

  -- Generate the sof (start of frame) flag. Technically this should be the
  -- first first pixel of blanking in first line, but to save some counters,
  -- lets just detect the rising edge of vsync
  process(pclk)
  begin
    if rising_edge(pclk) then
      vsync_d <= i_vsync;
      sof     <= i_vsync and not vsync_d;  -- rising edge of vsync
    end if;
  end process;
  o_sof <= sof;

  -- Generate an "end of stream" flag for the end of a frame. This will be
  -- used by the following module to flush the rest of their pipelines
  process(pclk)
  begin
    if rising_edge(pclk) then
      -- Count falling edge of href
      eos    <= '0';
      href_d <= i_href;
      if i_href = '0' and href_d = '1' then
        line_cnt <= line_cnt + 1;
        if line_cnt = G_FRAME_HEIGHT - 1 then
          eos <= '1';
        end if;
      end if;
      if rst = '1' or i_vsync = '1' then
        line_cnt <= (others => '0');
      end if;
    end if;
  end process;

  o_eos <= eos;

end;
