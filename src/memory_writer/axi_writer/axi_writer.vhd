-------------------------------------------------------------------------------
-- Title      : Axi Writer
-- Project    : OV7670
-------------------------------------------------------------------------------
-- File       : axi_writer.vhd
-- Author     : Philip  
-- Created    : 31-12-2022
-------------------------------------------------------------------------------
-- Description: An AXI4 master designed to read from a burst FIFO and write to a memory
-- through an AXI4 interface. Data will be written in memory in consecutive locations
-- from a fixed base address (i_base_pointer).
--
-- Currently, the reset input to this module must be the same as the AXI interface reset.
-- This module can NOT be independently reset, otherwise the AXI bus will hang from
-- an incomplete transaction.
--
-- Base pointer must be 4K aligned. With fixed sized bursts, this means we do
-- not need to check for 4KB boundaries crossings.
--
-- The flush input must be held high at the end to flush the FIFO. The last data
-- in the burst FIFO will then be read out (since in most cases the remaining
-- amount will not be nough to till a full burst to then trigger of a new transfer)..
--
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.OV7670_util_pkg.ceil_log2;

entity axi_writer is
  generic (
    G_AXI_DATA_WIDTH              : natural := 64;
    G_AXI_ADDR_WIDTH              : natural := 32;
    G_AXI_ID_WIDTH                : natural := 8;
    G_BURST_WRITE_FIFO_DEPTH_LOG2 : natural := 9;  --depth of the external burst fifo
    G_BURST_LENGTH                : natural := 64
    );
  port(
    clk : in std_logic;
    rst : in std_logic;                 --Must be same as axi rst

    i_base_pointer : in unsigned(G_AXI_ADDR_WIDTH - 1 downto 0);  --Must be 4K aligned
    i_flush        : in std_logic;

    -- Burst FIFO interface
    i_fifo_rd_data     : in  std_logic_vector(G_AXI_DATA_WIDTH - 1 downto 0);
    i_fifo_empty       : in  std_logic;  --for debug
    o_fifo_rd_en       : out std_logic;
    i_rd_burst_avail   : in  std_logic;
    i_rd_reserve_cnt   : in  unsigned(G_BURST_WRITE_FIFO_DEPTH_LOG2 downto 0);
    o_rd_burst_reserve : out std_logic;

    -- Axi interface
    m_axi_awaddr  : out std_logic_vector(G_AXI_ADDR_WIDTH - 1 downto 0);
    m_axi_awlen   : out std_logic_vector(7 downto 0);
    m_axi_awsize  : out std_logic_vector(2 downto 0);
    m_axi_awburst : out std_logic_vector(1 downto 0);
    m_axi_awvalid : out std_logic;
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

    -- error outputs
    o_axi_write_err : out std_logic
    );
end entity;

