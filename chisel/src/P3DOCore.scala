import chisel3._
import net.gamebub.framework.Core
import net.gamebub.framework.interface._

/**
 * 3DO Interactive Multiplayer core for Game Bub.
 *
 * The core itself is SystemVerilog (rtl/), this class only selects and
 * configures the framework interfaces and binds them to `p3do_gamebub`.
 */
class P3DOCore extends Module with Core {
    // MMCM 0 runs at 800 MHz (50 MHz x 16): 50 MHz system, 100 MHz memory,
    // 200 MHz SPI and the LCD clock all come from it.
    val mmcmVcoHz = 800_000_000

    // NTSC 3DO frame: 263 lines x 780 dots x 4 clocks at 49.0625 MHz.
    val framePeriod = 263.0 * 780.0 * 4.0 / 49_062_500.0

    val (displayClockMin, _) = ClocksV0.getClockDisplayHz(framePeriod)
    val displayDivider = (mmcmVcoHz.toFloat / displayClockMin).floor.toInt
    val displayClock = mmcmVcoHz / displayDivider

    val io = IO(new Bundle {
        val clocks = new ClocksV0(
            clockSystemHz = 50_000_000,
            clockDisplayHz = displayClock,
            clockSpiHz = 200_000_000,
        )
        val video = new VideoV0(
            videoWidth = 320,
            videoHeight = 240,
            colorDepthR = 6,
            colorDepthG = 6,
            colorDepthB = 6,
            framePeriod = framePeriod,
        )
        val audio = new AudioV0()
        val host = new HostV0()
        val input = new InputV0()
        val sdram = new SdramV0(
            addressWidth = 13,
            dataWidth = 16,
            bankWidth = 2,
            chips = 1,
        )
    })

    bindExtModule("p3do_gamebub", io, Map(
        "DISPLAY_DIVIDER" -> displayDivider,
    ))
}
