-------------------------------------------------------------------------------
-- Title      : OV7670 Register package
-- Project    : OV7670
-------------------------------------------------------------------------------
-- File       : OV7670_regs_pkg.vhd
-- Author     : Philip
-- Created    : 21-04-2023
-------------------------------------------------------------------------------
-- Description: A wrapper for modules interfacing with the OV7670 module
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package OV7670_regs_pkg is
  -- The names of the registers of interest. Not all are listed here, only
  -- those that we explicity set.
  type t_OV7670_regs is (VREF, COM1, COM3, CLKRC, COM7, COM10, HSTART, HSTOP, VSTRT, VSTOP, HREF, COM12, COM13, COM14, COM15);

  type t_regs_addr_arr is array(t_OV7670_regs) of unsigned(7 downto 0);
  constant C_REGS_ADDR : t_regs_addr_arr :=
    (
      VREF   => x"03",
      COM1   => x"04",
      COM3   => x"0C",
      CLKRC  => x"11",
      COM7   => x"12",
      COM10  => x"15",
      HSTART => x"17",
      HSTOP  => x"18",
      VSTRT  => x"19",
      VSTOP  => x"1A",
      HREF   => x"32",
      COM12  => x"3C",
      COM13  => x"3D",
      COM14  => x"3E",
      COM15  => x"40"
      );

end package OV7670_regs_pkg;
