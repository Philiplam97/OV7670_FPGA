-------------------------------------------------------------------------------
-- Title      : Axi Writer
-- Project    : OV7670
-------------------------------------------------------------------------------
-- File       : memory_writer.vhd
-- Author     : Philip  
-- Created    : 7/01/23
-------------------------------------------------------------------------------
-- Description: A wrapper containing burst_read_fifo and axi_reader
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.OV7670_util_pkg.ceil_log2;

entity memory_reader is
  generic (
    G_AXI_DATA_WIDTH  : natural := 64;
    G_AXI_ADDR_WIDTH  : natural := 32;
    G_AXI_ID_WIDTH    : natural := 8;
    G_BURST_LENGTH    : natural := 64;
    G_FIFO_DEPTH_LOG2 : natural := 9;
    G_OUT_DATA_WIDTH  : natural := 16;
    G_RAM_STYLE       : string  := "block"  -- "block" "distributed", refer to UG901 
    );
  port(
    clk : in std_logic;
    rst : in std_logic;                 --Must be same as axi rst

    i_base_pointer : in unsigned(G_AXI_ADDR_WIDTH - 1 downto 0);  --Must be 4K aligned

    -- Axi interface
    m_axi_araddr  : out std_logic_vector(G_AXI_ADDR_WIDTH - 1 downto 0);
    m_axi_arlen   : out std_logic_vector(7 downto 0);
    m_axi_arsize  : out std_logic_vector(2 downto 0);
    m_axi_arburst : out std_logic_vector(1 downto 0);
    m_axi_arvalid : out std_logic;
    m_axi_arid    : out std_logic_vector(G_AXI_ID_WIDTH - 1 downto 0);
    m_axi_arready : in  std_logic;

    m_axi_rdata  : in  std_logic_vector(G_AXI_DATA_WIDTH - 1 downto 0);
    m_axi_rvalid : in  std_logic;
    m_axi_rlast  : in  std_logic;
    m_axi_rready : out std_logic;
    m_axi_rid    : in  std_logic_vector(G_AXI_ID_WIDTH - 1 downto 0);  --unused
    m_axi_rresp  : in  std_logic_vector(1 downto 0);

    i_rd_en   : in  std_logic;
    o_rd_data : out std_logic_vector(G_OUT_DATA_WIDTH - 1 downto 0);
    o_empty   : out std_logic;

    o_axi_read_err : out std_logic
    );
end entity;

architecture rtl of memory_reader is
  
  signal fifo_wr_data     : std_logic_vector(G_AXI_DATA_WIDTH - 1 downto 0);
  signal fifo_full        : std_logic;
  signal fifo_wr_en       : std_logic;
  signal wr_burst_avail   : std_logic;
  signal wr_burst_reserve : std_logic;

begin
  
  axi_reader_1 : entity work.axi_reader
    generic map (
      G_AXI_DATA_WIDTH             => G_AXI_DATA_WIDTH,
      G_AXI_ADDR_WIDTH             => G_AXI_ADDR_WIDTH,
      G_AXI_ID_WIDTH               => G_AXI_ID_WIDTH,
      G_BURST_READ_FIFO_DEPTH_LOG2 => G_FIFO_DEPTH_LOG2,
      G_BURST_LENGTH               => G_BURST_LENGTH)
    port map (
      clk                => clk,
      rst                => rst,
      i_base_pointer     => i_base_pointer,
      m_axi_araddr       => m_axi_araddr,
      m_axi_arlen        => m_axi_arlen,
      m_axi_arsize       => m_axi_arsize,
      m_axi_arburst      => m_axi_arburst,
      m_axi_arvalid      => m_axi_arvalid,
      m_axi_arid         => m_axi_arid,
      m_axi_arready      => m_axi_arready,
      m_axi_rdata        => m_axi_rdata,
      m_axi_rvalid       => m_axi_rvalid,
      m_axi_rlast        => m_axi_rlast,
      m_axi_rready       => m_axi_rready,
      m_axi_rid          => m_axi_rid,
      m_axi_rresp        => m_axi_rresp,
      o_fifo_wr_data     => fifo_wr_data,
      i_fifo_full        => fifo_full,
      o_fifo_wr_en       => fifo_wr_en,
      i_wr_burst_avail   => wr_burst_avail,
      o_wr_burst_reserve => wr_burst_reserve,
      o_axi_read_err     => o_axi_read_err);

  burst_read_fifo_1 : entity work.burst_read_fifo
    generic map (
      G_DEPTH_LOG2     => G_FIFO_DEPTH_LOG2,
      G_IN_DATA_WIDTH  => G_AXI_DATA_WIDTH,
      G_OUT_DATA_WIDTH => G_OUT_DATA_WIDTH,
      G_BURST_LENGTH   => G_BURST_LENGTH,
      G_RAM_STYLE      => G_RAM_STYLE)
    port map (
      clk                => clk,
      rst                => rst,
      i_wr_burst_reserve => wr_burst_reserve,
      o_wr_burst_avail   => wr_burst_avail,
      i_wr_en            => fifo_wr_en,
      i_wr_data          => fifo_wr_data,
      i_rd_en            => i_rd_en,
      o_rd_data          => o_rd_data,
      o_full             => fifo_full,
      o_empty            => o_empty);
end;
