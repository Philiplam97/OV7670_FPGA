# -*- coding: utf-8 -*-
"""

@author: Philip

test for memory writer.
"""
import numpy as np
import logging
import itertools

import cocotb
from cocotb.binary import BinaryValue
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer, Edge, First
from cocotb.queue import Queue
from cocotb.handle import SimHandleBase
from cocotbext.axi import AxiWriteBus, AxiRamWrite 

class DataValidMonitor:
    """
    Generic monitor for valid data interface

    Args
        clk: clock signal
        valid: control signal noting a transaction occured
        datas: named handles to be sampled when transaction occurs
    """

    def __init__(self, clk, datas, valid):
        self.values = Queue()
        self.clk = clk
        self.datas = datas
        self.valid = valid
        self.coro = None
        #self.log = logging.getLogger(log_name)


    def start(self):
        """Start monitor"""
        if self.coro is not None:
            raise RuntimeError("Monitor already started")
        #self.log.info("Monitor started")
        self.coro = cocotb.start_soon(self._run())

    def stop(self):
        """Stop monitor"""
        if self.coro is None:
            raise RuntimeError("Monitor never started")
        self.coro.kill()
        self.coro = None
        #self.log.info("Monitor stopped")


    async def _run(self):
        while True:
            await RisingEdge(self.clk)
            if self.valid.value.binstr != "1":
                await RisingEdge(self.valid)
                continue
            self.values.put_nowait(self._sample())

    def _sample(self):
        """
        Samples the data signals and builds a transaction object
        """
        return {name: handle.value for name, handle in self.datas.items()}


class Driver:
    def __init__(self, clk, i_data, i_vld, o_full, rng, mode="full"):
        # These are dut handles to the input/output ports
        self.clock = clk
        self.data = i_data
        self.valid = i_vld
        self.fifo_full = o_full
        self.coro = None
        self.rng = rng
        self.mode = mode

    def start(self):
        """Start driver"""
        if self.coro is not None:
            raise RuntimeError("Driver already started")
        self.coro = [
            cocotb.start_soon(self._drive_valid()),
            cocotb.start_soon(self._drive_data()),
        ]

    def stop(self):
        """Stop monitor"""
        if self.coro is None:
            raise RuntimeError("Driver never started")
        [coro.kill() for coro in self.coro]
        self.valid.value = 0
        self.coro = None

    async def _drive_valid(self):
        self.valid.value = 1
        while True:
            if self.mode == "full":
                # Set valid high unless full.
                await Edge(self.fifo_full)
                self.valid.value = int(not self.fifo_full.value)
            elif self.mode == "random":
                clk_rising_edge_trigger = RisingEdge(self.clock)
                full_trigger = Edge(self.fifo_full)
                t_ret = await First(clk_rising_edge_trigger, full_trigger)
                if t_ret == full_trigger and self.fifo_full.value == 1:
                    self.valid.value = 0
                else:
                    self.valid.value = int(self.rng.choice([1,0], p=[0.9,0.1]))

            else:
                assert False, "Invalid driver mode"

    async def _drive_data(self):
        data_width = len(self.data.value.binstr)
        self.data.value = int(self.rng.integers(0, 2 ** data_width))
        while True:
            await RisingEdge(self.clock)
            if self.fifo_full.value.binstr == "0" and self.valid.value.binstr == "1":
                self.data.value = int(self.rng.integers(0, 2 ** data_width))

class TB:
    def __init__(self, dut, stop_at_err=False, base_address=0):
        self.dut = dut
        self.log = dut._log
        self.clk_period = 10
        self.clk_units = "ns"
        self.checker = None
        self.stop_at_err = stop_at_err
        #self.check_count = 0
        #self.err_count = 0
        self.rng = np.random.default_rng()

        self.base_address = base_address
        self.data_in_width = self.dut.G_IN_DATA_WIDTH.value

        self.input_mon = DataValidMonitor(
            self.dut.clk, {"Data in": self.dut.i_wr_data}, self.dut.i_wr_en
        )

        self.mem_size = 2 ** 14
        
        self.mem = AxiRamWrite(
            AxiWriteBus.from_prefix(dut, "m_axi"),
            self.dut.clk,
            self.dut.rst,
            size=self.mem_size,
        )

        self.driver = Driver(
            self.dut.clk,
            self.dut.i_wr_data,
            self.dut.i_wr_en,
            self.dut.o_fifo_full,
            self.rng,
            mode="random",
        )

        # start the clock
        cocotb.start_soon(
            Clock(self.dut.clk, self.clk_period, units=self.clk_units).start()
        )

    def random_ready(self):
        return itertools.cycle(self.rng.choice([1, 0], size=256, p=[0.7, 0.3]))
        
    def set_axi_backpressure(self, mode="random"):
        if mode=="full":
            return
        if mode=="random":
            self.mem.aw_channel.set_pause_generator(self.random_ready())
            self.mem.w_channel.set_pause_generator(self.random_ready())

    async def reset(self, n_clks=5):
        self.log.info("reset")
        self.dut.rst.value = 1
        await self.wait_clks(n_clks)
        self.dut.rst.value = 0

    async def wait_clks(self, n_clks):
        for _ in range(n_clks):
            await RisingEdge(self.dut.clk)

    def init_signals(self):
        self.dut.i_base_pointer.value = self.base_address
        self.dut.i_flush.value = 0

    def check_mem(self):
        # TODO move this to separate class.
        # A final end of sim equivalence check in of the memory and the recorded transactions.
        # read the word size based on the data width

        ref_mem_data = [val["Data in"].integer for val in list(self.input_mon.values._queue)]
        dut_mem_data = self.mem.read_words(
            self.base_address, len(ref_mem_data), byteorder="little", ws=self.data_in_width // 8
        )
        if dut_mem_data == ref_mem_data:
            self.log.info("End of sim memory check PASSED")
        else:
            # Save to file for debugging
            with open("dut_mem_data.txt", "w") as f:
                for val in dut_mem_data:
                    f.write("{}\n".format(val))

            with open("ref_mem_data.txt", "w") as f:
                for val in ref_mem_data:
                    f.write("{}\n".format(val))

            self.log.error("End of sim memory check FAILED")
            if self.stop_at_err:
                assert False, "End of sim memory check FAILED"

    def start(self):
        """Starts monitors"""
        self.input_mon.start()
        self.driver.start()

    async def end_sim(self):
        """Stops everything"""
        self.driver.stop()
        # need to send flush signal, is there a better place to put this?
        self.dut.i_flush.value = 1
        await self.wait_clks(500)
        self.input_mon.stop()
        self.check_mem()
        self.log.info("End of sim")


@cocotb.test()
async def test_random(dut):
    """Test Random"""

    tb = TB(dut)
    tb.set_axi_backpressure(mode="random")
    tb.init_signals()
    await tb.reset()
    tb.start()
    await tb.wait_clks(5000)
    await tb.end_sim()

@cocotb.test()
async def test_reset(dut):
    """Test Reset"""
    # Start drivers, wait a bit, stop drivers, issue a reset, start full test sequence.
    tb = TB(dut)
    tb.set_axi_backpressure(mode="random")
    tb.init_signals()
    await tb.reset()
    tb.driver.start()
    await tb.wait_clks(1000)
    tb.driver.stop()
    
    await tb.reset()    
    tb.start()
    await tb.wait_clks(5000)
    await tb.end_sim()
