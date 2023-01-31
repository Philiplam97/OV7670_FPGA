-------------------------------------------------------------------------------
-- Title      : Synchronous FIFO
-- Project    : 
-------------------------------------------------------------------------------
-- File       : fifo_sync.vhd
-- Author     : Philip
-- Created    : 26-12-2022
-------------------------------------------------------------------------------
-- Description: Synchronous FIFO with FWFT. Writes when full and reads when
-- empty are protected
--TODO add output register
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity fifo_sync is
  generic (
    G_DEPTH_LOG2 : natural := 11;
    G_DATA_WIDTH : natural := 16;
    G_RAM_STYLE  : string  := "block"  -- "block" "distributed", refer to UG901 
    );
  port(
    clk       : in std_logic;
    rst       : in std_logic;
    i_wr_en   : in std_logic;
    i_wr_data : in std_logic_vector(G_DATA_WIDTH - 1 downto 0);

    i_rd_en   : in  std_logic;
    o_rd_data : out std_logic_vector(G_DATA_WIDTH - 1 downto 0);

    o_full        : out std_logic;
    o_almost_full : out std_logic;
    o_empty       : out std_logic
    );
end entity;

architecture rtl of fifo_sync is

  signal rd_data : std_logic_vector(G_DATA_WIDTH - 1 downto 0) := (others => '0');
  signal wr_en   : std_logic                                   := '0';
  signal rd_en   : std_logic                                   := '0';
  signal wr_addr : unsigned(G_DEPTH_LOG2 - 1 downto 0)         := (others => '0');
  signal rd_addr : unsigned(G_DEPTH_LOG2 - 1 downto 0)         := (others => '0');

  signal full        : std_logic := '0';
  signal almost_full : std_logic := '0';
  signal empty       : std_logic := '1';  --internal empty signal
  signal fwft_empty  : std_logic := '1';  --empty at output interface
  signal fwft_rd_en  : std_logic := '0';

  signal count : unsigned(G_DEPTH_LOG2 downto 0) := (others => '0');
begin

  --protected writes and reads
  rd_en <= fwft_rd_en and not empty;
  wr_en <= i_wr_en and not full;

  p_update_addr : process(clk)
  begin
    if rising_edge(clk) then
      if wr_en = '1' then
        wr_addr <= wr_addr + 1;
      end if;

      if rd_en = '1' then
        rd_addr <= rd_addr + 1;
      end if;

      if rst = '1' then
        wr_addr <= (others => '0');
        rd_addr <= (others => '0');
      end if;
    end if;
  end process;

  p_update_count_flags : process(clk)
  begin
    if rising_edge(clk) then
      if wr_en = '1' and rd_en = '0' then     --write, no read
        count <= count + 1;
        empty <= '0';
        if count = 2**G_DEPTH_LOG2 - 2 then
          almost_full <= '1';
        else
          almost_full <= '0';
        end if;
        full <= almost_full;
      elsif rd_en = '1' and wr_en = '0' then  --read, no write
        full        <= '0';
        almost_full <= full;
        count       <= count - 1;
        if count = 1 then
          empty <= '1';
        else
          empty <= '0';
        end if;
      end if;  --otherwise read & write - no change in flags and counts

      if rst = '1' then
        full        <= '0';
        almost_full <= '0';
        empty       <= '1';
        count       <= (others => '0');
      end if;
    end if;
  end process;

  ram_sdp_0 : entity work.ram_sdp
    generic map (
      G_DEPTH_LOG2 => G_DEPTH_LOG2,
      G_DATA_WIDTH => G_DATA_WIDTH,
      G_RAM_STYLE  => G_RAM_STYLE)
    port map (
      clk       => clk,
      i_wr_addr => wr_addr,
      i_wr_en   => wr_en,
      i_wr_data => i_wr_data,
      i_rd_en   => fwft_rd_en,
      i_rd_addr => rd_addr,
      o_rd_data => rd_data);

  -- FWFT conversion
  p_FWFT : process(clk)
  begin
    if rising_edge(clk) then
      if fwft_rd_en = '1' then
        fwft_empty <= '0';
      elsif i_rd_en = '1' then
        fwft_empty <= '1';
      end if;
      if rst = '1' then
        fwft_empty <= '1';
      end if;
    end if;
  end process;

  fwft_rd_en <= not empty and (fwft_empty or i_rd_en);

  o_rd_data     <= rd_data;
  o_full        <= full;
  o_almost_full <= almost_full;
  o_empty       <= fwft_empty;

end;

