-------------------------------------------------------------------------------
-- Title      : Button debouncer
-- Project    : OV7670
-------------------------------------------------------------------------------
-- File       : button_debouncer.vhd
-- Author     : Philip  
-- Created    : 09-04-2023
-------------------------------------------------------------------------------
-- Description: A button debouncer. Input is assumed to be asynchronous and will
-- be synchronised within this moudule
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.OV7670_util_pkg.ceil_log2;

entity button_debouncer is
  generic (
    G_N_CLKS_MAX : natural := 5e6       --50ms with 100MHz clk
    );
  port (
    clk : in std_logic;
    i_din  : in  std_logic;            
    o_dout : out std_logic
    );
end entity;

architecture rtl of button_debouncer is

  signal din_sync     : std_logic;      --only use this synchronised signal
  signal debounce_cnt : unsigned(ceil_log2(G_N_CLKS_MAX + 1) - 1 downto 0) := (others=> '0');
  signal dout         : std_logic := '0';

begin

  sync_ff_1: entity work.sync_ff
    generic map (
      G_REGISTER_STAGES => 3)
    port map (
      clk   => clk,
      i_bit => i_din,
      o_bit => din_sync);

  p_debounce_input : process(clk)
  begin
    if rising_edge(clk) then
      -- Input is different to output, increment counter
      if din_sync /= dout then
        debounce_cnt <= debounce_cnt + 1;
        if debounce_cnt = G_N_CLKS_MAX - 1 then
          debounce_cnt <= (others => '0');
          dout         <= din_sync;
        end if;
      else
        debounce_cnt <= (others => '0');
      end if;
    end if;
  end process;

  o_dout <= dout;

end architecture;
