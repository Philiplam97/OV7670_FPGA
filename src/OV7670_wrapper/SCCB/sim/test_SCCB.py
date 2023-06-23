# -*- coding: utf-8 -*-
"""
Created on Thu Sep 23 22:46:54 2021

@author: Philip

test for SCCB.
"""
import numpy as np

import cocotb
from cocotb.binary import BinaryValue
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer
from cocotb.queue import Queue
from cocotb.handle import SimHandleBase


class DataValidMonitor:
    """
    Monitor for ready/valid data interface

    Args
        clk: clock signal
        valid: control signal noting a transaction occured
        datas: named handles to be sampled when transaction occurs
    """

    def __init__(self, clk, datas, valid, ready):
        self.values = Queue()
        self.clk = clk
        self.datas = datas
        self.ready = ready
        self.valid = valid
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
            if self.ready.value.binstr == "1":  # rdy && vld
                self.values.put_nowait(self._sample())

    def _sample(self):
        """
        Samples the data signals and builds a transaction object
        """
        return {name: handle.value for name, handle in self.datas.items()}


class SCCBTransaction:
    def __init__(self, id_address=0, sub_address=0, data=0):
        self.id_address = id_address
        self.sub_address = sub_address
        self.data = data

    def randomise(self, id_address_width=7, sub_address_width=8, data_width=8):
        rng = np.random.default_rng()
        self.id_address = int(rng.integers(0, 2 ** id_address_width))
        self.sub_address = int(rng.integers(0, 2 ** sub_address_width))
        self.data = int(rng.integers(0, 2 ** data_width))


class SCCBMonitor:
    """Monitor the pin wiggles and recreate the data and address fields"""

    def __init__(self, o_sio_c, io_sio_d, log):
        self.values = Queue()
        self.sio_c = o_sio_c
        self.sio_d = io_sio_d
        self.coro = None
        self.log = log

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
            # Start condition
            await FallingEdge(self.sio_d)  # TODO add timing information
            await FallingEdge(self.sio_c)

            rx_data = SCCBTransaction()
            for phase_idx in range(3):
                rx_word = 0
                for bit_idx in range(9):
                    # Sample on the rising edge of sio_c
                    await RisingEdge(self.sio_c)
                    if bit_idx < 8:
                        rx_word = (rx_word << 1) | self.sio_d.value.integer
                if phase_idx == 0:  # id
                    if (
                        rx_word & 0x1
                    ) == 1:  # only writing , this bit should be set to zero for write
                        self.log.error(
                            "ERROR: Read/Write bit sel set to read, when all transactions should be writes!"
                        )
                    rx_data.id_address = rx_word >> 1  # only top 7 bits are used for id
                elif phase_idx == 1:  # sub address
                    rx_data.sub_address = rx_word
                elif phase_idx == 2:  # Data
                    rx_data.data = rx_word
            # wait for stop condition
            await RisingEdge(self.sio_c)
            await RisingEdge(self.sio_d)
            self.values.put_nowait(rx_data)


class SCCBDriver:
    def __init__(self, clk, i_data, i_subaddr, i_id, i_vld, o_rdy):
        # These are dut handles to the input/output ports
        self.clock = clk
        self.data = i_data
        self.sub_address = i_subaddr
        self.id = i_id
        self.valid = i_vld
        self.ready = o_rdy
        self.coro = None

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
        self.valid.value = 0
        self.coro = None

    async def _run(self):
        # Just keep valid high. Transaction happens when valid and ready
        self.valid.value = 1
        trans = SCCBTransaction()
        trans.randomise()
        self.data.value = trans.data
        self.sub_address.value = trans.sub_address
        self.id.value = trans.id_address

        while True:
            await RisingEdge(self.clock)
            if self.ready.value.binstr != "1":
                await RisingEdge(self.ready)
                continue
            # Ready is high and Valid
            trans = SCCBTransaction()
            trans.randomise()
            self.data.value = trans.data
            self.sub_address.value = trans.sub_address
            self.id.value = trans.id_address


class TB:
    def __init__(self, dut, stop_at_err=False):
        self.dut = dut
        self.log = dut._log
        self.clk_period = 10
        self.clk_units = "ns"
        self.ref_queue = []
        self.checker = None
        self.stop_at_err = stop_at_err
        self.check_count = 0
        self.err_count = 0

        self.input_mon = DataValidMonitor(
            clk=self.dut.clk,
            valid=self.dut.i_vld,
            ready=self.dut.o_rdy,
            datas={
                "data": self.dut.i_data,
                "sub_address": self.dut.i_subaddr,
                "id_address": self.dut.i_id,
            },
        )

        self.output_mon = SCCBMonitor(self.dut.o_sio_c, self.dut.io_sio_d, self.log)

        self.driver = SCCBDriver(
            self.dut.clk,
            self.dut.i_data,
            self.dut.i_subaddr,
            self.dut.i_id,
            self.dut.i_vld,
            self.dut.o_rdy,
        )

        # start the clock
        cocotb.fork(Clock(dut.clk, self.clk_period, units=self.clk_units).start())

    async def reset(self, n_clks=5):
        self.log.info("reset")
        self.dut.rst.value = 1
        await self.wait_clks(n_clks)
        self.dut.rst.value = 0

    async def wait_clks(self, n_clks):
        for _ in range(n_clks):
            await RisingEdge(self.dut.clk)

    def init_signals(self):
        pass # currently unused

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
            dut_output = await self.output_mon.values.get()
            ref_output = await self.input_mon.values.get()
            if not (
                self.check_val(
                    ref_output["id_address"], dut_output.id_address, "id_address"
                )
                and self.check_val(
                    ref_output["sub_address"], dut_output.sub_address, "sub_address"
                )
                and self.check_val(ref_output["data"], dut_output.data, "data")
            ):
                self.err_count += 1
            self.check_count += 1

    def start(self):
        """Starts monitors, runs model and checker coroutine"""
        if self.checker is not None:
            raise RuntimeError("Test already started!")
        self.output_mon.start()
        self.input_mon.start()
        self.driver.start()

        self.checker = cocotb.fork(self._check())

    def end_sim(
        self,
    ):
        """Stops everything"""
        if self.checker is None:
            raise RuntimeError("Test never started")
        self.driver.stop()
        self.output_mon.stop()
        self.input_mon.stop()

        self.checker.kill()
        self.log.info("{} transactions checked".format(self.check_count))
        if self.err_count:
            assert False, "{} number of {} transactions INCORRECT!!!".format(self.err_count, self.check_count)
        self.checker = None
        self.log.info("End of sim")


@cocotb.test()
async def test_random(dut):
    """Test Random"""

    tb = TB(dut)
    cocotb.fork(tb.reset())
    tb.start()
    await Timer(0.001, units="sec")
    tb.end_sim()
    
@cocotb.test()
async def test_reset(dut):
    """Test Random"""

    tb = TB(dut)
    # Do a random reset
    await tb.reset()
    tb.driver.start()
    await Timer(0.5, units="ms")
    tb.driver.stop()
    await tb.reset()
    # Start the regular test
    tb.start()
    await Timer(0.001, units="sec")
    tb.end_sim()
