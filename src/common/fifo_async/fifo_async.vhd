-------------------------------------------------------------------------------
-- Title      : Asynchronous FIFO
-- Project    : 
-------------------------------------------------------------------------------
-- File       : fifo_async.vhd
-- Author     : Philip
-- Created    : 11-04-2023
-------------------------------------------------------------------------------
-- Description: Asynchronous FIFO, FWFT.
-- This FIFO follows the techniques detailed in Cliff Cummings paper, available
-- here : http://www.sunburst-design.com/papers/CummingsSNUG2002SJ_FIFO1.pdf
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity fifo_async is
  generic (
    G_DEPTH_LOG2 : natural := 3;
    G_DATA_WIDTH : natural := 16;
    G_RAM_STYLE  : string  := "distributed"  -- "block" "distributed", refer to UG901 
    );
  port(
    clk_wr    : in  std_logic;
    rst_wr    : in  std_logic;
    i_wr_en   : in  std_logic;
    i_wr_data : in  std_logic_vector(G_DATA_WIDTH - 1 downto 0);

    clk_rd    : in  std_logic;
    rst_rd    : in  std_logic;
    i_rd_en   : in  std_logic;
    o_rd_data : out std_logic_vector(G_DATA_WIDTH - 1 downto 0);

    o_full  : out std_logic;
    o_empty : out std_logic
    );
end entity;