architecture rtl of axi_writer is
  --TODO need a log2 function. Ceil log 2 works because it is a power of 2 anyway...
  constant C_BYTES_PER_BEAT_LOG2 : natural                      := ceil_log2(G_AXI_DATA_WIDTH / 8);
  constant C_AXI_BURST_TYPE_INCR : std_logic_vector(1 downto 0) := "01";

  constant C_AXI_RESP_SLVERR : std_logic_vector(1 downto 0) := "10";
  constant C_AXI_RESP_DECERR : std_logic_vector(1 downto 0) := "11";

  signal start_aw_trans : std_logic := '0';
  signal start_w_trans  : std_logic := '0';

  signal rd_burst_reserve_out : std_logic                                            := '0';
  signal burst_len            : unsigned(ceil_log2(G_BURST_LENGTH + 1) - 1 downto 0) := (others => '0');
  signal next_axi_awaddr      : unsigned(G_AXI_ADDR_WIDTH - 1 downto 0)              := (others => '0');
  signal axi_awaddr           : std_logic_vector(G_AXI_ADDR_WIDTH - 1 downto 0)      := (others => '0');
  signal finished_flush       : std_logic                                            := '0';

  signal axi_awvalid : std_logic                                        := '0';
  signal axi_awlen   : unsigned(ceil_log2(G_BURST_LENGTH) - 1 downto 0) := (others => '0');

  type t_tx_state is (IDLE, SEND);
  signal tx_data_state : t_tx_state := IDLE;

  signal tx_cnt     : unsigned(burst_len'range)                      := (others => '0');
  signal axi_wvalid : std_logic                                      := '0';
  signal axi_wdata  : std_logic_vector(G_AXI_DATA_WIDTH -1 downto 0) := (others => '0');
  signal axi_wlast  : std_logic                                      := '0';

  signal axi_bready    : std_logic;
  signal axi_write_err : std_logic;

  signal fifo_rd_en : std_logic;
begin

  -- Fixed burst length must be a power of two, to ensure that we do not cross
  -- 4KB boundaries with the burst. Base address is 4KB aligned.
  assert (ceil_log2(G_BURST_LENGTH + 1) = ceil_log2(G_BURST_LENGTH) + 1)
    report "ERROR: G_BURST_LENGTH must be a power of 2" severity failure;

  p_calc_address : process(clk)
  begin
    if rising_edge(clk) then
      rd_burst_reserve_out <= '0';
      -- We have a full burst to send and we can start a new transaction
      if start_aw_trans = '0'and start_w_trans = '0' then
        if i_rd_burst_avail = '1' then
          start_aw_trans       <= '1';
          start_w_trans        <= '1';
          burst_len            <= to_unsigned(G_BURST_LENGTH, burst_len'length);
          rd_burst_reserve_out <= '1';

        elsif i_flush = '1' and finished_flush = '0' then
          -- We must not reserve a burst to the burst fifo in this case, otherwise rd reserve count
          -- will underflow.
          start_aw_trans <= '1';
          start_w_trans  <= '1';
          burst_len      <= resize(i_rd_reserve_cnt, burst_len'length);
          --i_flush will be stuck high, but we only want to flush once. SO use
          --this to know when we have finished the flush.
          finished_flush <= '1';
        end if;
      end if;

      -- We have sampled the address and burst length when in idle state or
      -- after the last beat
      if start_aw_trans = '1' and (axi_awvalid = '0' or (axi_awvalid = '1' and m_axi_awready = '1')) then
        start_aw_trans  <= '0';
        next_axi_awaddr <= next_axi_awaddr + (burst_len & (C_BYTES_PER_BEAT_LOG2 - 1 downto 0 => '0'));
      end if;

      if start_w_trans = '1' and (tx_data_state = IDLE or (axi_wvalid = '1' and m_axi_wready = '1' and axi_wlast = '1')) then
        start_w_trans <= '0';
      end if;

      if rst = '1' then
        --Sample address pointer on reset
        next_axi_awaddr <= i_base_pointer;
        assert (unsigned(i_base_pointer(11 downto 0)) = 0)
          report "Base addres must be 4KB aligned!" severity failure;
        start_aw_trans <= '0';
        start_w_trans  <= '0';
        finished_flush <= '0';
      end if;
    end if;
  end process;

  p_aw_trans : process(clk)
  begin
    if rising_edge(clk) then
      if start_aw_trans = '1' then
        axi_awvalid <= '1';
        axi_awlen   <= resize(burst_len - 1, axi_awlen'length);
        axi_awaddr  <= std_logic_vector(next_axi_awaddr);
      end if;

      if axi_awvalid = '1' and m_axi_awready = '1' then
        if start_aw_trans = '0' then
          axi_awvalid <= '0';
        end if;
      end if;
      if rst = '1' then
        axi_awvalid <= '0';
      end if;
    end if;
  end process;

  p_w_trans : process(clk)
  begin
    if rising_edge(clk) then

      case tx_data_state is
        when IDLE =>
          axi_wvalid <= '0';
          axi_wlast  <= '0';

          if start_w_trans = '1' then
            tx_data_state <= SEND;
            tx_cnt        <= burst_len;

            if burst_len = 1 then
              axi_wlast <= '1';
            end if;
            --We only start the transafer when the fifo has full burst, so we can hold valid high (rather than tie
            --the valid to not empty)
            axi_wvalid <= '1';
          end if;
        when SEND =>
          -- Transfer happens when ready and valid. Valid is always set and stuck high when in
          -- this state, so transaction happens when ready='1'
          if m_axi_wready = '1' then
            tx_cnt    <= tx_cnt - 1;
            axi_wlast <= '0';

            if tx_cnt = 2 then
              axi_wlast <= '1';
            end if;

            if axi_wlast = '1' then
              --Start next transaction
              if start_w_trans = '1' then
                tx_data_state <= SEND;
                tx_cnt        <= burst_len;
                if burst_len = 1 then
                  axi_wlast <= '1';
                end if;
                axi_wvalid <= '1';
              else  --No new transaction, go back to idle state
                tx_data_state <= IDLE;
                axi_wvalid    <= '0';
              end if;
            end if;
          end if;
      end case;

      if rst = '1' then
        tx_data_state <= IDLE;
        axi_wvalid    <= '0';
      end if;
    end if;
  end process;

  --Just throw an error if bresp comes back with an error - cant really do
  --anthing else
  p_bresp_check : process(clk)
  begin
    if rising_edge(clk) then
      --errors are single cycle.
      axi_write_err <= '0';
      if axi_bready = '1' and m_axi_bvalid = '1' then
        if m_axi_bresp = C_AXI_RESP_DECERR or m_axi_bresp = C_AXI_RESP_SLVERR then
          axi_write_err <= '1';
        end if;
      end if;

      if rst = '1' then
        axi_write_err <= '0';
      end if;
    end if;
  end process;
  axi_bready <= '1';

  -- For debug only. If the logic is corrrect this will never happen
  --synthesis translate_off
  p_underflow_check : process(clk)
  begin
    if rising_edge(clk) then
      if fifo_rd_en = '1' and i_fifo_empty = '1' then
        assert false report "AXI writer underflowed burst FIFO" severity error;
      end if;
    end if;
  end process;
  --synthesis translate_on


  -- Burst Fifo outputs
  fifo_rd_en         <= m_axi_wready and axi_wvalid;
  o_fifo_rd_en       <= fifo_rd_en;
  o_rd_burst_reserve <= rd_burst_reserve_out;

  -- AXI outputs
  -- Write address channel
  m_axi_awaddr  <= axi_awaddr;
  m_axi_awlen   <= std_logic_vector(resize(axi_awlen, m_axi_awlen'length));
  m_axi_awsize  <= std_logic_vector(to_unsigned(ceil_log2(G_AXI_DATA_WIDTH/8), m_axi_awsize'length));
  m_axi_awburst <= C_AXI_BURST_TYPE_INCR;
  m_axi_awvalid <= axi_awvalid;
  --Write data channel
  m_axi_wdata   <= i_fifo_rd_data;
  m_axi_wstrb   <= (others => '1');
  m_axi_wvalid  <= axi_wvalid;
  m_axi_wlast   <= axi_wlast;
  --
  m_axi_bready  <= axi_bready;
end;
