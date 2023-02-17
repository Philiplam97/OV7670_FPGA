-------------------------------------------------------------------------------
-- Title      : SCCB
-- Project    : OV7670
-------------------------------------------------------------------------------
-- File       : SCCB.vhd
-- Author     : Philip
-- Created    : 01-11-2022
-------------------------------------------------------------------------------
-- Description: SCCB - Serial Camrea Control Bus interface to set
-- the control registers in the ov7670 module. Only does transmit side.
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.OV7670_util_pkg.ceil_log2;

entity SCCB is
  generic (
    G_CLK_FREQ : natural := 100e6  -- Clock frequency of input clock, in Hz
    );
  port (
    clk : in std_logic;
    rst : in std_logic;

    i_data    : in  std_logic_vector(7 downto 0);
    i_subaddr : in  std_logic_vector(7 downto 0);
    i_id      : in  std_logic_vector(6 downto 0);
    i_vld     : in  std_logic;
    o_rdy     : out std_logic;

    o_SIO_C  : out   std_logic;
    io_SIO_D : inout std_logic
    );
end entity;

architecture rtl of SCCB is

  -- For writes, the eighth bit in the ID address transmission should be set to
  -- '0'.
  constant C_WRITE_BIT_SEL  : std_logic        := '0';
  -- Bits to send for start condition
  constant C_START_COND_TX  : std_logic_vector := "100";
  -- Bits to send for stop
  constant C_STOP_COND_TX   : std_logic_vector := "0011";
  -- Frequency of the transfer clock (F_SIOC_C in the datasheet)
  constant C_SIO_C_FREQ     : natural          := 400e3;  --400 kHz
  -- Number of bits for each phase
  constant C_PHASE_NUM_BITS : natural          := 9;  --8 data bits and one don't care

  -- 4 times for one period
  constant C_STRB_CNTR_THRESHOLD : natural := G_CLK_FREQ / C_SIO_C_FREQ / 2 / 2;

  type t_SCCB_state is (IDLE, START_0, START_1, SEND_0, SEND_1, SEND_2, SEND_3, STOP_0, STOP_1, STOP_2, STOP_3, STOP_4);  --TODO
  signal SCCB_state : t_SCCB_state := IDLE;

  -- 3 phase transmission - 3x9 bits of data,  see below
  signal tx_sreg : std_logic_vector(C_START_COND_TX'length + 3*C_PHASE_NUM_BITS + C_STOP_COND_TX'length - 1 downto 0) := (others => '0');

  signal tx_cnt : unsigned(ceil_log2(tx_sreg'length) - 1 downto 0) := (others => '0');

  signal ready_out : std_logic := '0';
  signal SIO_C     : std_logic := '0';
  signal SIO_D     : std_logic := '0';

  signal rst_d : std_logic := '0';
  signal strb  : std_logic := '0';

  signal strb_counter : unsigned(ceil_log2(C_STRB_CNTR_THRESHOLD) - 1 downto 0) := (others => '0');

  signal drive_z : std_logic := '0';
  signal tx_done : std_logic := '0';
begin

  -- Main state machine for transmit. Perform 3 phase transmission cycle -
  -- refer to 3.2.1.1 of OmniVision Serial Camera Control Bus (SCCB) Function
  -- Specification
  -- We have:
  -- | ID Address |X| Sub Address |X| Write data |X|
  -- |    Phase 1   |    Phase 2    |   Phase 3    |
  -- 9th bit of each of the phases are don't cares (X)

  process(clk)
  begin
    if rising_edge(clk) then
      tx_done <= '0';
      if i_vld = '1' and ready_out = '1' then
        -- Sample the data, put onto shift register
        tx_sreg   <= C_START_COND_TX & i_id & C_WRITE_BIT_SEL & '0' & i_subaddr & '0' & i_data & '0' & C_STOP_COND_TX;
        ready_out <= '0';
      end if;

      if tx_done = '1' then
        ready_out <= '1';
      end if;

      --assert ready coming out of reset, but ensure it is low during reset to
      --allow this module to get  reset independently (even when the
      --interfacing module is not reset)
      if rst_d = '1' and rst = '0' then
        ready_out <= '1';
      end if;

      rst_d <= rst;

      if strb = '1' then
        case SCCB_state is
          when IDLE =>
            SIO_C <= '1';
            -- Ready out is essentially not empty, i.e. we have daa waaiting to
            -- be sent.
            if ready_out = '0' then
              SIO_D      <= tx_sreg(tx_sreg'left);  -- '1'
              tx_sreg    <= tx_sreg(tx_sreg'left -1 downto 0) & '0';
              drive_z    <= '0';
              SCCB_state <= START_0;
            end if;
          when START_0 =>
            SIO_C      <= '1';
            SIO_D      <= tx_sreg(tx_sreg'left);    --'0'
            tx_sreg    <= tx_sreg(tx_sreg'left -1 downto 0) & '0';
            SCCB_state <= START_1;
            drive_z    <= '0';
          when START_1 =>
            SIO_C      <= '0';
            SIO_D      <= tx_sreg(tx_sreg'left);    --'0'
            tx_sreg    <= tx_sreg(tx_sreg'left -1 downto 0) & '0';
            SCCB_state <= SEND_0;
            drive_z    <= '0';
          when SEND_0 =>
            SIO_C      <= '0';
            SCCB_state <= SEND_1;
            SIO_D      <= tx_sreg(tx_sreg'left);    --data bit
            tx_sreg    <= tx_sreg(tx_sreg'left -1 downto 0) & '0';
            tx_cnt     <= tx_cnt + 1;
            if tx_cnt = to_unsigned(8, tx_cnt'length)
              or tx_cnt = to_unsigned(17, tx_cnt'length)
              or tx_cnt = to_unsigned(26, tx_cnt'length) then
              drive_z <= '1';
            else
              drive_z <= '0';
            end if;
          when SEND_1 =>
            SIO_C      <= '1';
            SCCB_state <= SEND_2;
            drive_z    <= '0';

          when SEND_2 =>
            SIO_C      <= '1';
            SCCB_state <= SEND_3;
            drive_z    <= '0';
          when SEND_3 =>
            SIO_C <= '0';
            if tx_cnt = to_unsigned(27, tx_cnt'length) then  --done sending data
              tx_cnt     <= (others => '0');
              SCCB_state <= STOP_0;
            else
              SCCB_state <= SEND_0;
            end if;
            drive_z <= '0';
          when STOP_0 =>
            SIO_C      <= '0';
            SIO_D      <= tx_sreg(tx_sreg'left);             --'0'
            tx_sreg    <= tx_sreg(tx_sreg'left -1 downto 0) & '0';
            SCCB_state <= STOP_1;
            drive_z    <= '0';
          when STOP_1 =>
            SIO_C      <= '1';
            SIO_D      <= tx_sreg(tx_sreg'left);             --'0'
            tx_sreg    <= tx_sreg(tx_sreg'left - 1 downto 0) & '0';
            SCCB_state <= STOP_2;
            drive_z    <= '0';
          when STOP_2 =>
            SIO_C      <= '1';
            SIO_D      <= tx_sreg(tx_sreg'left);             --'1'
            tx_sreg    <= tx_sreg(tx_sreg'left - 1 downto 0) & '0';
            SCCB_state <= STOP_3;
            drive_z    <= '0';
          when STOP_3 =>
            SIO_C      <= '1';
            SIO_D      <= tx_sreg(tx_sreg'left);             --'1'
            tx_sreg    <= tx_sreg(tx_sreg'left -1 downto 0) & '0';
            SCCB_state <= STOP_4;
            drive_z    <= '0';
          when STOP_4 =>
            SIO_C      <= '1';
            SIO_D      <= tx_sreg(tx_sreg'left);             --'0'
            tx_done    <= '1';
            drive_z    <= '1';
            SCCB_state <= IDLE;
        end case;
      end if;

      if rst = '1' then
        SIO_C      <= '0';
        SCCB_state <= IDLE;
        tx_cnt     <= (others => '0');
        drive_z    <= '1';
        ready_out  <= '0';

      end if;
    end if;

  end process;

  -- Generate the strobe used as a clock enable for the state/output changes
  -- The period of sio_c is 2.5 micro seconds (at 400 KHz). We need this to pulse
  -- 4 times per period.
  process(clk)
  begin
    if rising_edge(clk) then
      if strb_counter = to_unsigned(C_STRB_CNTR_THRESHOLD-1, strb_counter) then
        strb_counter <= (others => '0');
        strb         <= '1';
      else
        strb_counter <= strb_counter + 1;
        strb         <= '0';
      end if;
      if rst = '1' then
        strb_counter <= (others => '0');
        strb         <= '0';
      end if;
    end if;
  end process;

  io_SIO_D <= SIO_D when drive_z = '0' else 'Z';
  o_SIO_C  <= SIO_C;
  o_rdy    <= ready_out;
end architecture;

