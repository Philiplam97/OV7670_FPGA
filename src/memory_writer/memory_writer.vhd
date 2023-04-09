-------------------------------------------------------------------------------
-- Title      : Axi Writer
-- Project    : OV7670
-------------------------------------------------------------------------------
-- File       : memory_writer.vhd
-- Author     : Philip  
-- Created    : 7/01/23
-------------------------------------------------------------------------------
-- Description: A wrapper containing burst_write_fifo and axi_writer
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.OV7670_util_pkg.ceil_log2;

entity memory_writer is
  generic (
    G_AXI_DATA_WIDTH  : natural := 64;
    G_AXI_ADDR_WIDTH  : natural := 32;
    G_AXI_ID_WIDTH    : natural := 8;
    G_BURST_LENGTH    : natural := 64;
    G_FIFO_DEPTH_LOG2 : natural := 9;
    G_IN_DATA_WIDTH   : natural := 16;
    G_RAM_STYLE       : string  := "block"  -- "block" "distributed", refer to UG901 
    );
  port(
    clk : in std_logic;
    rst : in std_logic;                 --Must be same as axi rst

    i_base_pointer : in unsigned(G_AXI_ADDR_WIDTH - 1 downto 0);  --Must be 4K aligned
    i_flush        : in std_logic;

    i_wr_en       : in  std_logic;
    i_wr_data     : in  std_logic_vector(G_IN_DATA_WIDTH - 1 downto 0);
    o_fifo_full   : out std_logic;
    -- Axi interface
    m_axi_awaddr  : out std_logic_vector(G_AXI_ADDR_WIDTH - 1 downto 0);
    m_axi_awlen   : out std_logic_vector(7 downto 0);
    m_axi_awsize  : out std_logic_vector(2 downto 0);
    m_axi_awburst : out std_logic_vector(1 downto 0);
    m_axi_awvalid : out std_logic;
    m_axi_awid    : out std_logic_vector(G_AXI_ID_WIDTH - 1 downto 0) := (others => '0');
    m_axi_awready : in  std_logic;

    m_axi_wdata  : out std_logic_vector(G_AXI_DATA_WIDTH - 1 downto 0);
    m_axi_wstrb  : out std_logic_vector((G_AXI_DATA_WIDTH/8) - 1 downto 0);
    m_axi_wvalid : out std_logic;
    m_axi_wlast  : out std_logic;
    m_axi_wready : in  std_logic;

    m_axi_bid    : in  std_logic_vector(G_AXI_ID_WIDTH - 1 downto 0);
    m_axi_bresp  : in  std_logic_vector(1 downto 0);
    m_axi_bvalid : in  std_logic;
    m_axi_bready : out std_logic;

    o_err        : out std_logic
    );
end entity;

architecture rtl of memory_writer is
  -- Burst FIFO interface
  signal fifo_rd_data     : std_logic_vector(G_AXI_DATA_WIDTH - 1 downto 0);
  signal fifo_empty       : std_logic;
  signal fifo_rd_en       : std_logic;
  signal rd_burst_avail   : std_logic;
  signal rd_reserve_cnt   : unsigned(G_FIFO_DEPTH_LOG2 downto 0);
  signal rd_burst_reserve : std_logic;
  signal fifo_full        : std_logic;
  signal fifo_almost_full : std_logic;
  signal finished_flush   : std_logic;
  signal fifo_wr_en       : std_logic;
  signal fifo_wr_data     : std_logic_vector(G_IN_DATA_WIDTH - 1 downto 0);
  signal flush_cnt        : unsigned(ceil_log2(G_AXI_DATA_WIDTH/G_IN_DATA_WIDTH) - 1 downto 0);
  signal axi_writer_flush : std_logic_vector(G_AXI_DATA_WIDTH/G_IN_DATA_WIDTH + 2 downto 0);
