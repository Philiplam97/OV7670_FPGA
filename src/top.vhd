-------------------------------------------------------------------------------
-- Title      : Top
-- Project    : OV7670
-------------------------------------------------------------------------------
-- File       : top.vhd
-- Author     : Philip  
-- Created    : 05-02-2023
-------------------------------------------------------------------------------
-- Description: Top level file for OV7670 project. Reads in data from OV7670
-- module and outputs onto VGA
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.OV7670_util_pkg.ceil_log2;

library unisim;
use unisim.vcomponents.BUFG;
use unisim.vcomponents.MMCME2_BASE;

entity top is
  generic (
    G_SIM   : boolean := false;
    G_DEBUG : boolean := true
    );
  port (
    clk_100 : in std_logic;

    --OV7670 pixel interface
    pclk        : in    std_logic;
    pxl_data    : in    std_logic_vector(7 downto 0);
    vsync       : in    std_logic;
    href        : in    std_logic;
    -- OV7670 SCCB configuration interface
    SIO_C       : out   std_logic;
    SIO_D       : inout std_logic;
    OV7670_xclk : out   std_logic;      --24MHz
    -- Ov7670 reset and power down input pins
    OV7670_rst_n : out std_logic;
    OV7670_pwdn  : out std_logic;

    -- VGA
    vga_hsync : out std_logic;
    vga_vsync : out std_logic;
    vga_red   : out std_logic_vector(3 downto 0);
    vga_green : out std_logic_vector(3 downto 0);
    vga_blue  : out std_logic_vector(3 downto 0);

    -- DDR 
    ddr3_dq      : inout std_logic_vector(15 downto 0);
    ddr3_dqs_n   : inout std_logic_vector(1 downto 0);
    ddr3_dqs_p   : inout std_logic_vector(1 downto 0);
    ddr3_addr    : out   std_logic_vector(13 downto 0);
    ddr3_ba      : out   std_logic_vector(2 downto 0);
    ddr3_ras_n   : out   std_logic;
    ddr3_cas_n   : out   std_logic;
    ddr3_we_n    : out   std_logic;
    ddr3_reset_n : out   std_logic;
    ddr3_ck_p    : out   std_logic_vector(0 to 0);
    ddr3_ck_n    : out   std_logic_vector(0 to 0);
    ddr3_cke     : out   std_logic_vector(0 to 0);
    ddr3_cs_n    : out   std_logic_vector(0 to 0);
    ddr3_dm      : out   std_logic_vector(1 downto 0);
    ddr3_odt     : out   std_logic_vector(0 to 0);

    -- Button input control
    btn : in std_logic_vector(3 downto 0)
    );

end entity top;

architecture rtl of top is

  -- Clocking and resets
  signal clk_mig_sys_unbuffered : std_logic;
  signal clk_mig_sys            : std_logic;
  signal clk_feedback_0         : std_logic;
  signal mmcm_locked_0          : std_logic;

  signal clk_200_unbuffered : std_logic;
  signal clk_24_unbuffered  : std_logic;
  signal clk_200            : std_logic;
  signal clk_24             : std_logic;
  signal clk_feedback_1     : std_logic;
  signal mmcm_locked_1      : std_logic;

  signal clk_ui : std_logic;
  signal rst_ui : std_logic;

  signal rst_100     : std_logic;
  signal rst_btn_100 : std_logic;
  signal btn_100Mhz  : std_logic_vector(3 downto 0);


  signal mmcm_all_locked    : std_logic;
  signal system_reset_async : std_logic;

  signal prst : std_logic;

