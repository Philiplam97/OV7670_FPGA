------------------------------------------------------------------------------- 
-- Title      : VGA                                                             
-- Project    : OV7670                                                          
------------------------------------------------------------------------------- 
-- File       : VGA.vhd                                                         
-- Author     : Philip                                                          
-- Created    : 23-03-2023                                                      
------------------------------------------------------------------------------- 
-- Description: VGA driver                                                  
------------------------------------------------------------------------------- 
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.OV7670_util_pkg.ceil_log2;

entity VGA is
  --default values corresponding to vga 640*480 60Hz
  generic (
    G_FRAME_WIDTH  : natural   := 640;
    G_FRAME_HEIGHT : natural   := 480;
    G_H_FP         : natural   := 16;  --Horizontal front porch in number of pixels/clk ticks 
    G_H_BP         : natural   := 48;   --Horizontal back porch
    G_H_PULSE      : natural   := 96;   -- Horizontal pulse width
    G_V_FP         : natural   := 10;  -- Vertical front porch in number of lines 
    G_V_BP         : natural   := 33;   --Vertical back porch
    G_V_PULSE      : natural   := 2;    -- Vertical pulse width
    G_SYNC_POL     : std_logic := '0';  --Polarity of sync signals
    G_PIXEL_WIDTH  : natural   := 4
    );
  port (
    clk : in std_logic;
    rst : in std_logic;

    i_pxl_en : in std_logic;

    i_red   : in unsigned(G_PIXEL_WIDTH - 1 downto 0);
    i_green : in unsigned(G_PIXEL_WIDTH - 1 downto 0);
    i_blue  : in unsigned(G_PIXEL_WIDTH - 1 downto 0);

    o_hsync : out std_logic;
    o_vsync : out std_logic;

    o_red   : out unsigned(G_PIXEL_WIDTH - 1 downto 0);
    o_green : out unsigned(G_PIXEL_WIDTH - 1 downto 0);
    o_blue  : out unsigned(G_PIXEL_WIDTH - 1 downto 0);

    -- Signals for framing or keeping track of current pixel. Keep unconnected
    -- if unused
    o_sof    : out std_logic;           -- Start of frame
    o_sav    : out std_logic;           -- Start of active video line
    o_eav    : out std_logic;           -- End of active video line
    o_vblank : out std_logic            -- Vertical blanking
    );
end;
architecture rtl of VGA is

  constant C_LINE_WIDTH    : natural := G_FRAME_WIDTH + G_H_FP + G_H_PULSE + G_H_BP;  --width in pixels of each line, 800 for 640*480 60 Hz VGA
  constant C_SCREEN_HEIGHT : natural := G_FRAME_HEIGHT + G_V_FP + G_V_PULSE + G_V_BP; --525 for 640*480 VGA
  constant C_HS_START      : natural := G_H_BP + G_FRAME_WIDTH + G_H_FP;              --number of clock cycles until hsync is asserted
  constant C_HS_END        : natural := G_H_BP + G_FRAME_WIDTH + G_H_FP + G_H_PULSE;  --number of clock cycles until hsync is deasserted
  constant C_VS_START      : natural := G_V_BP + G_FRAME_HEIGHT + G_V_FP;
  constant C_VS_END        : natural := G_V_BP + G_FRAME_HEIGHT + G_V_FP + G_V_PULSE;

  signal h_cnt : unsigned(ceil_log2(C_LINE_WIDTH + 1) - 1 downto 0);
  signal v_cnt : unsigned(ceil_log2(C_SCREEN_HEIGHT + 1) - 1 downto 0);

  signal h_sync : std_logic;
  signal v_sync : std_logic;

  signal active_video : std_logic;

  signal red   : unsigned(G_PIXEL_WIDTH - 1 downto 0);
  signal green : unsigned(G_PIXEL_WIDTH - 1 downto 0);
  signal blue  : unsigned(G_PIXEL_WIDTH - 1 downto 0);

  signal sof    : std_logic := '0';
  signal sav    : std_logic := '0';
  signal eav    : std_logic := '0';
  signal vblank : std_logic := '1';

begin
  --increment the horizontal and vertical position counters
  p_position_counters : process (clk)
  begin
    if rising_edge(clk) then
      if i_pxl_en = '1' then
        if h_cnt = C_LINE_WIDTH - 1 then  -- reached end of line
          h_cnt <= (others => '0');
          -- Update vsync here for next line
          if (v_cnt >= C_VS_START - 1 and v_cnt < C_VS_END - 1) then
            v_sync <= G_SYNC_POL;
          else
            v_sync <= not G_SYNC_POL;
          end if;
          if v_cnt = C_SCREEN_HEIGHT - 1 then
            v_cnt <= (others => '0');
          else
            v_cnt <= v_cnt + 1;
          end if;
        else
          h_cnt <= h_cnt + 1;
        end if;
      end if;
      --reset
      if rst = '1' then
        h_cnt <= (others => '0');
        v_cnt <= (others => '0');
      end if;
    end if;
  end process;

  --generate output horizontal sync
  p_hsync_output : process (clk)
  begin
    if rising_edge(clk) then
      if i_pxl_en = '1' then
        if (h_cnt >= C_HS_START - 1 and h_cnt < C_HS_END - 1) then
          h_sync <= G_SYNC_POL;
        else
          h_sync <= not G_SYNC_POL;
        end if;
      end if;
    end if;
  end process;

  p_framing : process(clk)
  begin
    if rising_edge(clk) then
      if i_pxl_en = '1' then
        --sav asserted one pixel before active period
        if h_cnt = G_H_BP - 1 - 1 then
          sav <= '1';
        else
          sav <= '0';
        end if;
        -- eav asserted on last pixel of active period
        if h_cnt = G_H_BP + G_FRAME_WIDTH - 1 - 1 then
          eav <= '1';
        else
          eav <= '0';
        end if;
        -- Start of frame flag. High at first pixel of blanking in first line
        if h_cnt = C_LINE_WIDTH - 1 and v_cnt = C_SCREEN_HEIGHT - 1 then
          sof <= '1';
        else
          sof <= '0';
        end if;
        -- vblank asserted on vertical blanking lines
        -- This will be delayed by one pixel, but will be valid
        -- alongside sav and eav signals
        if v_cnt > G_V_BP - 1 and v_cnt < G_FRAME_HEIGHT + G_V_BP then
          vblank <= '0';
        else
          vblank <= '1';
        end if;
      end if;
    end if;
  end process;

  -- Set output pixel
  p_set_pix_output : process(clk)
  begin
    if rising_edge(clk) then
      if i_pxl_en = '1' then
        if active_video = '1' or (sav = '1'and vblank = '0') then
          if eav = '1' then
            active_video <= '0';
            red          <= (others => '0');
            green        <= (others => '0');
            blue         <= (others => '0');
          else
            active_video <= '1';
            red          <= i_red;
            green        <= i_green;
            blue         <= i_blue;
          end if;
        else
          red          <= (others => '0');
          green        <= (others => '0');
          blue         <= (others => '0');
          active_video <= '0';
        end if;
      end if;
    end if;
  end process;

  o_hsync <= h_sync;
  o_vsync <= v_sync;

  o_red   <= red;
  o_green <= green;
  o_blue  <= blue;

  o_sof    <= sof;
  o_sav    <= sav;
  o_eav    <= eav;
  o_vblank <= vblank;

end;