begin

  -- The width conversion from the input data width to the axi bus width
  -- is done inside the burst write fifo. However if a full word is not filled,
  -- it will not be written in the fifo. So if we get a flush input, we need to
  -- write some extra data into the fifo. This needs to be
  -- G_AXI_DATA_WIDTH/G_IN_DATA_WIDTH - 1 elements to ensure the last word gets written in
  process(clk)
  begin
    if rising_edge(clk) then
      fifo_wr_data <= i_wr_data;
      if i_wr_en = '1' then
        fifo_wr_en <= '1';
      elsif i_flush = '1' then
        if flush_cnt = G_AXI_DATA_WIDTH / G_IN_DATA_WIDTH - 1 then
          -- finished flush
          fifo_wr_en <= '0';
        else
          fifo_wr_en <= '1';
          flush_cnt  <= flush_cnt + 1;
        end if;
      else
        fifo_wr_en <= '0';
      end if;
      if rst = '1' then
        flush_cnt  <= (others => '0');
        fifo_wr_en <= '0';
      end if;
    end if;
  end process;

  -- We need to delay the flush signal that goes into the axi writer module so
  -- that the last word gets written in to the FIFO before the axi writer sees
  -- the flush signal.
  p_delay_flush : process(clk)
  begin
    if rising_edge(clk) then
      axi_writer_flush <= axi_writer_flush(axi_writer_flush'high - 1 downto 0) & i_flush;
      if rst = '1' then
        axi_writer_flush <= (others => '0');
      end if;
    end if;
  end process;


  burst_write_fifo_1 : entity work.burst_write_fifo
    generic map (
      G_DEPTH_LOG2     => G_FIFO_DEPTH_LOG2,
      G_IN_DATA_WIDTH  => G_IN_DATA_WIDTH,
      G_OUT_DATA_WIDTH => G_AXI_DATA_WIDTH,
      G_BURST_LENGTH   => G_BURST_LENGTH,
      G_RAM_STYLE      => G_RAM_STYLE)
    port map (
      clk                => clk,
      rst                => rst,
      i_wr_en            => fifo_wr_en,
      i_wr_data          => fifo_wr_data,
      i_rd_burst_reserve => rd_burst_reserve,
      o_rd_burst_avail   => rd_burst_avail,
      o_reserve_cnt      => rd_reserve_cnt,
      i_rd_en            => fifo_rd_en,
      o_rd_data          => fifo_rd_data,
      o_full             => fifo_full,
      o_almost_full      => fifo_almost_full,
      o_empty            => fifo_empty);

  -- Overflow error - single cycle
  p_overflow_err : process(clk)
  begin
    if rising_edge(clk) then
      if fifo_full = '1' and fifo_wr_en = '1' then
        o_err <= '1';
      else
        o_err <= '0';
      end if;
    end if;
  end process;

  -- Since we need to register the write enable above due to the need for
  -- flushing, the worst case in back to back writes is that we can no longer
  -- accept data when the fifo is almost full, rather than full.
  o_fifo_full <= fifo_almost_full;

  axi_writer_1 : entity work.axi_writer
    generic map (
      G_AXI_DATA_WIDTH              => G_AXI_DATA_WIDTH,
      G_AXI_ADDR_WIDTH              => G_AXI_ADDR_WIDTH,
      G_BURST_WRITE_FIFO_DEPTH_LOG2 => G_FIFO_DEPTH_LOG2,
      G_BURST_LENGTH                => G_BURST_LENGTH)
    port map (
      clk                => clk,
      rst                => rst,
      i_base_pointer     => i_base_pointer,
      i_flush            => axi_writer_flush(axi_writer_flush'high),
      i_fifo_rd_data     => fifo_rd_data,
      i_fifo_empty       => fifo_empty,
      o_fifo_rd_en       => fifo_rd_en,
      i_rd_burst_avail   => rd_burst_avail,
      i_rd_reserve_cnt   => rd_reserve_cnt,
      o_rd_burst_reserve => rd_burst_reserve,
      m_axi_awaddr       => m_axi_awaddr,
      m_axi_awlen        => m_axi_awlen,
      m_axi_awsize       => m_axi_awsize,
      m_axi_awburst      => m_axi_awburst,
      m_axi_awvalid      => m_axi_awvalid,
      m_axi_awready      => m_axi_awready,
      m_axi_wdata        => m_axi_wdata,
      m_axi_wstrb        => m_axi_wstrb,
      m_axi_wvalid       => m_axi_wvalid,
      m_axi_wlast        => m_axi_wlast,
      m_axi_wready       => m_axi_wready,
      m_axi_bid          => m_axi_bid,
      m_axi_bresp        => m_axi_bresp,
      m_axi_bvalid       => m_axi_bvalid,
      m_axi_bready       => m_axi_bready);

end;
