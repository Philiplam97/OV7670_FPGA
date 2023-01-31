-------------------------------------------------------------------------------
-- Title      : axi_reader
-- Project    : 
-------------------------------------------------------------------------------
-- File       : axi_reader.vhd
-- Author     : Philip
-- Created    : 25-01-2023
-------------------------------------------------------------------------------
-- Description:  An axi master designed to read from a memory interface. Will
-- read fixed bursts from a base pointer
--
-------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.OV7670_util_pkg.ceil_log2;

entity axi_reader is
  generic(
    G_AXI_DATA_WIDTH             : natural := 64;
    G_AXI_ADDR_WIDTH             : natural := 32;
    G_AXI_ID_WIDTH               : natural := 8;
    G_BURST_READ_FIFO_DEPTH_LOG2 : natural := 9;  --depth of the external burst fifo
    G_BURST_LENGTH               : natural := 64
    );
  port (

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

    -- Burst FIFO interface
    o_fifo_wr_data     : out std_logic_vector(G_AXI_DATA_WIDTH - 1 downto 0);
    i_fifo_full        : in  std_logic;  --for debug
    o_fifo_wr_en       : out std_logic;
    i_wr_burst_avail   : in  std_logic;
    o_wr_burst_reserve : out std_logic;
    -- error outputs
    o_axi_read_err     : out std_logic
    );
end entity;

architecture rtl of axi_reader is
  constant C_BYTES_PER_BEAT_LOG2 : natural := ceil_log2(G_AXI_DATA_WIDTH / 8);

  constant C_AXI_RESP_SLVERR     : std_logic_vector(1 downto 0) := "10";
  constant C_AXI_RESP_DECERR     : std_logic_vector(1 downto 0) := "11";
  constant C_AXI_BURST_TYPE_INCR : std_logic_vector(1 downto 0) := "01";

  type t_rd_req_state is (IDLE, SEND);
  signal rd_req_state : t_rd_req_state                          := IDLE;
  signal axi_araddr   : unsigned(G_AXI_ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal axi_arvalid  : std_logic;

  signal wr_burst_reserve : std_logic := '0';
  signal axi_read_err     : std_logic := '0';

begin
  -- Fixed burst length must be a power of two, to ensure that we do not cross
  -- 4KB boundaries with the burst. Base address is 4KB aligned.
  assert (ceil_log2(G_BURST_LENGTH + 1) = ceil_log2(G_BURST_LENGTH) + 1)
    report "ERROR: G_BURST_LENGTH must be a power of 2" severity failure;

  assert (G_BURST_LENGTH <= 256)
    report "AXI only supports burst lengths of 256 or less!" severity failure;

  -- Just keep letting burst request go out until FIFO is fully reserved
  p_rd_req : process(clk)
  begin
    if rising_edge(clk) then
      wr_burst_reserve <= '0';

      case rd_req_state is
        when IDLE =>
          -- We have space for a new burst - start a new transaction
          if i_wr_burst_avail = '1' then
            axi_arvalid      <= '1';
            rd_req_state     <= SEND;
            wr_burst_reserve <= '1';
          end if;
        when SEND =>
          if m_axi_arready = '1' then  --arvalid will be high in this state. vld && rdy
            axi_araddr   <= axi_araddr + (G_BURST_LENGTH * 2**C_BYTES_PER_BEAT_LOG2);--byte address
            rd_req_state <= IDLE;
            axi_arvalid  <= '0';
          end if;
      end case;

      if rst = '1' then
        wr_burst_reserve <= '0';
        axi_arvalid      <= '0';
        axi_araddr       <= i_base_pointer;
        rd_req_state     <= IDLE;
        assert (unsigned(i_base_pointer(11 downto 0)) = 0)
          report "Base address must be 4KB aligned!" severity failure;
      end if;
    end if;
  end process;

  -- Raise an error if the resp channel comes back with an error.
  p_bresp_check : process(clk)
  begin
    if rising_edge(clk) then
      --errors are single cycle.
      axi_read_err <= '0';
      if m_axi_rvalid = '1' then
        if m_axi_rresp = C_AXI_RESP_DECERR or m_axi_rresp = C_AXI_RESP_SLVERR then
          axi_read_err <= '1';
        end if;
      end if;

      if rst = '1' then
        axi_read_err <= '0';
      end if;
    end if;
  end process;

  -- For debug only. If the logic is corrrect this will never happen
  --synthesis translate_off
  p_overflow_check : process(clk)
  begin
    if rising_edge(clk) then
      if m_axi_rvalid = '1' and i_fifo_full = '1' then
        assert false report "AXI reader overflowed burst FIFO" severity error;
      end if;
    end if;
  end process;
  --synthesis translate_on

  -- AXI outputs
  -- Since we only issue new requests when we have enough space to reserve in the
  -- burst fifo, we can keep ready high
  m_axi_rready  <= '1';
  m_axi_araddr  <= std_logic_vector(axi_araddr);
  m_axi_arlen   <= std_logic_vector(to_unsigned(G_BURST_LENGTH - 1, m_axi_arlen'length));  -- Always read fixed bursts
  m_axi_arsize  <= std_logic_vector(to_unsigned(ceil_log2(G_AXI_DATA_WIDTH/8), m_axi_arsize'length));
  m_axi_arid    <= (others => '0');     --unused
  m_axi_arvalid <= axi_arvalid;
  m_axi_arburst <= C_AXI_BURST_TYPE_INCR;

  -- Burst FIFO outputs
  o_fifo_wr_data     <= m_axi_rdata;
  o_fifo_wr_en       <= m_axi_rvalid;
  o_wr_burst_reserve <= wr_burst_reserve;

  o_axi_read_err <= axi_read_err;

end architecture;


