-------------------------------------------------------------------------------
-- Title      : Util Package OV7670
-- Project    : OV7670
-------------------------------------------------------------------------------
-- File       : OV7670_util_pkg.vhd
-- Author     : Philip  
-- Created    : 30-12-2022
-------------------------------------------------------------------------------
-- Description: 
-------------------------------------------------------------------------------

package OV7670_util_pkg is

function ceil_log2 (num : natural)  return natural;

end package OV7670_util_pkg;

package body OV7670_util_pkg is
  
  function ceil_log2(num : natural) return natural is
  begin
    for i in 0 to 31 loop
      if num <= 2**i then
        return i;
      end if;
    end loop;
  end function;
  
end package body OV7670_util_pkg;
