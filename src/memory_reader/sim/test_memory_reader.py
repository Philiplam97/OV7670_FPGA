# -*- coding: utf-8 -*-
"""

@author: Philip

test for memory reader.
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
from cocotbext.axi import AxiReadBus, AxiRamRead


class DataMonitor:
    """ """

    def __init__(self, clk, datas, empty, rd_en):
        self.values = Queue()
        self.clk = clk
        self.datas = datas
        self.empty = empty
        self.rd_en = rd_en
        self.coro = None
        # self.log = logging.getLogger(log_name)

    def start(self):
        """Start monitor"""
        if self.coro is not None:
            raise RuntimeError("Monitor already started")
        # self.log.info("Monitor started")
        self.coro = cocotb.start_soon(self._run())

    def stop(self):
        """Stop monitor"""
        if self.coro is None:
            raise RuntimeError("Monitor never started")
        self.coro.kill()
        self.coro = None
        # self.log.info("Monitor stopped")

    async def _run(self):
        while True:
            await RisingEdge(self.clk)
            if self.empty.value.binstr == "1":
                await FallingEdge(self.empty)
                continue
            if self.rd_en.value.binstr == "1":
                self.values.put_nowait(self._sample())

    def _sample(self):
        """
        Samples the data signals and builds a transaction object
        """
        return {name: handle.value for name, handle in self.datas.items()}


class Driver:
    """
    Drive the read enable port of the dut.
    """

    def __init__(self, clk, i_rd_en, o_empty, rng):

        # These are dut handles to the input/output ports
        self.clock = clk
        self.rd_en = i_rd_en
        self.fifo_empty = o_empty
        self.coro = None
        self.rng = rng
        self.mode = "full"

    def set_driver_mode(self, mode):
        self.mode = mode

    def start(self):
        """Start driver"""
        if self.coro is not None:
            raise RuntimeError("Driver already started")
        self.coro = cocotb.start_soon(self._run())

    def stop(self):
        """Stop monitor"""
        if self.coro is None:
            raise RuntimeError("Driver never started")
        self.coro.kill()
        self.rd_en.value = 0
        self.coro = None

    async def _run(self):
        self.rd_en.value = 0
        while True:
            if self.mode == "full":
                # just keep reading. Hold rd_en high
                await RisingEdge(self.clock)
                self.rd_en.value = 1
            elif self.mode == "random":
                # slow read enable
                await RisingEdge(self.clk)
                self.valid.value = int(self.rng.choice([1, 0], p=[0.2, 0.8]))
            else:
                assert False, "Invalid driver mode"


class TB:
    def __init__(self, dut, stop_at_err=False, base_address=0, test_data_length=2048):
        self.dut = dut
        self.log = dut._log
        self.clk_period = 10
        self.clk_units = "ns"
        self.checker = None
        self.stop_at_err = stop_at_err
        self.input_data = None  # asigned in init mem.
        self.check_count = 0
        self.err_count = 0
        self.rng = np.random.default_rng()

        self.base_address = base_address
        self.test_data_length = test_data_length

        self.data_out_width = self.dut.G_OUT_DATA_WIDTH.value

        self.output_mon = DataMonitor(
            self.dut.clk,
            {"Data out": self.dut.o_rd_data},
            self.dut.o_empty,
            self.dut.i_rd_en,
        )

        self.mem_size = 2 ** 14

        self.mem = AxiRamRead(
            AxiReadBus.from_prefix(dut, "m_axi"),
            self.dut.clk,
            self.dut.rst,
            size=self.mem_size,
        )

        self.driver = Driver(
            self.dut.clk,
            self.dut.i_rd_en,
            self.dut.o_empty,
            self.rng,
        )

        # start the clock
        cocotb.start_soon(
            Clock(self.dut.clk, self.clk_period, units=self.clk_units).start()
        )

    def random_ready(self):
        return itertools.cycle(self.rng.choice([1, 0], size=256, p=[0.7, 0.3]))

    def set_axi_backpressure(self, mode="random"):
        if mode == "full":
            return
        if mode == "random":
            self.mem.ar_channel.set_pause_generator(self.random_ready())
            self.mem.r_channel.set_pause_generator(self.random_ready())

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

    def init_mem(self):
        """
        length is number of data words
        """
        self.input_data = self.rng.integers(
            0, 2 ** self.data_out_width, size=self.test_data_length
        ).tolist()
        self.input_data =  np.arange(self.test_data_length).tolist()

        self.mem.write_words(
            self.base_address, self.input_data, byteorder="little", ws=self.data_out_width // 8
        )

    def check_val(self, ref, dut_output, info_str=""):
        if ref == dut_output:
            self.log.info("Data match, got {} - {} ".format(dut_output, info_str))
            return True
        else:
            fail_str = "MISMATCH: got {}, expected {} - {}".format(dut_output, ref, info_str)
            if self.stop_at_err:
                assert False, fail_str
            else:
                self.log.error(fail_str)
                return False

    async def _check(self):
        while True:
            dut_output = await self.output_mon.values.get()
            if self.input_data:
                ref_output = self.input_data.pop(0)
            else:
                return
            if not self.check_val(
                ref_output, dut_output["Data out"].integer, "rd data"
            ):
                self.err_count += 1
            self.check_count += 1

    def start(self):
        """Starts monitors"""
        self.init_mem()
        self.output_mon.start()
        self.driver.start()
        self.checker = cocotb.start_soon(self._check())

    def end_sim(self):
        """Stops everything"""
        if self.checker is None:
            raise RuntimeError("Test never started")
        self.driver.stop()
        self.output_mon.stop()

        self.checker.kill()
        self.log.info("{} transactions checked".format(self.check_count))
        if self.err_count:
            assert False, "{} number of {} transactions INCORRECT!!!".format(
                self.err_count, self.check_count
            )
        self.checker = None
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
    tb.end_sim()


# @cocotb.test()
# async def test_reset(dut):
#     """Test Reset"""
#     # Start drivers, wait a bit, stop drivers, issue a reset, start full test sequence.
#     tb = TB(dut)
#     tb.set_axi_backpressure(mode="random")
#     tb.init_signals()
#     await tb.reset()
#     tb.driver.start()
#     await tb.wait_clks(1000)
#     tb.driver.stop()

#     await tb.reset()
#     tb.start()
#     await tb.wait_clks(5000)
#     await tb.end_sim()