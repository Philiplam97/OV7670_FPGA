# -*- coding: utf-8 -*-
"""

@author: Philip

test for capture.
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
    Monitor for valid data interface

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
            self.values.put_nowait(self._sample())

    def _sample(self):
        """
        Samples the data signals and builds a transaction object
        """
        return {name: handle.value for name, handle in self.datas.items()}


class Ov7670Bus:
    def __init__(
        self,
        pclk,
        rst,
        o_data,
        o_vsync,
        o_href,
        frame_pattern="random",
        Ov7670_output_format="RGB565",
        bit_depth_r=5,
        bit_depth_g=6,
        bit_depth_b=5,
        frame_width=640,
        frame_height=480,
        vsync_width=3,
        v_front_porch=17,
        v_back_porch=10,
        href_blank=144,
    ):
        self.pclk = pclk
        self.rst = rst
        self.o_data = o_data
        self.o_vsync = o_vsync
        self.o_href = o_href
        self.bit_depth_r = bit_depth_r
        self.bit_depth_g = bit_depth_g
        self.bit_depth_b = bit_depth_b
        self.frame_width = frame_width
        self.frame_height = frame_height
        self.vsync_width = vsync_width
        self.v_front_porch = v_front_porch
        self.v_back_porch = v_back_porch
        self.v_blank = self.v_front_porch + self.frame_width + self.v_back_porch
        self.href_blank = href_blank

        self.coro = None

        self.total_lines = (
            self.vsync_width
            + self.v_front_porch
            + self.frame_height
            + self.v_back_porch
        )
        self.test_frame = self.init_frame(frame_pattern)

        assert (
            Ov7670_output_format == "RGB565"
        ), "Only RGB565 output format supported for now!"

    def init_frame(self, pattern):
        # TODO add multi frame
        if pattern == "random":
            rng = np.random.default_rng()
            frame_data_r = rng.integers(
                0, 2 ** self.bit_depth_r, size=(self.frame_height, self.frame_width)
            )
            frame_data_g = rng.integers(
                0, 2 ** self.bit_depth_g, size=(self.frame_height, self.frame_width)
            )
            frame_data_b = rng.integers(
                0, 2 ** self.bit_depth_b, size=(self.frame_height, self.frame_width)
            )
            frame_data = np.stack((frame_data_r, frame_data_g, frame_data_b), axis=-1)
        else:
            assert False, "ERROR: {} pattern not implemented!".format(pattern)

        return frame_data

    def start(self):
        """Start OV7670 bus"""
        if self.coro is not None:
            raise RuntimeError("OV7670 already started")
        self.coro = cocotb.start_soon(self._run())

    def stop(self):
        """Stop monitor"""
        if self.coro is None:
            raise RuntimeError("OV7670 never started")
        self.coro.kill()
        self.coro = None

    async def _run(self):
        v_cnt = 0
        h_cnt = 0
        data_in = 0
        self.o_href.value = 0
        self.o_data.value = 0
        self.o_vsync.value = 0
        second_byte = False

        while True:
            await RisingEdge(self.pclk)
            if self.rst.value.binstr == "1":
                v_cnt = 0
                h_cnt = 0
                data_in = 0
                second_byte = False
                continue
            # else not reset
            # For rgb, t_p = 2 x t_pclk. Refer to Figure 6 VGA Frame Timing in OV7670 document
            # data is for one pixel is sent over two bytes over two clock cycles
            if v_cnt < 3:
                vsync = 1
            else:
                vsync = 0

            if (
                v_cnt < self.vsync_width + self.v_front_porch
                or v_cnt >= self.vsync_width + self.v_front_porch + self.frame_height
            ):
                href = 0
            else:
                if h_cnt < self.frame_width:
                    href = 1
                else:
                    href = 0

            if href:
                x_pos = h_cnt
                y_pos = v_cnt - self.vsync_width - self.v_front_porch
                if not second_byte:
                    # send first byte of data. Refer to Figure 11 RGB 565 Output Timing Diagram for packing info
                    # the first byte has data[7:3] = R[4:0], data[2:0] = G[5:3]
                    data_in = (self.test_frame[y_pos, x_pos, 0] << 3) | (
                        self.test_frame[y_pos, x_pos, 1] >> 3
                    )
                else:
                    # the second byte has data[7:5] = G[2:0], data[4:0] = B[4:0]
                    data_in = ((self.test_frame[y_pos, x_pos, 1] & 0b111) << 5) | (
                        self.test_frame[y_pos, x_pos, 2]
                    )

            # Assign to dut pins
            self.o_href.value = href
            self.o_data.value = int(data_in)
            self.o_vsync.value = vsync

            # Update counts
            if second_byte:
                if h_cnt == self.frame_width + self.href_blank - 1:
                    h_cnt = 0
                    if v_cnt == self.total_lines - 1:
                        v_cnt = 0
                    else:
                        v_cnt += 1
                else:
                    h_cnt += 1

            second_byte = not second_byte


class TB:
    def __init__(self, dut, stop_at_err=False):
        self.dut = dut
        self.log = dut._log
        self.clk_period = 10
        self.clk_units = "ns"
        self.checker = None
        self.stop_at_err = stop_at_err
        self.check_count = 0
        self.err_count = 0

        self.frame_width = self.dut.G_FRAME_WIDTH.value.integer
        self.frame_height = self.dut.G_FRAME_HEIGHT.value.integer

        self.pxl_out_mon = DataValidMonitor(
            clk=self.dut.pclk,
            valid=self.dut.o_pxl_vld,
            datas={
                "o_pxl_r": self.dut.o_pxl_r,
                "o_pxl_g": self.dut.o_pxl_g,
                "o_pxl_b": self.dut.o_pxl_b,
            },
        )

        self.OV7670_bus = Ov7670Bus(
            self.dut.pclk,
            self.dut.rst,
            self.dut.i_data,
            self.dut.i_vsync,
            self.dut.i_href,
            frame_pattern="random",
            Ov7670_output_format="RGB565",
            bit_depth_r=self.dut.G_BIT_DEPTH_R.value,
            bit_depth_g=self.dut.G_BIT_DEPTH_G.value,
            bit_depth_b=self.dut.G_BIT_DEPTH_B.value,
            frame_width=self.frame_width,
            frame_height=self.frame_height,
            vsync_width=3,  # Values from datasheet
            v_front_porch=17,
            v_back_porch=10,
            href_blank=144,
        )

        # start the clock
        cocotb.start_soon(Clock(self.dut.pclk, self.clk_period, units=self.clk_units).start())

    async def reset(self, n_clks=5):
        self.log.info("reset")
        self.dut.rst.value = 1
        await self.wait_clks(n_clks)
        self.dut.rst.value = 0

    async def wait_clks(self, n_clks):
        for _ in range(n_clks):
            await RisingEdge(self.dut.pclk)

    def init_signals(self):
        pass  # currently unused

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
        x_pos = 0
        y_pos = 0
        while True:
            dut_output = await self.pxl_out_mon.values.get()
            for colour_plane in range(3):  # RGB
                ref_output = self.OV7670_bus.test_frame[y_pos, x_pos, colour_plane]
                data_key = list(dut_output.keys())[colour_plane]
                dut_val = dut_output[data_key].integer
                if not self.check_val(
                    ref_output, dut_val, "{}, x={}, y={}".format(data_key, x_pos, y_pos)
                ):
                    self.err_count += 1
                self.check_count += 1

            if x_pos == self.frame_width - 1:
                x_pos = 0
                if y_pos == self.frame_height - 1:
                    y_pos = 0
                else:
                    y_pos += 1
            else:
                x_pos += 1

    def start(self):
        """Starts monitors and checker coroutine"""
        if self.checker is not None:
            raise RuntimeError("Test already started!")
        self.pxl_out_mon.start()
        self.OV7670_bus.start()
        self.checker = cocotb.start_soon(self._check())

    def end_sim(
        self,
    ):
        """Stops everything"""
        if self.checker is None:
            raise RuntimeError("Test never started")
        self.pxl_out_mon.stop()
        self.OV7670_bus.stop()

        self.checker.kill()

        self.log.info("{} transactions checked".format(self.check_count))
        if self.err_count:  # fail the test is there are errors
            assert False, "{} number of {} transactions INCORRECT!!!".format(
                self.err_count, self.check_count
            )
        self.checker = None
        self.log.info("End of sim")


@cocotb.test()
async def test_random(dut):
    """Test Random"""

    tb = TB(dut)
    cocotb.start_soon(tb.reset())
    tb.start()
    await RisingEdge(tb.dut.o_eos)
    await tb.wait_clks(50)
    tb.end_sim()


# @cocotb.test()
# async def test_reset(dut):
#     """Test Random"""

#     tb = TB(dut)
#     # Do a random reset
#     await tb.reset()
#     tb.driver.start()
#     await Timer(0.5, units="ms")
#     tb.driver.stop()
#     await tb.reset()
#     # Start the regular test
#     tb.start()
#     await Timer(0.001, units="sec")
#     tb.end_sim()