--mig 
  signal mig_ui_clk_sync_rst : std_logic;
  signal mig_mmcm_locked     : std_logic;
  signal mig_aresetn         : std_logic;

  constant C_AXI_DATA_WIDTH : natural := 64;
  constant C_AXI_ADDR_WIDTH : natural := 28;
  constant C_AXI_ID_WIDTH   : natural := 1;
  constant C_BURST_LENGTH   : natural := 64;
  constant C_DATA_WIDTH     : natural := 16;
  constant C_FRAME_WIDTH    : natural := 640;
  constant C_FRAME_HEIGHT   : natural := 480;
  constant C_BASE_PTR       : natural := 0;
  constant C_FRAME_OFFSET   : natural := C_FRAME_HEIGHT*C_FRAME_WIDTH*C_DATA_WIDTH/8;

  signal cap_sof_ui      : std_logic;
  signal frame_wr_idx    : std_logic;
  signal next_mem_wr_ptr : unsigned(C_AXI_ADDR_WIDTH - 1 downto 0);
  signal mem_rd_ptr      : unsigned(C_AXI_ADDR_WIDTH - 1 downto 0);

  signal cap_pxl_data              : std_logic_vector(C_DATA_WIDTH - 1 downto 0);
  signal mem_wr_data               : std_logic_vector(C_DATA_WIDTH - 1 downto 0);
  signal mem_wr_en                 : std_logic;
  signal pxl_data_async_fifo_full  : std_logic;
  signal pxl_data_async_fifo_empty : std_logic;
  signal mem_wr_flush              : std_logic;
  signal mem_wr_err                : std_logic;
  signal cap_eos_ui                : std_logic;

  signal mem_writer_rst : std_logic;

  --Axi writer
  signal m_axi_awaddr  : std_logic_vector(C_AXI_ADDR_WIDTH - 1 downto 0);
  signal m_axi_awlen   : std_logic_vector(7 downto 0);
  signal m_axi_awsize  : std_logic_vector(2 downto 0);
  signal m_axi_awburst : std_logic_vector(1 downto 0);
  signal m_axi_awvalid : std_logic;
  signal m_axi_awid    : std_logic_vector(C_AXI_ID_WIDTH - 1 downto 0) := (others => '0');
  signal m_axi_awready : std_logic;

  signal m_axi_wdata  : std_logic_vector(C_AXI_DATA_WIDTH - 1 downto 0);
  signal m_axi_wstrb  : std_logic_vector((C_AXI_DATA_WIDTH/8) - 1 downto 0);
  signal m_axi_wvalid : std_logic;
  signal m_axi_wlast  : std_logic;
  signal m_axi_wready : std_logic;

  signal m_axi_bid    : std_logic_vector(C_AXI_ID_WIDTH - 1 downto 0);
  signal m_axi_bresp  : std_logic_vector(1 downto 0);
  signal m_axi_bvalid : std_logic;
  signal m_axi_bready : std_logic;

  -- Axi reader
  signal m_axi_araddr  : std_logic_vector(C_AXI_ADDR_WIDTH - 1 downto 0);
  signal m_axi_arlen   : std_logic_vector(7 downto 0);
  signal m_axi_arsize  : std_logic_vector(2 downto 0);
  signal m_axi_arburst : std_logic_vector(1 downto 0);
  signal m_axi_arvalid : std_logic;
  signal m_axi_arid    : std_logic_vector(C_AXI_ID_WIDTH - 1 downto 0);
  signal m_axi_arready : std_logic;

  signal m_axi_rdata  : std_logic_vector(C_AXI_DATA_WIDTH - 1 downto 0);
  signal m_axi_rvalid : std_logic;
  signal m_axi_rlast  : std_logic;
  signal m_axi_rready : std_logic;
  signal m_axi_rid    : std_logic_vector(C_AXI_ID_WIDTH - 1 downto 0);
  signal m_axi_rresp  : std_logic_vector(1 downto 0);

  signal mem_reader_rst    : std_logic;
  signal first_frame_valid : std_logic;
  signal cap_sof_ui_sreg   : std_logic_vector(1 downto 0);
  signal mem_rd_en         : std_logic;
  signal mem_rd_data       : std_logic_vector(C_DATA_WIDTH - 1 downto 0);
  signal mem_rd_empty      : std_logic;
  signal axi_rd_err        : std_logic;

  -- OV7670 
  constant C_BIT_DEPTH_R       : natural := 5;
  constant C_BIT_DEPTH_G       : natural := 6;
  constant C_BIT_DEPTH_B       : natural := 5;
  constant C_SCCB_CLK_FREQ     : natural := 100e6;
  constant C_1MS_CNT_THRESHOLD : natural := C_SCCB_CLK_FREQ/1e3 - 1;

  signal clk_cnt_1ms    : unsigned(ceil_log2(C_1MS_CNT_THRESHOLD + 1) - 1 downto 0);
  signal start_config   : std_logic;
  signal done_config    : std_logic;
  signal btn_100Mhz_1_d : std_logic;

  signal s_SIO_C : std_logic;
  signal s_SIO_D : std_logic;

--capture signals
  signal cap_pxl_r   : std_logic_vector(C_BIT_DEPTH_R - 1 downto 0);
  signal cap_pxl_g   : std_logic_vector(C_BIT_DEPTH_G - 1 downto 0);
  signal cap_pxl_b   : std_logic_vector(C_BIT_DEPTH_B - 1 downto 0);
  signal cap_pxl_vld : std_logic;
  signal cap_sof     : std_logic;
  signal cap_eos     : std_logic;

  -- VGA
  -- timings for 640x480
  constant C_VGA_H_FP        : natural := 16;  --Horizontal front porch in number of pixels/clk ticks 
  constant C_VGA_H_BP        : natural := 48;  --Horizontal back porch
  constant C_VGA_H_PULSE     : natural := 96;  -- Horizontal pulse width
  constant C_VGA_V_FP        : natural := 10;  -- Vertical front porch in number of lines 
  constant C_VGA_V_BP        : natural := 33;  --Vertical back porch
  constant C_VGA_V_PULSE     : natural := 2;   -- Vertical pulse width
  constant C_VGA_PIXEL_WIDTH : natural := 4;

  signal vga_sof    : std_logic;
  signal vga_sav    : std_logic;
  signal vga_eav    : std_logic;
  signal vga_vblank : std_logic;

  -- The vga module is clocked with the mig ui clk, so that there is no CDC
  -- from the memory reader to the output VGA interface. VGA output needs to be
  -- roughly 25.125MHz, so we need to generate an enable pulse at around this frequency
  -- NOTE: if the ui clk is changed, this will also need to be updated
  -- ui clk is currently 303.03/2 (2:1 ratio) so the division is 6 -> 151.515/6
  -- ~= 25.2525
  constant C_VGA_CLK_DIV : natural := 6;
  signal vga_clk_en_cnt  : unsigned(ceil_log2(C_VGA_CLK_DIV+1) - 1 downto 0);
  signal vga_clk_en      : std_logic;
  signal active_video    : std_logic;

