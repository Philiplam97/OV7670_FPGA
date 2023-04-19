# -*- coding: utf-8 -*-
"""
Created on Thu Sep 23 22:46:54 2021

@author: Philip

test for Asynchronous FIFO.
"""
import numpy as np

import cocotb
from cocotb.binary import BinaryValue
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Edge, Timer, First, ReadOnly
from cocotb.queue import Queue
from cocotb.handle import SimHandleBase


class DataValidMonitor:
    """
    Monitor for ready/valid data interface

    Args
        clk: clock signal
        valid: control signal indicating data bus is valid
        data: handle to be sampled when transaction occurs
        ready: control signal indicating receiver is ready
        ready_polarity: polarity of ready signal. "1"=active high, "0"=active_low
        data_queue: cocotb queue object where sampled data will be placed
    """

    def __init__(
        self,
        data_queue,
        log,
        clk,
        data,
        valid,
        ready,
        ready_polarity="1",
    ):
        self.values = data_queue
        self.clk = clk
        self.data = data
        self.ready = ready
        self.valid = valid
        self.ready_polarity = ready_polarity
        self.log = log
        self.coro = None

    def start(self):
        """Start monitor"""
        if self.coro is not None:
            raise RuntimeError("Monitor already started")
        self.coro = cocotb.start_soon(self._run())

    def stop(self):
        """Stop monitor"""
        if self.coro is None:
            raise RuntimeError("Monitor never started")
        self.coro.kill()
        self.coro = None

    async def _run(self):
        while True:
            await RisingEdge(self.clk)
            if self.valid.value.binstr != "1":
                await RisingEdge(self.valid)
                continue
            if self.ready.value.binstr == self.ready_polarity:  # rdy && vld
                sampled_data = self.data.value.integer
                await ReadOnly()
                self.values.put_nowait(sampled_data)
                #self.log.info(self.values._queue)


class FullMonitor:
    """
    Full flag monitor and checker.
    This checks whether the full flag is asserted properly by the async FIFO.
    """

    def __init__(self, log, data_queue, clk, full_flag, stop_at_err=False):
        self.log = log  # TODO add separate internal log
        self.FIFO = data_queue  # Cocotb queue object modelling the FIFO
        self.clk = clk
        self.full_flag = full_flag
        self.stop_at_err = stop_at_err
        self.coro = None
        self.full_cnt = 0
        self.err_cnt = 0

    def start(self):
        if self.coro is not None:
            raise RuntimeError("Full flag monitor already started")
        self.coro = cocotb.start_soon(self._run())

    def stop(self):
        """Stop monitor"""
        if self.coro is None:
            raise RuntimeError("Full flag monitor never started")
        self.coro.kill()
        self.coro = None
        self.log.info(
            "Full monitor detected {} correct assertions of the Full flag".format(
                self.full_cnt
            )
        )

    async def _run(self):
        while True:
            await RisingEdge(self.clk)
            if self.FIFO.full():
                # FIFO is full, check to make sure full flag is asserted too.
                if self.full_flag.value != 1:
                    self.log.error("FIFO is full but full flag is not asserted!")
                    self.err_cnt += 1
                    if self.stop_at_err:
                        assert False, "FIFO is full but full flag is not asserted!"
                else:
                    # Keep a count of how many times full is asserted
                    self.full_cnt += 1


class EmptyMonitor:
    """
    Empty flag monitor and checker.
    This checks whether the empty flag is asserted properly by the async FIFO.
    """

    def __init__(self, log, data_queue, clk, empty_flag, stop_at_err=False):
        self.log = log  # TODO add separate internal log
        self.FIFO = data_queue  # Cocotb queue object modelling the FIFO
        self.clk = clk
        self.empty_flag = empty_flag
        self.stop_at_err = stop_at_err
        self.coro = None
        self.empty_cnt = 0
        self.err_cnt = 0

    def start(self):
        if self.coro is not None:
            raise RuntimeError("Empty flag monitor already started")
        self.coro = cocotb.start_soon(self._run())

    def stop(self):
        """Stop monitor"""
        if self.coro is None:
            raise RuntimeError("Empty flag monitor never started")
        self.coro.kill()
        self.coro = None
        self.log.info(
            "Empty monitor detected {} correct assertions of the Empty flag".format(
                self.empty_cnt
            )
        )

    async def _run(self):
        while True:
            await RisingEdge(self.clk)
            if self.FIFO.empty():
                # FIFO is empty, check to make sure empty flag is asserted too.
                if self.empty_flag.value != 1:
                    self.err_cnt += 1
                    self.log.error("FIFO is empty but empty flag is not asserted!")
                    if self.stop_at_err:
                        assert False, "FIFO is empty but empty flag is not asserted!"
                else:
                    # Keep a count of how many times empty is asserted
                    self.empty_cnt += 1


