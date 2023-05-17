-------------------------------------------------------------------------------
-- Title      : Sync Pulse
-- Project    : 
-------------------------------------------------------------------------------
-- File       : sync_pulse.vhd
-- Author     : Philip
-- Created    : 01-02-2023
-------------------------------------------------------------------------------
-- Description:
-- A pulse synchroniser. Used to cross a pulse from one clock domain to another
-- Input pulse can be single cycle or longer. Output will be a generated single
-- cycle pulse in the destination clock domain. Note that if crossing from a
-- fast to a slow clock domain pulses on the input side can not occur back to back,
-- too frequent pulses will be missed in the destinaiton clok domain. There
-- should be no more than one pulse per  
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sync_pulse is
  generic (
    G_REGISTER_STAGES : natural := 2    --number of synchroniser flip flops
    );
  port (
    clk_a   : in std_logic;
    i_pulse : in std_logic;

    clk_b   : in  std_logic;
    o_pulse : out std_logic
    );

end entity;

architecture rtl of sync_pulse is
  signal pulse_in_d : std_logic := '0';
  signal toggle_src : std_logic := '0';

  signal toggle_sync   : std_logic_vector(G_REGISTER_STAGES - 1 downto 0) := (others => '0');
  signal toggle_sync_d : std_logic                                        := '0';
  signal out_pulse     : std_logic                                        := '0';

  attribute ASYNC_REG                : string;
  attribute ASYNC_REG of toggle_sync : signal is "TRUE";

begin
  -- src clock domain
  -- Detect risign edge cand convert to a level change
  p_src : process(clk_a)
  begin
    if rising_edge(clk_a) then
      -- detect rising edge of input pulse
      pulse_in_d <= i_pulse;
      if pulse_in_d = '0' and i_pulse = '1' then
        toggle_src <= not toggle_src;
      end if;
    end if;
  end process;

  --Synchronise the level/toggle signal
  p_sync : process(clk_b)
  begin
    if rising_edge(clk_b) then
      toggle_sync <= toggle_sync(toggle_sync'high - 1 downto 0) & toggle_src;
    end if;
  end process;

  -- Destination clock domain
  -- Convert level change to pulse
  p_out_pulse : process(clk_b)
  begin
    if rising_edge(clk_b) then
      toggle_sync_d <= toggle_sync(toggle_sync'high);
      --transistion
      if (toggle_sync_d xor toggle_sync(toggle_sync'high)) = '1' then
        out_pulse <= '1';
      else
        out_pulse <= '0';
      end if;
    end if;
  end process;

  o_pulse <= out_pulse;
end;
