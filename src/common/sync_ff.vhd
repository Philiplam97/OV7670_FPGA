-------------------------------------------------------------------------------
-- Title      : sync_ff
-- Project    : OV7670
-------------------------------------------------------------------------------
-- File       : sync_ff.vhd
-- Author     : Philip  
-- Created    : 08-04-2023
-------------------------------------------------------------------------------
-- Description: Sync Flip Flop - a single bit synchroniser using flip flops.
-- DOn't connect reset input if it is not needed.
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;

entity sync_ff is
  generic(G_REGISTER_STAGES : natural   := 2;
          G_RESET_POL       : std_logic := '1';
          G_RESET_VAL       : std_logic := '0');
  port (
    clk : in std_logic;
    rst : in std_logic := not G_RESET_POL; 

    i_bit : in  std_logic;
    o_bit : out std_logic
    );
end entity;

architecture rtl of sync_ff is
  -- Synchronisation flip flops 
  signal sync_regs : std_logic_vector(G_REGISTER_STAGES - 1 downto 0);

  attribute ASYNC_REG              : string;
  attribute ASYNC_REG of sync_regs : signal is "TRUE";
begin
  
  assert (G_REGISTER_STAGES > 1)
    report "A synchronisation chain needs more than 1 flip flop. G_REGISTER_STAGES is currently set to "
    & integer'image(G_REGISTER_STAGES) & ". Did you mean to do this?"
    severity error;
  
  p_sync : process (clk, rst)
  begin
    if rst = G_RESET_POL then
      sync_regs <= (others => G_RESET_VAL);
    elsif rising_edge(clk) then
      sync_regs(0)                       <= i_bit;
      sync_regs(sync_regs'high downto 1) <= sync_regs(sync_regs'high - 1 downto 0);
    end if;
  end process;
  o_bit <= sync_regs(sync_regs'high);
end;