class FifoWriter:
    """
    Writes random data into the FIFO
    """

    def __init__(self, log, rng, clk, i_wr_en, i_wr_data, o_full, mode="full"):
        self.log = log
        self.rng = rng
        self.clk = clk
        self.wr_data = i_wr_data
        self.wr_en = i_wr_en
        self.full_flag = o_full
        self.coro = None
        self.mode = mode  # full, random

    def start(self):
        if self.coro is not None:
            raise RuntimeError("FIFO writer already started")
        self.log.info("FIFO writer started with mode: {}".format(self.mode))
        self.coro = [
            cocotb.start_soon(self._run()),
            cocotb.start_soon(self._write_data()),
        ]

    def stop(self):
        if self.coro is None:
            raise RuntimeError("FIFO writer never started")
        [x.kill() for x in self.coro]
        self.wr_en.value = 0
        self.coro = None

    async def _run(self):
        while True:
            if self.mode == "full":
                # Hold write enable high (FIFO should be protected for writes when full)
                self.wr_en.value = 1
                await RisingEdge(self.clk)
            elif self.mode == "random":
                # Assert wr_en on random cycles
                await RisingEdge(self.clk)
                self.wr_en.value = int(self.rng.choice([0, 1], p=[0.95, 0.05]))
            else:
                assert (
                    False
                ), 'Invalid mode set for FIFO writer. Must be "full" or "random"'

    async def _write_data(self):
        """
        This will change the write data if FIFO is not full and wr_en is high.
        """
        data_width = len(self.wr_data.value.binstr)
        self.wr_data.value = int(self.rng.integers(0, 2 ** data_width))
        while True:
            await RisingEdge(self.clk)
            if self.full_flag.value.binstr == "0" and self.wr_en.value.binstr == "1":
                self.wr_data.value = int(self.rng.integers(0, 2 ** data_width))


class FifoReader:
    """
    Asserts the read enable for the FIFO.
    """

    def __init__(self, log, rng, clk, i_rd_en, o_empty, mode="full"):
        self.log = log
        self.rng = rng
        self.clk = clk
        self.rd_en = i_rd_en
        self.empty_flag = o_empty
        self.coro = None
        self.mode = mode  # full, random

    def start(self):
        if self.coro is not None:
            raise RuntimeError("FIFO reader already started")
        self.log.info("FIFO reader started with mode: {}".format(self.mode))
        self.coro = cocotb.start_soon(self._run())

    def stop(self):
        if self.coro is None:
            raise RuntimeError("FIFO reader never started")
        self.coro.kill()
        self.rd_en.value = 0
        self.coro = None

    async def _run(self):
        while True:
            if self.mode == "full":
                # Hold write enable high (FIFO should be protected for writes when full)
                self.rd_en.value = 1
                await RisingEdge(self.clk)
            elif self.mode == "random":
                # Assert wr_en on random cycles
                await RisingEdge(self.clk)
                self.rd_en.value = int(self.rng.choice([0, 1], p=[0.95, 0.05]))
            else:
                assert (
                    False
                ), 'Invalid mode set for FIFO reader. Must be "full" or "random"'