architecture rtl of fifo_async is

  signal rd_data : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
  signal wr_en   : std_logic;
  --signal rd_en   : std_logic;
  signal wr_addr : unsigned(G_DEPTH_LOG2 - 1 downto 0);
  signal rd_addr : unsigned(G_DEPTH_LOG2 - 1 downto 0);

  -- The pointers have 1 extra bit so that we can store 2**N elements and
  -- distinguish between full and empty.
  signal wr_ptr : unsigned(G_DEPTH_LOG2 downto 0);
  signal rd_ptr : unsigned(G_DEPTH_LOG2 downto 0);

  signal wr_ptr_gray    : std_logic_vector(G_DEPTH_LOG2 downto 0);
  signal wr_ptr_gray_s  : std_logic_vector(G_DEPTH_LOG2 downto 0);
  signal wr_ptr_gray_rd : std_logic_vector(G_DEPTH_LOG2 downto 0);

  signal rd_ptr_gray    : std_logic_vector(G_DEPTH_LOG2 downto 0);
  signal rd_ptr_gray_s  : std_logic_vector(G_DEPTH_LOG2 downto 0);
  signal rd_ptr_gray_wr : std_logic_vector(G_DEPTH_LOG2 downto 0);

  attribute ASYNC_REG                   : string;
  attribute ASYNC_REG of rd_ptr_gray_s  : signal is "TRUE";
  attribute ASYNC_REG of rd_ptr_gray_wr : signal is "TRUE";

  signal full        : std_logic := '0';
  signal almost_full : std_logic := '0';
  signal empty       : std_logic := '1';  --internal empty signal
  signal fwft_empty  : std_logic := '1';  --empty at output interface
  signal fwft_rd_en  : std_logic := '0';


  function bin2gray(num : unsigned)
    return std_logic_vector is
    variable v_gray_num : std_logic_vector(num'range);
  begin
    v_gray_num := std_logic_vector(num xor shift_right(num, 1));
    return v_gray_num;
  end function;

  --Not currently needed. May need to use later for compaing binary points for
  --fill levels.
  function gray2bin(gray_num : std_logic_vector)
    return unsigned is
    variable v_bin_num : unsigned(gray_num'range);
  begin
    v_bin_num(v_bin_num'high) := gray_num(gray_num'high);
    for idx in gray_num'high-1 to 0 loop
      v_bin_num(idx) := v_bin_num(idx+1) xor gray_num(idx);
    end loop;
    return v_bin_num;
  end function;

begin

  -- Write clock domain

  wr_en <= i_wr_en and not full;

  process(clk_wr, rst_wr)
  begin
    if rst_wr = '1' then
      wr_ptr <= (others => '0');
    elsif rising_edge(clk_wr) then
      if wr_en = '1' then
        wr_ptr <= wr_ptr + 1;
      end if;
    end if;
  end process;

  -- Full logic generation

  -- sync read gray pointer into write clock domain
  process(clk_wr)
  begin
    if rising_edge(clk_wr) then
      rd_ptr_gray_s  <= rd_ptr_gray;
      rd_ptr_gray_wr <= rd_ptr_gray_s;
    end if;
  end process;

  process(clk_wr, rst_wr)
    variable v_gray_next : std_logic_vector(G_DEPTH_LOG2 downto 0);
  begin
    if rst_wr = '1' then
      full        <= '0';
      wr_ptr_gray <= (others => '0');
    elsif rising_edge(clk_wr) then
      if wr_en = '1' then
        v_gray_next := bin2gray(wr_ptr + 1);
      else
        v_gray_next := bin2gray(wr_ptr);
      end if;
      -- Full if write pointer catches up to ready pointer. Compare gray code
      -- pointers, full if upper two bits are different, rest of bits are the same
      if (v_gray_next(v_gray_next'high) /= rd_ptr_gray_wr(rd_ptr_gray_wr'high))
        and (v_gray_next(v_gray_next'high - 1) /= rd_ptr_gray_wr(rd_ptr_gray_wr'high - 1))
        and (v_gray_next(v_gray_next'high - 2 downto 0) = rd_ptr_gray_wr(rd_ptr_gray_wr'high - 2 downto 0)) then
        full <= '1';
      else
        full <= '0';
      end if;
      wr_ptr_gray <= v_gray_next;
    end if;
  end process;

  wr_addr <= wr_ptr(wr_ptr'high - 1 downto 0);

  -- read clock domain
  process(clk_rd, rst_rd)
  begin
    if rst_rd = '1' then
      rd_ptr <= (others => '0');
    elsif rising_edge(clk_rd) then
      if fwft_rd_en = '1' then
        rd_ptr <= rd_ptr + 1;
      end if;
    end if;
  end process;

  -- sync write gray pointer into read clock domain
  process(clk_rd)
  begin
    if rising_edge(clk_rd) then
      wr_ptr_gray_s  <= wr_ptr_gray;
      wr_ptr_gray_rd <= wr_ptr_gray_s;
    end if;
  end process;

  process(clk_rd, rst_rd)
    variable v_gray_next : std_logic_vector(G_DEPTH_LOG2 downto 0);
  begin
    if rst_rd = '1' then
      empty        <= '1';
      rd_ptr_gray <= (others => '0');
    elsif rising_edge(clk_rd) then
      if fwft_rd_en = '1' then
        v_gray_next := bin2gray(rd_ptr + 1);
      else
        v_gray_next := bin2gray(rd_ptr);
      end if;
      -- Full if write pointer catches up to ready pointer. Compare gray code
      -- pointers, full if upper two bits are different, rest of bits are the same
      if v_gray_next = wr_ptr_gray_rd then
        empty <= '1';
      else
        empty <= '0';
      end if;
      rd_ptr_gray <= v_gray_next;
    end if;
  end process;


  rd_addr <= rd_ptr(wr_ptr'high - 1 downto 0);

  ram_sdp_dual_clk_1 : entity work.ram_sdp_dual_clk
    generic map (
      G_DEPTH_LOG2 => G_DEPTH_LOG2,
      G_DATA_WIDTH => G_DATA_WIDTH,
      G_OUTPUT_REG => false,
      G_RAM_STYLE  => G_RAM_STYLE)
    port map (
      clk_wr    => clk_wr,
      i_wr_addr => wr_addr,
      i_wr_en   => wr_en,
      i_wr_data => i_wr_data,
      clk_rd    => clk_rd,
      i_rd_en   => fwft_rd_en,
      i_rd_addr => rd_addr,
      o_rd_data => rd_data);

  -- FWFT conversion
  p_FWFT : process(clk_rd, rst_rd)
  begin
    if rst_rd = '1' then
      fwft_empty <= '1';
    elsif rising_edge(clk_rd) then
      if fwft_rd_en = '1' then
        fwft_empty <= '0';
      elsif i_rd_en = '1' then
        fwft_empty <= '1';
      end if;
    end if;
  end process;

  fwft_rd_en <= not empty and (fwft_empty or i_rd_en);

  o_rd_data <= rd_data;
  o_full    <= full;
  o_empty   <= fwft_empty;

end;