begin

  -----------------------------------------------------------------------------
  --
  -- Clocking and Resets
  --
  -----------------------------------------------------------------------------

  -- Generate 202.02MHz sys clock for MIG
  MMCME2_BASE_0 : MMCME2_BASE
    generic map (
      BANDWIDTH          => "OPTIMIZED",  -- Jitter programming (OPTIMIZED, HIGH, LOW)                       
      CLKFBOUT_MULT_F    => 25.00,  -- Multiply value for all CLKOUT (2.000-64.000).                        
      CLKFBOUT_PHASE     => 0.0,  -- Phase offset in degrees of CLKFB (-360.000-360.000).                    
      CLKIN1_PERIOD      => 10.0,  -- Input clock period in ns to ps resolution (i.e. 33.333 is 30 MHz).     
-- CLKOUT0_DIVIDE - CLKOUT6_DIVIDE: Divide amount for each CLKOUT (1-128)                                    
      CLKOUT1_DIVIDE     => 1,
      CLKOUT2_DIVIDE     => 1,
      CLKOUT3_DIVIDE     => 1,
      CLKOUT4_DIVIDE     => 1,
      CLKOUT5_DIVIDE     => 1,
      CLKOUT6_DIVIDE     => 1,
      CLKOUT0_DIVIDE_F   => 4.125,  -- Divide amount for CLKOUT0 (1.000-128.000).                           
-- CLKOUT0_DUTY_CYCLE - CLKOUT6_DUTY_CYCLE: Duty cycle for each CLKOUT (0.01-0.99).                          
      CLKOUT0_DUTY_CYCLE => 0.5,
      CLKOUT1_DUTY_CYCLE => 0.5,
      CLKOUT2_DUTY_CYCLE => 0.5,
      CLKOUT3_DUTY_CYCLE => 0.5,
      CLKOUT4_DUTY_CYCLE => 0.5,
      CLKOUT5_DUTY_CYCLE => 0.5,
      CLKOUT6_DUTY_CYCLE => 0.5,
-- CLKOUT0_PHASE - CLKOUT6_PHASE: Phase offset for each CLKOUT (-360.000-360.000).                           
      CLKOUT0_PHASE      => 0.0,
      CLKOUT1_PHASE      => 0.0,
      CLKOUT2_PHASE      => 0.0,
      CLKOUT3_PHASE      => 0.0,
      CLKOUT4_PHASE      => 0.0,
      CLKOUT5_PHASE      => 0.0,
      CLKOUT6_PHASE      => 0.0,
      CLKOUT4_CASCADE    => false,  -- Cascade CLKOUT4 counter with CLKOUT6 (FALSE, TRUE)                    
      DIVCLK_DIVIDE      => 3,  -- Master division value (1-106)                                     
      REF_JITTER1        => 0.0,  -- Reference input jitter in UI (0.000-0.999).                             
      STARTUP_WAIT       => false  -- Delays DONE until MMCM is locked (FALSE, TRUE)                         
      )
    port map (
-- Clock Outputs: 1-bit (each) output: User configurable clock outputs                                       
      CLKOUT0   => clk_mig_sys_unbuffered,  -- 1-bit output: CLKOUT0                                             
      CLKOUT0B  => open,  -- 1-bit output: Inverted CLKOUT0                                    
      CLKOUT1   => open,  -- 1-bit output: CLKOUT1                                             
      CLKOUT1B  => open,  -- 1-bit output: Inverted CLKOUT1                                    
      CLKOUT2   => open,  -- 1-bit output: CLKOUT2                                             
      CLKOUT2B  => open,  -- 1-bit output: Inverted CLKOUT2                                    
      CLKOUT3   => open,  -- 1-bit output: CLKOUT3                                             
      CLKOUT3B  => open,  -- 1-bit output: Inverted CLKOUT3                                    
      CLKOUT4   => open,  -- 1-bit output: CLKOUT4                                             
      CLKOUT5   => open,  -- 1-bit output: CLKOUT5                                             
      CLKOUT6   => open,  -- 1-bit output: CLKOUT6                                             
-- Feedback Clocks: 1-bit (each) output: Clock feedback ports                                                
      CLKFBOUT  => clk_feedback_0,  -- 1-bit output: Feedback clock                                      
      CLKFBOUTB => open,  -- 1-bit output: Inverted CLKFBOUT                                   
-- Status Ports: 1-bit (each) output: MMCM status ports                                                      
      LOCKED    => mmcm_locked_0,  -- 1-bit output: LOCK                                                
-- Clock Inputs: 1-bit (each) input: Clock input                                                             
      CLKIN1    => clk_100,  -- 1-bit input: Clock                                                
-- Control Ports: 1-bit (each) input: MMCM control ports                                                     
      PWRDWN    => '0',  -- 1-bit input: Power-down                                           
      RST       => '0',  -- 1-bit input: Reset                                                
-- Feedback Clocks: 1-bit (each) input: Clock feedback ports                                                 
      CLKFBIN   => clk_feedback_0  -- 1-bit input: Feedback clock                                       
      );

  bufg_0 : BUFG
    port map (
      i => clk_mig_sys_unbuffered,
      o => clk_mig_sys
      );

  -- Generate 200 MHz reference clock for MIG and 24 MHz for OV7670
  MMCME2_BASE_1 : MMCME2_BASE
    generic map (
      BANDWIDTH          => "OPTIMIZED",  -- Jitter programming (OPTIMIZED, HIGH, LOW)                       
      CLKFBOUT_MULT_F    => 6.00,  -- Multiply value for all CLKOUT (2.000-64.000).                        
      CLKFBOUT_PHASE     => 0.0,  -- Phase offset in degrees of CLKFB (-360.000-360.000).                    
      CLKIN1_PERIOD      => 10.0,  -- Input clock period in ns to ps resolution (i.e. 33.333 is 30 MHz).     
-- CLKOUT0_DIVIDE - CLKOUT6_DIVIDE: Divide amount for each CLKOUT (1-128)                                    
      CLKOUT1_DIVIDE     => 25,
      CLKOUT2_DIVIDE     => 1,
      CLKOUT3_DIVIDE     => 1,
      CLKOUT4_DIVIDE     => 1,
      CLKOUT5_DIVIDE     => 1,
      CLKOUT6_DIVIDE     => 1,
      CLKOUT0_DIVIDE_F   => 3.00,  -- Divide amount for CLKOUT0 (1.000-128.000).                           
-- CLKOUT0_DUTY_CYCLE - CLKOUT6_DUTY_CYCLE: Duty cycle for each CLKOUT (0.01-0.99).                          
      CLKOUT0_DUTY_CYCLE => 0.5,
      CLKOUT1_DUTY_CYCLE => 0.5,
      CLKOUT2_DUTY_CYCLE => 0.5,
      CLKOUT3_DUTY_CYCLE => 0.5,
      CLKOUT4_DUTY_CYCLE => 0.5,
      CLKOUT5_DUTY_CYCLE => 0.5,
      CLKOUT6_DUTY_CYCLE => 0.5,
-- CLKOUT0_PHASE - CLKOUT6_PHASE: Phase offset for each CLKOUT (-360.000-360.000).                           
      CLKOUT0_PHASE      => 0.0,
      CLKOUT1_PHASE      => 0.0,
      CLKOUT2_PHASE      => 0.0,
      CLKOUT3_PHASE      => 0.0,
      CLKOUT4_PHASE      => 0.0,
      CLKOUT5_PHASE      => 0.0,
      CLKOUT6_PHASE      => 0.0,
      CLKOUT4_CASCADE    => false,  -- Cascade CLKOUT4 counter with CLKOUT6 (FALSE, TRUE)                    
      DIVCLK_DIVIDE      => 1,  -- Master division value (1-106)                                     
      REF_JITTER1        => 0.0,  -- Reference input jitter in UI (0.000-0.999).                             
      STARTUP_WAIT       => false  -- Delays DONE until MMCM is locked (FALSE, TRUE)                         
      )
    port map (
-- Clock Outputs: 1-bit (each) output: User configurable clock outputs                                       
      CLKOUT0   => clk_200_unbuffered,  -- 1-bit output: CLKOUT0                                             
      CLKOUT0B  => open,  -- 1-bit output: Inverted CLKOUT0                                    
      CLKOUT1   => clk_24_unbuffered,  -- 1-bit output: CLKOUT1                                             
      CLKOUT1B  => open,  -- 1-bit output: Inverted CLKOUT1                                    
      CLKOUT2   => open,  -- 1-bit output: CLKOUT2                                             
      CLKOUT2B  => open,  -- 1-bit output: Inverted CLKOUT2                                    
      CLKOUT3   => open,  -- 1-bit output: CLKOUT3                                             
      CLKOUT3B  => open,  -- 1-bit output: Inverted CLKOUT3                                    
      CLKOUT4   => open,  -- 1-bit output: CLKOUT4                                             
      CLKOUT5   => open,  -- 1-bit output: CLKOUT5                                             
      CLKOUT6   => open,  -- 1-bit output: CLKOUT6                                             
-- Feedback Clocks: 1-bit (each) output: Clock feedback ports                                                
      CLKFBOUT  => clk_feedback_1,  -- 1-bit output: Feedback clock                                      
      CLKFBOUTB => open,  -- 1-bit output: Inverted CLKFBOUT                                   
-- Status Ports: 1-bit (each) output: MMCM status ports                                                      
      LOCKED    => mmcm_locked_1,  -- 1-bit output: LOCK                                                
-- Clock Inputs: 1-bit (each) input: Clock input                                                             
      CLKIN1    => clk_100,  -- 1-bit input: Clock                                                
-- Control Ports: 1-bit (each) input: MMCM control ports                                                     
      PWRDWN    => '0',  -- 1-bit input: Power-down                                           
      RST       => '0',  -- 1-bit input: Reset                                                 
-- Feedback Clocks: 1-bit (each) input: Clock feedback ports                                                 
      CLKFBIN   => clk_feedback_1  -- 1-bit input: Feedback clock                                       
      );

  bufg_1 : BUFG
    port map (
      i => clk_200_unbuffered,
      o => clk_200
      );

  bufg_2 : BUFG
    port map (
      i => clk_24_unbuffered,
      o => clk_24
      );

  -- Resets
  gen_btn_debounce : if not G_SIM generate
    gen_four_btn_debounce : for i in 0 to 3 generate
      debouncer_1 : entity work.button_debouncer
        generic map (
          G_N_CLKS_MAX => 5e6)          --50ms with 100MHz clk
        port map (
          clk    => clk_100,
          i_din  => btn(i),
          o_dout => btn_100Mhz(i));
    end generate;
  else generate                         --Don't debounce in simulation
    btn_100Mhz <= btn;
  end generate;

  rst_btn_100 <= btn_100Mhz(0);
  
  mmcm_all_locked    <= mmcm_locked_0 and mmcm_locked_1 and mig_mmcm_locked;
  system_reset_async <= not mmcm_all_locked or rst_btn_100;

  sync_ff_rst_100 : entity work.sync_ff
    generic map (
      G_REGISTER_STAGES => 4,
      G_RESET_POL       => '1',
      G_RESET_VAL       => '1')
    port map (
      clk   => clk_100,
      rst   => system_reset_async,
      i_bit => '0',
      o_bit => rst_100);

  sync_ff_rst_ui : entity work.sync_ff
    generic map (
      G_REGISTER_STAGES => 4,
      G_RESET_POL       => '1',
      G_RESET_VAL       => '1')
    port map (
      clk   => clk_ui,
      rst   => system_reset_async,
      i_bit => '0',
      o_bit => rst_ui);

  sync_ff_prst : entity work.sync_ff
    generic map (
      G_REGISTER_STAGES => 4,
      G_RESET_POL       => '1',
      G_RESET_VAL       => '1')
    port map (
      clk   => pclk,
      rst   => system_reset_async,
      i_bit => '0',
      o_bit => prst);


  OV7670_xclk <= clk_24;


  -----------------------------------------------------------------------------
  --
  -- MIG
  --
  -----------------------------------------------------------------------------
  mig_aresetn <= not rst_ui;            -- This resets only the axi shim.

  mig_7series_0 : entity work.mig_7series_0
    port map (
      ddr3_dq      => ddr3_dq,
      ddr3_dqs_n   => ddr3_dqs_n,
      ddr3_dqs_p   => ddr3_dqs_p,
      ddr3_addr    => ddr3_addr,
      ddr3_ba      => ddr3_ba,
      ddr3_ras_n   => ddr3_ras_n,
      ddr3_cas_n   => ddr3_cas_n,
      ddr3_we_n    => ddr3_we_n,
      ddr3_reset_n => ddr3_reset_n,
      ddr3_ck_p    => ddr3_ck_p,
      ddr3_ck_n    => ddr3_ck_n,
      ddr3_cke     => ddr3_cke,
      ddr3_cs_n    => ddr3_cs_n,
      ddr3_dm      => ddr3_dm,
      ddr3_odt     => ddr3_odt,

      sys_clk_i => clk_mig_sys,
      clk_ref_i => clk_200,             -- Ref clk must be 200MHZ

      ui_clk          => clk_ui,
      ui_clk_sync_rst => mig_ui_clk_sync_rst,
      mmcm_locked     => mig_mmcm_locked,
      aresetn         => mig_aresetn,
      app_sr_req      => '0',
      app_ref_req     => '0',
      app_zq_req      => '0',
      app_sr_active   => open,
      app_ref_ack     => open,
      app_zq_ack      => open,

      s_axi_awid          => m_axi_awid,
      s_axi_awaddr        => m_axi_awaddr,
      s_axi_awlen         => m_axi_awlen,
      s_axi_awsize        => m_axi_awsize,
      s_axi_awburst       => m_axi_awburst,
      s_axi_awlock        => "0",
      s_axi_awcache       => "0000",    --UG586: awcache unused
      s_axi_awprot        => "000",
      s_axi_awqos         => "0000",
      s_axi_awvalid       => m_axi_awvalid,
      s_axi_awready       => m_axi_awready,
      s_axi_wdata         => m_axi_wdata,
      s_axi_wstrb         => m_axi_wstrb,
      s_axi_wlast         => m_axi_wlast,
      s_axi_wvalid        => m_axi_wvalid,
      s_axi_wready        => m_axi_wready,
      s_axi_bready        => m_axi_bready,
      s_axi_bid           => m_axi_bid,
      s_axi_bresp         => m_axi_bresp,
      s_axi_bvalid        => m_axi_bvalid,
      s_axi_arid          => m_axi_awid,
      s_axi_araddr        => m_axi_araddr,
      s_axi_arlen         => m_axi_arlen,
      s_axi_arsize        => m_axi_arsize,
      s_axi_arburst       => m_axi_arburst,
      s_axi_arlock        => "0",
      s_axi_arcache       => "0000",    --UG586: arcache unused
      s_axi_arprot        => "000",
      s_axi_arqos         => "0000",
      s_axi_arvalid       => m_axi_arvalid,
      s_axi_arready       => m_axi_arready,
      s_axi_rready        => m_axi_rready,
      s_axi_rid           => m_axi_rid,
      s_axi_rdata         => m_axi_rdata,
      s_axi_rresp         => m_axi_rresp,
      s_axi_rlast         => m_axi_rlast,
      s_axi_rvalid        => m_axi_rvalid,
      init_calib_complete => open,
      device_temp         => open,
      sys_rst             => '1'        --never reset? - active low.
      );

  -----------------------------------------------------------------------------
  --
  -- Memory writer and reader
  --
  -----------------------------------------------------------------------------

  -- Bring the pixel data into the clk_ui domain.
  cap_pxl_data <= cap_pxl_r & cap_pxl_g & cap_pxl_b;

  fifo_async_1 : entity work.fifo_async
    generic map (
      G_DEPTH_LOG2 => 3,
      G_DATA_WIDTH => 16,
      G_RAM_STYLE  => "distributed")
    port map (
      clk_wr    => pclk,
      rst_wr    => prst,
      i_wr_en   => cap_pxl_vld,
      i_wr_data => cap_pxl_data,
      clk_rd    => clk_ui,
      rst_rd    => rst_ui,
      i_rd_en   => '1',
      o_rd_data => mem_wr_data,
      o_full    => pxl_data_async_fifo_full,
      o_empty   => pxl_data_async_fifo_empty
      );

  mem_wr_en <= not pxl_data_async_fifo_empty;

  sync_pulse_cap_eos : entity work.sync_pulse
    generic map (
      G_REGISTER_STAGES => 8)  --Longer delay than other sof reset generator
    port map (
      clk_a   => pclk,
      i_pulse => cap_eos,
      clk_b   => clk_ui,
      o_pulse => cap_eos_ui);

  -- Control for memory write/read. Memory writer and reader sample the address
  -- pointer on rst (connected to capture sof and vga sof). So we only need to increment the
  -- address pointer any time after sof.
  p_memory_ptr_ctrl : process(clk_ui)
  begin
    if rising_edge(clk_ui) then
      if cap_sof_ui = '1' then
        frame_wr_idx <= not frame_wr_idx;
      end if;

      if frame_wr_idx = '0' then
        next_mem_wr_ptr <= to_unsigned(C_BASE_PTR, next_mem_wr_ptr'length);
      else
        next_mem_wr_ptr <= to_unsigned(C_BASE_PTR + C_FRAME_OFFSET, next_mem_wr_ptr'length);
      end if;

      if rst_ui = '1' then
        frame_wr_idx <= '0';
      end if;
    end if;
  end process;

  -- Since we only store two frames (ping pong) the next wr ptr is also the
  -- previous wr pointer, so set this to the rd pointer
  mem_rd_ptr <= next_mem_wr_ptr;

  sync_pulse_cap_sof : entity work.sync_pulse
    generic map (
      G_REGISTER_STAGES => 2)
    port map (
      clk_a   => pclk,
      i_pulse => cap_sof,
      clk_b   => clk_ui,
      o_pulse => cap_sof_ui);

  -- Generate reset for memory writer.
  -- We want the memory writer to reset when:
  -- 1. We get a system reset
  -- 2. We get a mig reset
  -- 3. We get a start of frame signal from the capture module
  p_mem_rst : process(clk_ui)
  begin
    if rising_edge(clk_ui) then
      mem_writer_rst <= rst_ui or mig_ui_clk_sync_rst or cap_sof_ui;
    end if;
  end process;

  --Hold flush signal high until reset/sof
  p_mem_flush : process(clk_ui)
  begin
    if rising_edge(clk_ui) then
      if cap_eos_ui = '1' then
        mem_wr_flush <= '1';
      end if;

      if mem_writer_rst = '1' then
        mem_wr_flush <= '0';
      end if;
    end if;
  end process;


  memory_writer_1 : entity work.memory_writer
    generic map (
      G_AXI_DATA_WIDTH  => C_AXI_DATA_WIDTH,
      G_AXI_ADDR_WIDTH  => C_AXI_ADDR_WIDTH,
      G_AXI_ID_WIDTH    => C_AXI_ID_WIDTH,
      G_BURST_LENGTH    => C_BURST_LENGTH,
      G_FIFO_DEPTH_LOG2 => 9,
      G_IN_DATA_WIDTH   => C_DATA_WIDTH,
      G_RAM_STYLE       => "block")
    port map (
      clk            => clk_ui,
      rst            => mem_writer_rst,
      i_base_pointer => next_mem_wr_ptr,
      i_flush        => mem_wr_flush,
      i_wr_en        => mem_wr_en,
      i_wr_data      => mem_wr_data,
      o_fifo_full    => open,
      m_axi_awaddr   => m_axi_awaddr,
      m_axi_awlen    => m_axi_awlen,
      m_axi_awsize   => m_axi_awsize,
      m_axi_awburst  => m_axi_awburst,
      m_axi_awvalid  => m_axi_awvalid,
      m_axi_awid     => m_axi_awid,
      m_axi_awready  => m_axi_awready,
      m_axi_wdata    => m_axi_wdata,
      m_axi_wstrb    => m_axi_wstrb,
      m_axi_wvalid   => m_axi_wvalid,
      m_axi_wlast    => m_axi_wlast,
      m_axi_wready   => m_axi_wready,
      m_axi_bid      => m_axi_bid,
      m_axi_bresp    => m_axi_bresp,
      m_axi_bvalid   => m_axi_bvalid,
      m_axi_bready   => m_axi_bready,
      o_err          => mem_wr_err);

  -- Generate a reset for the memory reader
  -- We want the memory reader to be reset when:
  -- 1. We get a system wide reset (rst_ui)
  -- 2. We get a reset from the mig (mig_ui_clk_sync_rst)
  -- 3. We get a vga start of frame (vga_sof)
  -- 4. We have not written in the first frame yet from the ov7670 module i.e.
  -- we don't want to display junk
  process(clk_ui)
  begin
    if rising_edge(clk_ui) then
      mem_reader_rst <= rst_ui or mig_ui_clk_sync_rst or vga_sof or first_frame_valid;

      -- Wait until at least two capture sofs have been asserted so we know one
      -- frame has been fully written into memory
      -- Delay it an extra clock because the write pointer takes one clock
      -- cycle to update
      first_frame_valid <= not cap_sof_ui_sreg(cap_sof_ui_sreg'high);
      if cap_sof_ui = '1' then
        cap_sof_ui_sreg <= cap_sof_ui_sreg(cap_sof_ui_sreg'high - 1 downto 0) & '1';
      end if;

      if rst_ui = '1' then
        cap_sof_ui_sreg <= (others => '0');
        first_frame_valid <= '0';
      end if;
    end if;
  end process;

  memory_reader_1 : entity work.memory_reader
    generic map (
      G_AXI_DATA_WIDTH  => C_AXI_DATA_WIDTH,
      G_AXI_ADDR_WIDTH  => C_AXI_ADDR_WIDTH,
      G_AXI_ID_WIDTH    => C_AXI_ID_WIDTH,
      G_BURST_LENGTH    => C_BURST_LENGTH,
      G_FIFO_DEPTH_LOG2 => 9,
      G_OUT_DATA_WIDTH  => C_DATA_WIDTH,
      G_RAM_STYLE       => "block")
    port map (
      clk            => clk_ui,
      rst            => mem_reader_rst,
      i_base_pointer => mem_rd_ptr,
      m_axi_araddr   => m_axi_araddr,
      m_axi_arlen    => m_axi_arlen,
      m_axi_arsize   => m_axi_arsize,
      m_axi_arburst  => m_axi_arburst,
      m_axi_arvalid  => m_axi_arvalid,
      m_axi_arid     => m_axi_arid,
      m_axi_arready  => m_axi_arready,
      m_axi_rdata    => m_axi_rdata,
      m_axi_rvalid   => m_axi_rvalid,
      m_axi_rlast    => m_axi_rlast,
      m_axi_rready   => m_axi_rready,
      m_axi_rid      => m_axi_rid,
      m_axi_rresp    => m_axi_rresp,
      i_rd_en        => mem_rd_en,
      o_rd_data      => mem_rd_data,
      o_empty        => mem_rd_empty,
      o_axi_read_err => axi_rd_err);

  -----------------------------------------------------------------------------
  --
  -- OV7670
  --
  -----------------------------------------------------------------------------

  -- Start configuration after waiting 1ms after hardware reset for OV7670 module
  -- See T_S:RESET on OV7670 datasheet.
  p_start_config : process(clk_100)
  begin
    if rising_edge(clk_100) then
      start_config <= '0';
      if clk_cnt_1ms < C_1MS_CNT_THRESHOLD and not G_SIM then
        clk_cnt_1ms <= clk_cnt_1ms + 1;
      elsif done_config = '0' then
        start_config <= '1';
        done_config  <= '1';
      end if;
      btn_100Mhz_1_d <= btn_100Mhz(1);
      -- Redo register config if button is pressed
      if btn_100Mhz(1) = '1' and btn_100Mhz_1_d = '0' then
        start_config <= '1';
      end if;
      
      if rst_100 = '1' then
        clk_cnt_1ms  <= (others => '0');
        done_config  <= '0';
        start_config <= '0';
      end if;
    end if;
  end process;


  OV7670_wrapper_1 : entity work.OV7670_wrapper
    generic map (
      G_BIT_DEPTH_R  => C_BIT_DEPTH_R,
      G_BIT_DEPTH_G  => C_BIT_DEPTH_G,
      G_BIT_DEPTH_B  => C_BIT_DEPTH_B,
      G_FRAME_HEIGHT => C_FRAME_HEIGHT,
      G_FRAME_WIDTH  => C_FRAME_WIDTH,
      G_CLK_FREQ     => C_SCCB_CLK_FREQ)
    port map (
      pclk           => pclk,
      prst           => prst,
      SCCB_clk       => clk_100,
      SCCB_rst       => rst_100,
      i_start_config => start_config,
      i_data         => pxl_data,
      i_vsync        => vsync,
      i_href         => href,
      o_pxl_r        => cap_pxl_r,
      o_pxl_g        => cap_pxl_g,
      o_pxl_b        => cap_pxl_b,
      o_pxl_vld      => cap_pxl_vld,
      o_sof          => cap_sof,
      o_eos          => cap_eos,
      o_SIO_C        => s_SIO_C,
      io_SIO_D       => s_SIO_D);

  SIO_C <= s_SIO_C;
  SIO_D <= s_SIO_D;

  -- Tie reset pin to high (never hardware reset) and power down pin to low
  OV7670_rst_n <= '1';
  OV7670_pwdn  <= '0';
  
  -----------------------------------------------------------------------------
  --
  -- VGA
  -- Run VGA on the mig ui clk (303.03/2 MHz) domain so we don't need extra CDC
  --
  -----------------------------------------------------------------------------

  -- generate a pixel enable for the VGA
  p_vga_clk_en : process(clk_ui)
  begin
    if rising_edge(clk_ui) then
      if vga_clk_en_cnt = C_VGA_CLK_DIV - 1 then
        vga_clk_en     <= '1';
        vga_clk_en_cnt <= (others => '0');
      else
        vga_clk_en     <= '0';
        vga_clk_en_cnt <= vga_clk_en_cnt + 1;
      end if;
      -- Hold vga in reset if first frame not written in yet.
      if rst_ui = '1' or cap_sof_ui_sreg(cap_sof_ui_sreg'high) = '0' then
        vga_clk_en     <= '0';
        vga_clk_en_cnt <= (others => '0');
      end if;
    end if;
  end process;

  p_vga_read_en : process(clk_ui)
  begin
    if rising_edge(clk_ui) then
      mem_rd_en <= '0';
      if vga_clk_en = '1' then
        if (vga_sav = '1' and vga_vblank = '0') or active_video = '1' then
          if vga_eav = '1' then
            active_video <= '0';
          else
            active_video <= '1';
            --Mem rd en is registered/delayed. This is fine because vga_clk_en
            --is gapped.
            mem_rd_en    <= '1';
          end if;
        end if;
      end if;
      if rst_ui = '1' then
        active_video <= '0';
        mem_rd_en    <= '0';
      end if;
    end if;
  end process;


  VGA_1 : entity work.VGA
    generic map (
      G_FRAME_WIDTH  => C_FRAME_WIDTH,
      G_FRAME_HEIGHT => C_FRAME_HEIGHT,
      G_H_FP         => C_VGA_H_FP,
      G_H_BP         => C_VGA_H_BP,
      G_H_PULSE      => C_VGA_H_PULSE,
      G_V_FP         => C_VGA_V_FP,
      G_V_BP         => C_VGA_V_BP,
      G_V_PULSE      => C_VGA_V_PULSE,
      G_PIXEL_WIDTH  => C_VGA_PIXEL_WIDTH)
    port map (
      clk                       => clk_ui,
      rst                       => rst_ui,
      i_pxl_en                  => vga_clk_en,
      i_red                     => unsigned(mem_rd_data(15 downto 12)),
      i_green                   => unsigned(mem_rd_data(10 downto 7)),
      i_blue                    => unsigned(mem_rd_data(4 downto 1)),
      o_hsync                   => vga_hsync,
      o_vsync                   => vga_vsync,
      std_logic_vector(o_red)   => vga_red,
      std_logic_vector(o_green) => vga_green,
      std_logic_vector(o_blue)  => vga_blue,
      o_sof                     => vga_sof,
      o_sav                     => vga_sav,
      o_eav                     => vga_eav,
      o_vblank                  => vga_vblank);

  gen_dbg : if G_DEBUG generate
    signal pclk_ui : std_logic;

  begin

    sync_ff_pclk : entity work.sync_ff
      generic map (
        G_REGISTER_STAGES => 2)
      port map (
        clk   => clk_ui,
        rst   => '0',
        i_bit => pclk,
        o_bit => pclk_ui);

    ila_0 : entity work.ila_256_2k
      port map(
        clk                 => clk_ui,
        probe0(0)           => pclk,
        probe0(1)           => rst_ui,
        probe0(2)           => mem_wr_en,
        probe0(18 downto 3) => mem_wr_data,
        probe0(19)          => cap_sof_ui,
        probe0(20)          => cap_eos_ui,
        probe0(21)          => clk_24,
        probe0(22)          => vsync,
        probe0(23)          => href,
        probe0(24)          => s_SIO_C,
        probe0(25)          => s_SIO_D,
        probe0(29 downto 26)=> btn_100Mhz,

        probe0(255 downto 30) => (others => '0')
        );

  end generate;

end;
