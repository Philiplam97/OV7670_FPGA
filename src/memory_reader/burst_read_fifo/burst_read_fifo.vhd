-------------------------------------------------------------------------------
-- Title      : Burst Read Fifo
-- Project    : 
-------------------------------------------------------------------------------
-- File       : burst_read_fifo.vhd
-- Author     : Philip  
-- Created    : 30-12-2022
-------------------------------------------------------------------------------
-- Description: A fifo designed for use with sinking reads from burst interfaces.
-- Burst lengths are fixed, and set by G_BURST_LENGTH. Assert the burst reserve
-- input before the data is written into this FIFO (e.g. when the AR
-- transaction in AXI happens). Asserting the burst reserve input will allocate
-- space in this fifo for the incoming data burst.
--
-- Burst ready will be deasserted when all the space in the fifo has been
-- reserved/used and no more bursts can be received.
-- It is assumed that the correct number of writes will come in after the space
-- is reserved for a burst - if this is not true the burst ready output will not be correct!
-- 
-- Output data width must be smaller than or equal to input width. If smaller than,
-- the data undergoes downsizing on the output side after the fifo
-- e.g. write 64 bits, read out 16 bits
--
-- This is a synchronous FIFO, write side and read side must be the same clock.
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.OV7670_util_pkg.ceil_log2;

entity burst_read_fifo is
  generic (
    G_DEPTH_LOG2     : natural := 9;
    G_IN_DATA_WIDTH  : natural := 64;  -- This will be the  width of the internal FIFO
    G_OUT_DATA_WIDTH : natural := 16;
    G_BURST_LENGTH   : natural := 64;
    G_RAM_STYLE      : string  := "block"  -- "block" "distributed", refer to UG901 
    );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- Reserve interface for the write side
    i_wr_burst_reserve : in  std_logic;
    o_wr_burst_avail   : out std_logic;  -- We have at least G_BURST_LENGTH free
    -- and not reserved in the FIFO

    -- Write interface
    i_wr_en   : in std_logic;
    i_wr_data : in std_logic_vector(G_IN_DATA_WIDTH - 1 downto 0);

    i_rd_en   : in  std_logic;
    o_rd_data : out std_logic_vector(G_OUT_DATA_WIDTH - 1 downto 0);

    o_full  : out std_logic;
    o_empty : out std_logic
    );
end entity;

architecture rtl of burst_read_fifo is

  signal reserve_cnt    : unsigned(G_DEPTH_LOG2 downto 0) := (others => '0');
  signal wr_burst_avail : std_logic                       := '0';

  signal fifo_rd_en   : std_logic                                      := '0';
  signal fifo_rd_data : std_logic_vector(G_IN_DATA_WIDTH - 1 downto 0) := (others => '0');
  signal fifo_empty   : std_logic                                      := '0';
  signal empty_out    : std_logic                                      := '0';

begin

  assert (G_OUT_DATA_WIDTH <= G_IN_DATA_WIDTH)
    report "Output data width must be less than or equal to the input data width"
    severity failure;

  assert (G_IN_DATA_WIDTH mod G_OUT_DATA_WIDTH = 0)
    report "Input data width must be a multiple of the output data width!"
    severity failure;


  p_update_counts : process(clk) is
  begin
    if rising_edge(clk) then
      if fifo_rd_en = '1' and i_wr_burst_reserve = '0' then     --rd only
        reserve_cnt <= reserve_cnt - 1;
      elsif i_wr_burst_reserve = '1' and fifo_rd_en = '0' then  --wr reserve only
        reserve_cnt <= reserve_cnt + G_BURST_LENGTH;
      elsif i_wr_burst_reserve = '1' and fifo_rd_en = '1' then
        reserve_cnt <= reserve_cnt + G_BURST_LENGTH - 1;  --rd and wr reserve
      end if;
      --Pessimistic calculation for burst avail
      if reserve_cnt + G_BURST_LENGTH <= 2** G_DEPTH_LOG2 - G_BURST_LENGTH then
        wr_burst_avail <= '1';
      else
        wr_burst_avail <= '0';
      end if;

      if rst = '1' then
        reserve_cnt <= (others => '0');
      end if;
    end if;
  end process;

  gen_width_conv : if G_IN_DATA_WIDTH /= G_OUT_DATA_WIDTH generate
    constant C_DOWNSIZE_FACTOR : natural                                             := G_IN_DATA_WIDTH/G_OUT_DATA_WIDTH;
    signal downsize_cnt        : unsigned(ceil_log2(C_DOWNSIZE_FACTOR) - 1 downto 0) := (others => '0');
    signal output_sreg         : std_logic_vector(G_IN_DATA_WIDTH - 1 downto 0)      := (others => '0');
  begin

    -- Use a shift register and a counter to output the fifo data in the smaller
    -- data width.
    process(clk) is
    begin
      if rising_edge(clk) then

        if fifo_empty = '0' and empty_out = '1' then
          --Output is empty but fifo has data
          fifo_rd_en  <= '1';
          empty_out   <= '0';
          output_sreg <= fifo_rd_data;
        elsif i_rd_en = '1' and empty_out = '0' then
          if downsize_cnt = C_DOWNSIZE_FACTOR - 1 then
            -- We have output all data in the shift register, read the fifo
            -- again if it is not empty to fill the output register
            downsize_cnt <= (others => '0');
            if fifo_empty = '0' then
              fifo_rd_en  <= '1';
              output_sreg <= fifo_rd_data;
              empty_out   <= '0';
            else                        --fifo is empty
              fifo_rd_en <= '0';
              empty_out  <= '1';
            end if;
          else
            -- Right shift the output shift register by the output data width
            fifo_rd_en   <= '0';
            downsize_cnt <= downsize_cnt + 1;
            output_sreg  <= (G_OUT_DATA_WIDTH - 1 downto 0 => '0') & output_sreg(output_sreg'high downto G_OUT_DATA_WIDTH);
          end if;
        else
          fifo_rd_en <= '0';
        end if;

        if rst = '1' then
          downsize_cnt <= (others=> '0');
          fifo_rd_en <= '0';
          empty_out <= '1';
        end if;
      end if;
    end process;

    o_rd_data <= output_sreg(G_OUT_DATA_WIDTH - 1 downto 0);
    o_empty   <= empty_out;
  end generate;

  gen_no_width_conv : if G_IN_DATA_WIDTH = G_OUT_DATA_WIDTH generate
    fifo_rd_en <= i_rd_en and not fifo_empty;
    o_rd_data  <= fifo_rd_data;
    o_empty    <= fifo_empty;
  end generate;

  fifo_sync_1 : entity work.fifo_sync
    generic map (
      G_DEPTH_LOG2 => G_DEPTH_LOG2,
      G_DATA_WIDTH => G_IN_DATA_WIDTH,
      G_RAM_STYLE  => G_RAM_STYLE)
    port map (
      clk       => clk,
      rst       => rst,
      i_wr_en   => i_wr_en,
      i_wr_data => i_wr_data,
      i_rd_en   => fifo_rd_en,
      o_rd_data => fifo_rd_data,
      o_full    => o_full,
      o_empty   => fifo_empty);

  o_wr_burst_avail <= wr_burst_avail;
end;
