-------------------------------------------------------------------------------
-- Title      : Burst Write Fifo
-- Project    : 
-------------------------------------------------------------------------------
-- File       : burst_write_fifo.vhd
-- Author     : Philip  
-- Created    : 31-12-2022
-------------------------------------------------------------------------------
-- Description: A fifo designed for use with burst write interfaces with a
-- fixed burst length.
--
-- This is a synchronous FIFO, write side and read side must be the same clock.
--
-- There is a reserve interface, which means that burst reads can be "reserved"
-- before the reads actually happen, so we know whether another burst request
-- (e.g. axi aw transaction) can be sent out before the previous ones have finished.
--
-- If the input data width is smaller than the output data width (memory busses
-- are usually wide) the input data will undergo width conversion/upsizing up
-- to the output width. The data will only be written into the FIFO when a full
-- word has been filled.
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.OV7670_util_pkg.ceil_log2;

entity burst_write_fifo is
  generic (
    G_DEPTH_LOG2     : natural := 9;
    G_IN_DATA_WIDTH  : natural := 16;
    G_OUT_DATA_WIDTH : natural := 64;  --This will be the width of the internal FIFO
    G_BURST_LENGTH   : natural := 64;
    G_RAM_STYLE      : string  := "block"  -- "block" "distributed", refer to UG901 
    );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- Write interface
    i_wr_en   : in std_logic;
    i_wr_data : in std_logic_vector(G_IN_DATA_WIDTH - 1 downto 0);

    -- Reserve interface for the read side
    i_rd_burst_reserve : in  std_logic;
    o_rd_burst_avail   : out std_logic;  -- We have at least G_BURST_LENGTH to read in the fifo that is not already reseved
    o_reserve_cnt      : out unsigned(G_DEPTH_LOG2 downto 0);

    i_rd_en   : in  std_logic;
    o_rd_data : out std_logic_vector(G_OUT_DATA_WIDTH - 1 downto 0);

    o_full        : out std_logic;
    o_almost_full : out std_logic;
    o_empty       : out std_logic
    );
end entity;

architecture rtl of burst_write_fifo is

  signal reserve_cnt    : unsigned(G_DEPTH_LOG2 downto 0) := (others => '0');
  signal rd_burst_avail : std_logic                       := '0';

  signal fifo_wr_en       : std_logic                                       := '0';
  signal fifo_wr_data     : std_logic_vector(G_OUT_DATA_WIDTH - 1 downto 0) := (others => '0');
  signal fifo_full        : std_logic                                       := '0';
  signal fifo_almost_full : std_logic                                       := '0';
  signal full_out         : std_logic                                       := '0';
  signal almost_full_out  : std_logic                                       := '0';
begin

  assert (G_OUT_DATA_WIDTH >= G_IN_DATA_WIDTH)
    report "Output data width must be greater than or equal to the input data width"
    severity failure;

  assert (G_OUT_DATA_WIDTH mod G_IN_DATA_WIDTH = 0)
    report "Input data width must be a multiple of the output data width!"
    severity failure;


  p_update_counts : process(clk) is
  begin
    if rising_edge(clk) then
      if i_rd_burst_reserve = '1' and fifo_wr_en = '0' then  --rd reserve  only
        reserve_cnt <= reserve_cnt - G_BURST_LENGTH;
      elsif i_rd_burst_reserve = '0' and fifo_wr_en = '1' then  --wr only
        reserve_cnt <= reserve_cnt + 1;
      elsif i_rd_burst_reserve = '1' and fifo_wr_en = '1' then
        reserve_cnt <= reserve_cnt - G_BURST_LENGTH + 1;  --wr and rd reserve
      end if;
      --Pessimistic calculation for burst avail
      if (i_rd_burst_reserve = '1' and reserve_cnt >= 2*G_BURST_LENGTH)
        or (i_rd_burst_reserve = '0' and reserve_cnt >= G_BURST_LENGTH) then
        rd_burst_avail <= '1';
      else
        rd_burst_avail <= '0';
      end if;

      if rst = '1' then
        reserve_cnt    <= (others => '0');
        rd_burst_avail <= '0';
      end if;
    end if;
  end process;

  -- Perform upsizing before writing data into the FIFO. This is done by
  -- shifting the data into a shift register, and writing the data in when full
  -- (serial in - parallel out)
  gen_width_conv : if G_IN_DATA_WIDTH /= G_OUT_DATA_WIDTH generate
    constant C_UPSIZE_FACTOR : natural                                           := G_OUT_DATA_WIDTH/G_IN_DATA_WIDTH;
    signal upsize_cnt        : unsigned(ceil_log2(C_UPSIZE_FACTOR) - 1 downto 0) := (others => '0');
    signal input_sreg        : std_logic_vector(G_OUT_DATA_WIDTH - 1 downto 0)   := (others => '0');
  begin
    --Upsize the data by shifting the data into a shift register and writing
    --the data every C_UPSIZE_FACTOR number of inputs.
    process(clk) is
    begin
      if rising_edge(clk) then
        if i_wr_en = '1' and full_out = '0' then
          input_sreg <= i_wr_data & input_sreg(input_sreg'high downto G_IN_DATA_WIDTH);
          upsize_cnt <= upsize_cnt + 1;
          if upsize_cnt = C_UPSIZE_FACTOR - 1 then
            upsize_cnt <= (others => '0');
            fifo_wr_en <= '1';
            if fifo_full = '1' then
              full_out <= '1';
            end if;
          end if;
          if upsize_cnt >= C_UPSIZE_FACTOR - 2 then
            if fifo_full = '1' then
              almost_full_out <= '1';
            end if;
          end if;
        end if;

        -- Hold wr en high if the FIFO is full, deassert when the data gets
        -- written in when it is no longer full.
        if fifo_wr_en = '1' and fifo_full = '0' then
          fifo_wr_en <= '0';
        end if;

        if fifo_full = '0' then
          full_out        <= '0';
          almost_full_out <= '0';
        end if;

        if rst = '1' then
          almost_full_out <= '0';
          full_out        <= '0';
          fifo_wr_en      <= '0';
          upsize_cnt      <= (others => '0');
        end if;

      end if;
    end process;

    fifo_wr_data  <= input_sreg;
    o_full        <= full_out;
    o_almost_full <= almost_full_out;
  end generate;

  gen_no_width_conv : if G_IN_DATA_WIDTH = G_OUT_DATA_WIDTH generate
    fifo_wr_en    <= i_wr_en and not fifo_full;
    fifo_wr_data  <= i_wr_data;
    o_full        <= fifo_full;
    o_almost_full <= fifo_almost_full;
  end generate;

  fifo_sync_1 : entity work.fifo_sync
    generic map (
      G_DEPTH_LOG2 => G_DEPTH_LOG2,
      G_DATA_WIDTH => G_OUT_DATA_WIDTH,
      G_RAM_STYLE  => G_RAM_STYLE)
    port map (
      clk           => clk,
      rst           => rst,
      i_wr_en       => fifo_wr_en,
      i_wr_data     => fifo_wr_data,
      i_rd_en       => i_rd_en,
      o_rd_data     => o_rd_data,
      o_full        => fifo_full,
      o_almost_full => fifo_almost_full,
      o_empty       => o_empty);

  o_rd_burst_avail <= rd_burst_avail;
  o_reserve_cnt    <= reserve_cnt;
end;