class TB:
    def __init__(self, dut, stop_at_err=False, writer_mode="full", reader_mode="full"):
        self.dut = dut
        self.log = dut._log
        self.wr_clk_period = 10
        self.rd_clk_period = 9
        self.clk_units = "ns"
        self.rd_data_checker = None
        self.stop_at_err = stop_at_err
        self.check_count = 0
        self.err_count = 0

        self.writer_mode = writer_mode
        self.reader_mode = reader_mode

        self.rng = np.random.default_rng()

        fifo_depth = 2 ** self.dut.G_DEPTH_LOG2.value
        self.ref_FIFO = Queue(
            maxsize=fifo_depth + 1
        )  # Since it is FWFT, we can store one more.
        self.output_queue = Queue()

        self.write_mon = DataValidMonitor(
            data_queue=self.ref_FIFO,
            log=self.log,
            clk=self.dut.clk_wr,
            valid=self.dut.i_wr_en,
            ready=self.dut.o_full,
            data=self.dut.i_wr_data,
            ready_polarity="0",
        )

        self.fifo_wr_driver = FifoWriter(
            self.log,
            self.rng,
            self.dut.clk_wr,
            self.dut.i_wr_en,
            self.dut.i_wr_data,
            self.dut.o_full,
            mode=self.writer_mode,
        )
        self.full_checker = FullMonitor(
            self.log, self.ref_FIFO, self.dut.clk_wr, self.dut.o_full, self.stop_at_err
        )

        # self.read_mon = DataValidMonitor(
        #     data_queue=self.output_queue,
        #     clk=self.dut.clk_rd,
        #     valid=self.dut.i_rd_en,
        #     ready=self.dut.o_empty,
        #     data=self.dut.o_rd_data,
        #     ready_polarity="0",
        # )

        self.fifo_rd_driver = FifoReader(
            self.log,
            self.rng,
            self.dut.clk_rd,
            self.dut.i_rd_en,
            self.dut.o_empty,
            mode=self.reader_mode,
        )
        self.empty_checker = EmptyMonitor(
            self.log, self.ref_FIFO, self.dut.clk_rd, self.dut.o_empty, self.stop_at_err
        )

        # start the clock
        cocotb.start_soon(
            Clock(dut.clk_rd, self.wr_clk_period, units=self.clk_units).start()
        )
        cocotb.start_soon(
            Clock(dut.clk_wr, self.rd_clk_period, units=self.clk_units).start()
        )

    async def reset(self, clk, rst, n_clks=5):
        self.log.info("Reset: {}".format(rst._name))
        rst.value = 1
        await self.wait_clks(clk, n_clks)
        rst.value = 0

    async def wait_clks(self, clk, n_clks):
        for _ in range(n_clks):
            await RisingEdge(clk)

    def check_val(self, ref, dut_output, info_str=""):
        if ref == dut_output:
            self.log.info("Data match, got {} - {} ".format(dut_output, info_str))
            return True
        else:
            fail_str = "MISMATCH: got {}, expected {} - ".format(dut_output, ref)
            if self.stop_at_err:
                assert False, fail_str
            else:
                self.log.error(fail_str)
                return False

    async def _check(self):
        while True:
            await RisingEdge(self.dut.clk_rd)
            if self.dut.i_rd_en.value == 1 and self.dut.o_empty.value == 0:
                dut_output = self.dut.o_rd_data.value.integer
                ref = self.ref_FIFO.get_nowait()
                if not self.check_val(ref, dut_output, "o_rd_data"):
                    self.err_count += 1
                self.check_count += 1

    def init_dut(self):
        self.dut.i_wr_en.value = 0
        self.dut.i_rd_en.value = 0

    def start(self):
        """Starts monitors, runs model and checker coroutine"""
        if self.rd_data_checker is not None:
            raise RuntimeError("Test already started!")
        self.init_dut()
        self.write_mon.start()
        self.full_checker.start()
        # self.read_mon.start()
        self.empty_checker.start()
        self.fifo_wr_driver.start()
        self.fifo_rd_driver.start()
        self.rd_data_checker = cocotb.start_soon(self._check())

    async def end_sim(self):
        """Stops everything"""
        if self.rd_data_checker is None:
            raise RuntimeError("Test never started")
        self.fifo_wr_driver.stop()
        self.write_mon.stop()
        self.full_checker.stop()
        #        self.read_mon.stop()
        self.empty_checker.stop()
        self.fifo_rd_driver.stop()
        await Timer(1, units="step")
        self.rd_data_checker.kill()
        self.log.info("{} transactions checked".format(self.check_count))
        if self.err_count:
            assert False, "{} number of {} transactions INCORRECT!!!".format(
                self.err_count, self.check_count
            )
        if self.full_checker.err_cnt:
            assert False, "{} number of FULL flag assertion  missed!!!".format(
                self.full_checker.err_cnt
            )
        if self.empty_checker.err_cnt:
            assert False, "{} number of EMPTY flag assertion  missed!!!".format(
                self.full_checker.err_cnt
            )
        self.checker = None
        self.log.info("End of sim")


# -----------------------------------------------------------------------------------
#
# TESTS
#
# -----------------------------------------------------------------------------------


@cocotb.test()
async def test_random(dut):
    """
    Test Random - write en and read en held high
    """
    tb = TB(dut)
    cocotb.start_soon(tb.reset(dut.clk_wr, dut.rst_wr))
    await tb.reset(dut.clk_rd, dut.rst_rd)
    tb.start()
    await tb.wait_clks(dut.clk_rd, 500)
    await tb.end_sim()


@cocotb.test()
async def test_empty(dut):
    """
    Test Empty flag - fast reads, slow write
    """
    tb = TB(dut, writer_mode="random", reader_mode="full")
    cocotb.start_soon(tb.reset(dut.clk_wr, dut.rst_wr))
    await tb.reset(dut.clk_rd, dut.rst_rd)
    tb.start()
    await tb.wait_clks(dut.clk_rd, 500)
    await tb.end_sim()


@cocotb.test()
async def test_full(dut):
    """
    Test full flag - slow reads, fast write
    """
    tb = TB(dut, writer_mode="full", reader_mode="random")
    cocotb.start_soon(tb.reset(dut.clk_wr, dut.rst_wr))
    await tb.reset(dut.clk_rd, dut.rst_rd)
    tb.start()
    await tb.wait_clks(dut.clk_rd, 500)
    await tb.end_sim()
