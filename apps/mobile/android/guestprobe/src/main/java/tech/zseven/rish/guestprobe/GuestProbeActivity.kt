package tech.zseven.rish.guestprobe

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.method.ScrollingMovementMethod
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import tech.zseven.rish.guest.AndroidGuestAssets
import tech.zseven.rish.guest.GuestAssets
import tech.zseven.rish.guest.GuestRuntimeState
import tech.zseven.rish.guest.GuestSessionController
import tech.zseven.rish.guest.RishGuestNative
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * On-screen equivalent of LocalGuestBootTest, check for check.
 *
 * The instrumentation test is the real proof on a machine that has adb. A
 * HarmonyOS phone running Android through 卓易通 does not give the host adb at
 * all, so that proof cannot be run there. This screen runs the same sequence
 * against the same classes and prints each result, so the only thing the
 * person on the phone has to supply is a tap.
 *
 * Every check states what it expected. A probe that only said "failed" would
 * move the question rather than answer it.
 */
class GuestProbeActivity : Activity() {

    private lateinit var output: TextView
    private lateinit var run: Button
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var running = false
    private var failures = 0
    private var checks = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 24, 24, 24)
            setBackgroundColor(Color.BLACK)
        }
        run = Button(this).apply {
            text = "Boot the guest"
            setOnClickListener { start() }
        }
        output = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            setTextColor(Color.WHITE)
            setTextIsSelectable(true)
            movementMethod = ScrollingMovementMethod()
            gravity = Gravity.TOP
        }
        root.addView(run, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(output, LinearLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        setContentView(root)
        line("Rish guest probe")
        line("abi        ${android.os.Build.SUPPORTED_ABIS.joinToString(",")}")
        line("device     ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
        line("android    ${android.os.Build.VERSION.RELEASE} (sdk ${android.os.Build.VERSION.SDK_INT})")
        line("kernel     ${GuestAssets.KERNEL_NAME}")
        line("initramfs  ${GuestAssets.INITRAMFS_NAME}")
        line("")
        line("Tap the button. A boot is interpreted and slow; minutes are normal.")
    }

    private fun start() {
        if (running) return
        running = true
        failures = 0
        checks = 0
        run.isEnabled = false
        run.text = "Running…"
        output.text = ""
        Thread({ probe() }, "guest-probe").start()
    }

    private fun finish(summary: String) {
        main.post {
            running = false
            run.isEnabled = true
            run.text = "Run again"
            output.append("\n$summary\n")
        }
    }

    private fun line(text: String) = main.post {
        output.append(if (output.text.isEmpty()) text else "\n$text")
    }

    /** Records one expectation. [detail] is printed whether it held or not. */
    private fun check(name: String, ok: Boolean, detail: String = "") {
        checks += 1
        if (!ok) failures += 1
        val mark = if (ok) "PASS" else "FAIL"
        line("  [$mark] $name${if (detail.isEmpty()) "" else " -- $detail"}")
    }

    private class Call {
        var receipt: Map<String, Any?>? = null
        var code: String? = null
        var message: String? = null
        val done = CountDownLatch(1)
        /** Returns false when the call never settled, which is itself a result. */
        fun await(seconds: Long): Boolean = done.await(seconds, TimeUnit.SECONDS)
    }

    private fun probe() {
        val started = System.currentTimeMillis()
        line("")
        line("== runtime ==")
        if (!RishGuestNative.available) {
            check("librish_ffi.so and librish_guest_jni.so load", false,
                "System.loadLibrary failed; this build has no staged runtime")
            finish("STOPPED after $checks checks, $failures failed.")
            return
        }
        check("librish_ffi.so and librish_guest_jni.so load", true)
        val protocol = try { RishGuestNative.protocolVersion() } catch (error: Throwable) { -1 }
        check("protocolVersion() > 0", protocol > 0, "got $protocol")

        GuestRuntimeState.setGuestRuntimeMounted(false)
        val controller = GuestSessionController(AndroidGuestAssets(this), RishGuestNative)
        try {
            line("")
            line("== boot (768 MiB) ==")
            val boot = Call()
            val bootStarted = System.currentTimeMillis()
            controller.bootGuest(
                mapOf("schema_version" to 1, "memory_mib" to 768),
                { boot.receipt = it; boot.done.countDown() },
                { code, message -> boot.code = code; boot.message = message; boot.done.countDown() },
            )
            if (!boot.await(1500)) {
                check("boot settles within 1500s", false, "still running")
                finish("STOPPED after $checks checks, $failures failed.")
                return
            }
            val bootMs = System.currentTimeMillis() - bootStarted
            check("boot is not rejected", boot.code == null, boot.code?.let { "$it ${boot.message}" } ?: "took ${bootMs}ms")
            val receipt = boot.receipt
            if (receipt == null) {
                check("boot returns a receipt", false)
                finish("STOPPED after $checks checks, $failures failed.")
                return
            }
            check("status == booted", receipt["status"] == "booted", "got ${receipt["status"]}")
            check("kernel name matches", receipt["kernel"] == GuestAssets.KERNEL_NAME, "got ${receipt["kernel"]}")
            check("initramfs name matches", receipt["initramfs"] == GuestAssets.INITRAMFS_NAME, "got ${receipt["initramfs"]}")
            check("kernel sha256 matches", receipt["kernel_sha256"] == GuestAssets.KERNEL_SHA256, "got ${receipt["kernel_sha256"]}")
            check("initramfs sha256 matches", receipt["initramfs_sha256"] == GuestAssets.INITRAMFS_SHA256, "got ${receipt["initramfs_sha256"]}")
            check("boot_ms > 0", (receipt["boot_ms"] as? Long ?: 0L) > 0L, "reported ${receipt["boot_ms"]}ms")
            check("registry reports a mounted guest", GuestRuntimeState.guestRuntimeMounted)

            line("")
            line("== single session ==")
            val second = Call()
            controller.bootGuest(
                mapOf("schema_version" to 1, "memory_mib" to 768),
                { second.receipt = it; second.done.countDown() },
                { code, message -> second.code = code; second.message = message; second.done.countDown() },
            )
            if (!second.await(60)) check("a second boot settles", false, "still running")
            else check("a second boot is refused", second.code == "E_GUEST_ALREADY_BOOTED", "got ${second.code ?: "a receipt"}")

            line("")
            line("== the guest is a real x86_64 machine ==")
            val uname = exec(controller, listOf("uname", "-m"), 300)
            if (uname == null) check("uname -m settles within 300s", false)
            else {
                check("uname -m is not rejected", uname.code == null, uname.code ?: "")
                val out = uname.receipt?.get("stdout") as? String ?: ""
                check("stdout contains x86_64", out.contains("x86_64"), out.trim())
            }

            line("")
            line("== apk add tree, from the offline repository ==")
            val apk = exec(controller, listOf("apk", "add", "tree"), 1800)
            if (apk == null) check("apk add settles within 1800s", false)
            else {
                check("apk add is not rejected", apk.code == null, apk.code ?: "")
                check("ok == true", apk.receipt?.get("ok") == true, "got ${apk.receipt?.get("ok")}")
                check("exit code == 0", apk.receipt?.get("exit_code") == 0, "got ${apk.receipt?.get("exit_code")}")
                check("receipt carries boot_units", apk.receipt?.get("boot_units") != null, "got ${apk.receipt?.get("boot_units")}")
                val out = apk.receipt?.get("stdout") as? String ?: ""
                check("output shows the tree install", out.contains("Installing tree"))
                check("output finishes with OK:", out.contains("OK:"))
            }

            line("")
            line("== the installed binary runs ==")
            val tree = exec(controller, listOf("sh", "-lc", "/usr/bin/tree --version"), 300)
            if (tree == null) check("tree --version settles within 300s", false)
            else {
                check("tree --version is not rejected", tree.code == null, tree.code ?: "")
                check("exit code == 0", tree.receipt?.get("exit_code") == 0, "got ${tree.receipt?.get("exit_code")}")
                val out = tree.receipt?.get("stdout") as? String ?: ""
                check("reports tree v2.3.2", out.contains("tree v2.3.2"), out.trim())
            }
        } catch (error: Throwable) {
            check("the probe runs without throwing", false, "${error.javaClass.simpleName}: ${error.message}")
        } finally {
            line("")
            line("== shutdown ==")
            val stop = Call()
            controller.shutdownGuest { stop.receipt = it; stop.done.countDown() }
            if (!stop.await(120)) check("shutdown settles within 120s", false)
            else check("status == shutdown", stop.receipt?.get("status") == "shutdown", "got ${stop.receipt?.get("status")}")
            check("registry reports no mounted guest", !GuestRuntimeState.guestRuntimeMounted)
            controller.close()
        }
        val seconds = (System.currentTimeMillis() - started) / 1000
        finish(if (failures == 0) "ALL $checks CHECKS PASSED in ${seconds}s"
               else "$failures of $checks CHECKS FAILED in ${seconds}s")
    }

    private fun exec(controller: GuestSessionController, command: List<String>, seconds: Long): Call? {
        val call = Call()
        val started = System.currentTimeMillis()
        controller.guestExec(
            mapOf("schema_version" to 1, "command" to command),
            { call.receipt = it; call.done.countDown() },
            { code, message -> call.code = code; call.message = message; call.done.countDown() },
        )
        if (!call.await(seconds)) return null
        line("  ${command.joinToString(" ")} -- ${System.currentTimeMillis() - started}ms")
        return call
    }
}
