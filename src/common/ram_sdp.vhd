-------------------------------------------------------------------------------
-- Title      : Simple Dual Port Ram
-- Project    : 
-------------------------------------------------------------------------------
-- File       : ram_sdp.vhd
-- Author     : Philip
-- Created    : 26-12-2022
-------------------------------------------------------------------------------
-- Description: 
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ram_sdp is
  generic (
    G_DEPTH_LOG2 : natural;
    G_DATA_WIDTH : natural;
    G_OUTPUT_REG : boolean := false;
    G_RAM_STYLE  : string := "block" -- "block" "distributed", refer to UG901 
    );
  port(
    clk       : in std_logic;
    rst       : in std_logic := '0'; -- only resets output register if used
    i_wr_addr : in unsigned(G_DEPTH_LOG2 - 1 downto 0);
    i_wr_en   : in std_logic;
    i_wr_data : in std_logic_vector(G_DATA_WIDTH - 1 downto 0);

    i_rd_en   : in  std_logic;
    i_reg_ce  : in std_logic := '1'; --only used if output reg enabled
    i_rd_addr : in  unsigned(G_DEPTH_LOG2 - 1 downto 0);
    o_rd_data : out std_logic_vector(G_DATA_WIDTH - 1 downto 0)
    );
end entity;

architecture rtl of ram_sdp is

  signal rd_data : std_logic_vector(G_DATA_WIDTH - 1 downto 0) := (others => '0');

  type t_ram is array (0 to 2**G_DEPTH_LOG2 - 1) of std_logic_vector(G_DATA_WIDTH - 1 downto 0);
  signal ram : t_ram;

  attribute ram_style        : string;
  attribute ram_style of ram : signal is G_RAM_STYLE;

begin

  process(clk)
  begin
    if rising_edge(clk) then
      if i_wr_en = '1' then
        ram(to_integer(i_wr_addr)) <= i_wr_data;
      end if;
      if i_rd_en = '1' then
        rd_data <= ram(to_integer(i_rd_addr));
      end if;
    end if;
  end process;

  GEN_NO_OUTPUT_REG : if not G_OUTPUT_REG generate 
    o_rd_data <= rd_data;
  end generate;

  GEN_OUTPUT_REG : if G_OUTPUT_REG generate
    signal rd_data_reg : std_logic_vector(G_DATA_WIDTH - 1 downto 0) := (others => '0');
  begin
    process(clk)
    begin
      if rising_edge(clk) then
        if i_reg_ce = '1' then
          rd_data_reg <= rd_data;
        end if;
        if rst = '1' then
          rd_data_reg <= (others => '0');
        end if;
      end if;
    end process;
    o_rd_data <= rd_data_reg;
  end generate;
  
end;

