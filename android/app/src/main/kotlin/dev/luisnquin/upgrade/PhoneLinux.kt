package dev.luisnquin.upgrade

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.security.MessageDigest
import java.util.TimeZone
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream

object PhoneLinux {
    private const val TAG = "PhoneLinux"
    private const val ROOTFS_URL =
        "https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-arm64.tar.gz"
    private const val ROOTFS_SHA256 = "04207713ece899c3740823d33690441ad3a7f0ded1101aca744e2b0f37ac7ff2"
    private const val READY_MARK = ".upgrade-ready"
    private const val SSHD_CONFIG = "/etc/ssh/upgrade_sshd_config"
    private const val AUTHORIZED = "/etc/ssh/upgrade_authorized_keys"

    private val SSHD = """
        for gid in ${'$'}(id -G); do
          grep -q "^[^:]*:[^:]*:${'$'}gid:" /etc/group || echo "android_${'$'}gid:x:${'$'}gid:" >> /etc/group
        done
        mkdir -p /run/sshd
        exec /usr/sbin/sshd -D -e -f @CONFIG@ -o Port=@PORT@
    """.trimIndent()

    private val jobs = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    @Volatile var phase = "idle"
        private set
    @Volatile var percent = -1
        private set
    @Volatile var error: String? = null
        private set
    @Volatile var hostKey: String? = null
        private set
    @Volatile private var sshd: Process? = null
    @Volatile private var sshdPort = 0

    @Volatile var sink: EventChannel.EventSink? = null

    fun changed(context: Context) {
        val now = state(context)
        main.post { sink?.success(now) }
    }

    private fun base(context: Context) = File(context.filesDir, "linux")
    private fun rootfs(context: Context) = File(base(context), "rootfs")
    private fun fakes(context: Context) = File(base(context), "proc")
    private fun temp(context: Context) = File(base(context), "tmp")

    fun installed(context: Context) = File(rootfs(context), READY_MARK).exists()

    fun running() = sshd?.isAlive == true

    fun handle(context: Context, method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        val app = context.applicationContext
        when (method) {
            "state" -> result.success(state(app))
            "install" -> {
                val key = args?.get("publicKey") as? String
                if (key == null) return result.error("args", "publicKey missing", null)
                if (phase == "download" || phase == "unpack" || phase == "setup") return result.success(state(app))
                phase = "download"
                percent = 0
                error = null
                changed(app)
                LinuxService.foreground(app)
                jobs.execute {
                    try {
                        install(app, key)
                        phase = "ready"
                    } catch (failure: Exception) {
                        Log.e(TAG, "install", failure)
                        error = failure.message ?: failure.toString()
                        phase = "failed"
                    } finally {
                        percent = -1
                        if (!running()) LinuxService.stop(app)
                        changed(app)
                    }
                }
                result.success(state(app))
            }
            "start" -> {
                val key = args?.get("publicKey") as? String
                val port = args?.get("port") as? Int
                if (key == null || port == null) return result.error("args", "publicKey and port required", null)
                LinuxService.foreground(app)
                jobs.execute {
                    val outcome = try {
                        start(app, key, port)
                        null
                    } catch (failure: Exception) {
                        Log.e(TAG, "start", failure)
                        if (!running()) LinuxService.stop(app)
                        failure.message ?: failure.toString()
                    }
                    changed(app)
                    main.post {
                        if (outcome == null) result.success(state(app)) else result.error("start", outcome, null)
                    }
                }
            }
            "stop" -> {
                stop(app)
                result.success(state(app))
            }
            "remove" -> jobs.execute {
                stop(app)
                val outcome = runCatching { deleteTree(base(app)) }
                phase = "idle"
                hostKey = null
                changed(app)
                main.post {
                    outcome.fold({ result.success(state(app)) }, { result.error("remove", it.message, null) })
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun state(context: Context): Map<String, Any?> = mapOf(
        "installed" to installed(context),
        "running" to running(),
        "phase" to phase,
        "percent" to percent,
        "error" to error,
        "hostKey" to (hostKey ?: readHostKey(context)),
    )

    private fun readHostKey(context: Context): String? {
        val pub = File(rootfs(context), "etc/ssh/ssh_host_ed25519_key.pub")
        return if (pub.exists()) pub.readText().trim() else null
    }

    private fun install(context: Context, publicKey: String) {
        if (installed(context)) return
        val base = base(context).apply { mkdirs() }
        val archive = File(base, "rootfs.tar.gz")
        if (!archive.exists() || sha256(archive) != ROOTFS_SHA256) download(context, archive)
        phase = "unpack"
        percent = -1
        changed(context)
        // Never moved after unpack: PRoot stores hard links as absolute symlinks, so a
        // renamed rootfs is full of dead links. The ready mark says it is whole.
        val root = rootfs(context)
        deleteTree(root)
        root.mkdirs()
        archive.inputStream().use { TarUnpacker(root).unpack(GZIPInputStream(BufferedInputStream(it, 1 shl 16))) }
        File(root, "etc/resolv.conf").apply { delete() }.writeText("nameserver 1.1.1.1\nnameserver 8.8.8.8\n")
        File(root, "etc/hosts").writeText("127.0.0.1 localhost\n::1 localhost\n")
        File(root, "usr/sbin/policy-rc.d").apply { writeText("#!/bin/sh\nexit 101\n") }.setExecutable(true, false)
        val zone = TimeZone.getDefault().id
        File(root, "etc/localtime").delete()
        Os.symlink("/usr/share/zoneinfo/$zone", File(root, "etc/localtime").path)
        File(root, "etc/timezone").writeText("$zone\n")
        File(root, "root").mkdirs()
        File(root, "tmp").mkdirs()
        phase = "setup"
        changed(context)
        val setup = """
            set -eu
            export DEBIAN_FRONTEND=noninteractive
            apt-get -o APT::Sandbox::User=root update
            apt-get -o APT::Sandbox::User=root install -y --no-install-recommends openssh-server
            mkdir -p /run/sshd
            passwd -d root
            test -f /etc/ssh/ssh_host_ed25519_key || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
        """.trimIndent()
        val exit = run(context, root, setup, TimeUnit.MINUTES.toSeconds(20))
        if (exit != 0) throw IllegalStateException("setup exited $exit")
        writeSshd(root, publicKey)
        File(root, READY_MARK).writeText("ubuntu-base-24.04.4-arm64\n")
        archive.delete()
        hostKey = readHostKey(context)
    }

    private fun download(context: Context, target: File) {
        val part = File(target.path + ".part")
        val connection = URL(ROOTFS_URL).openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        try {
            if (connection.responseCode != 200) throw IllegalStateException("download answered ${connection.responseCode}")
            val total = connection.contentLengthLong
            val digest = MessageDigest.getInstance("SHA-256")
            var read = 0L
            connection.inputStream.use { input ->
                part.outputStream().use { output ->
                    val buffer = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                        digest.update(buffer, 0, n)
                        read += n
                        val now = if (total > 0) (read * 100 / total).toInt() else -1
                        if (now != percent) {
                            percent = now
                            changed(context)
                        }
                    }
                }
            }
            val sum = digest.digest().joinToString("") { "%02x".format(it) }
            if (sum != ROOTFS_SHA256) {
                part.delete()
                throw IllegalStateException("download did not match its checksum")
            }
            if (!part.renameTo(target)) throw IllegalStateException("could not keep the download")
        } finally {
            connection.disconnect()
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun writeSshd(root: File, publicKey: String) {
        File(root, AUTHORIZED.drop(1)).writeText(publicKey.trim() + "\n")
        File(root, SSHD_CONFIG.drop(1)).writeText(
            """
            ListenAddress 127.0.0.1
            HostKey /etc/ssh/ssh_host_ed25519_key
            AuthorizedKeysFile $AUTHORIZED
            PermitRootLogin prohibit-password
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            UsePAM no
            StrictModes no
            PrintMotd no
            AcceptEnv LANG LC_*
            Subsystem sftp internal-sftp
            """.trimIndent() + "\n",
        )
    }

    @Synchronized
    private fun start(context: Context, publicKey: String, port: Int) {
        if (!installed(context)) throw IllegalStateException("Linux is not installed")
        if (running() && sshdPort == port) {
            writeSshd(rootfs(context), publicKey)
            return
        }
        kill(context)
        writeSshd(rootfs(context), publicKey)
        val process = builder(context, rootfs(context), SSHD.replace("@CONFIG@", SSHD_CONFIG).replace("@PORT@", "$port"))
            .redirectErrorStream(true)
            .start()
        sshd = process
        sshdPort = port
        Thread {
            runCatching { process.inputStream.bufferedReader().forEachLine { Log.i(TAG, "sshd: $it") } }
            val code = runCatching { process.waitFor() }.getOrDefault(-1)
            Log.i(TAG, "sshd exited $code")
            if (sshd === process) {
                sshd = null
                LinuxService.stop(context)
                changed(context)
            }
        }.start()
        LinuxService.foreground(context)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
        while (System.nanoTime() < deadline) {
            if (!process.isAlive) throw IllegalStateException("sshd exited ${process.exitValue()}")
            if (answers(port)) return
            Thread.sleep(150)
        }
        throw IllegalStateException("sshd did not answer on $port")
    }

    private fun answers(port: Int): Boolean = try {
        Socket().use { socket ->
            socket.connect(InetSocketAddress("127.0.0.1", port), 500)
            socket.soTimeout = 1000
            val banner = ByteArray(4)
            socket.getInputStream().read(banner) == 4 && String(banner) == "SSH-"
        }
    } catch (_: Exception) {
        // ignored: a refused or silent port only means sshd is not up yet; the caller retries.
        false
    }

    fun stop(context: Context) {
        kill(context)
        LinuxService.stop(context)
        changed(context)
    }

    /// PRoot dies alone on a signal and leaves its tracees running, so every process the
    /// system runs is found by the loader PRoot executes it through.
    fun kill(context: Context) {
        val process = sshd
        sshd = null
        val loader = File(context.applicationInfo.nativeLibraryDir, "libproot-loader.so").path
        signalTracees(loader, OsConstants.SIGTERM)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (tracees(loader).isNotEmpty() && System.nanoTime() < deadline) Thread.sleep(50)
        signalTracees(loader, OsConstants.SIGKILL)
        if (process != null && !process.waitFor(2, TimeUnit.SECONDS)) process.destroyForcibly()
    }

    private fun signalTracees(loader: String, signal: Int) {
        for (pid in tracees(loader)) runCatching { Os.kill(pid, signal) }
    }

    private fun tracees(loader: String): List<Int> =
        File("/proc").listFiles().orEmpty().mapNotNull { entry ->
            val pid = entry.name.toIntOrNull() ?: return@mapNotNull null
            pid.takeIf { runCatching { Os.readlink("/proc/$pid/exe") }.getOrNull() == loader }
        }

    private fun run(context: Context, root: File, script: String, timeoutSeconds: Long): Int {
        val process = builder(context, root, script).redirectErrorStream(true).start()
        val reader = Thread { runCatching { process.inputStream.bufferedReader().forEachLine { Log.i(TAG, it) } } }
        reader.start()
        if (!process.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            throw IllegalStateException("setup timed out")
        }
        reader.join(2000)
        return process.exitValue()
    }

    private fun procFakes(context: Context): Array<String> {
        val dir = fakes(context).apply { mkdirs() }
        val up = SystemClock.elapsedRealtime() / 1000.0
        val boot = System.currentTimeMillis() / 1000 - up.toLong()
        val cpus = Runtime.getRuntime().availableProcessors()
        val cpuLines = (0 until cpus).joinToString("") { "cpu$it 0 0 0 0 0 0 0 0 0 0\n" }
        val files = mapOf(
            "loadavg" to "0.00 0.00 0.00 1/1 1\n",
            "uptime" to "%.2f %.2f\n".format(java.util.Locale.ROOT, up, up * cpus),
            "version" to "Linux version ${Os.uname().release} (upgrade@phone) #1 SMP PREEMPT\n",
            "stat" to "cpu  0 0 0 0 0 0 0 0 0 0\n${cpuLines}intr 0\nctxt 0\nbtime $boot\n" +
                "processes 0\nprocs_running 1\nprocs_blocked 0\nsoftirq 0 0 0 0 0 0 0 0 0 0 0\n",
            "vmstat" to "nr_free_pages 0\npgpgin 0\npgpgout 0\npswpin 0\npswpout 0\n",
        )
        return files.flatMap { (name, text) ->
            val file = File(dir, name).apply { writeText(text) }
            listOf("-b", "${file.path}:/proc/$name")
        }.toTypedArray()
    }

    private fun builder(context: Context, root: File, script: String): ProcessBuilder {
        val native = File(context.applicationInfo.nativeLibraryDir)
        val temp = temp(context).apply { mkdirs() }
        val builder = ProcessBuilder(
            File(native, "libproot.so").path,
            "--kill-on-exit",
            "--link2symlink",
            "-0",
            "-r", root.path,
            "-b", "/dev",
            "-b", "/proc",
            "-b", "/sys",
            *procFakes(context),
            "-b", "${temp.path}:/dev/shm",
            "-w", "/root",
            "/usr/bin/env", "-i",
            "HOME=/root",
            "USER=root",
            "LANG=C.UTF-8",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "/bin/sh", "-c", script,
        )
        builder.environment().apply {
            clear()
            put("PROOT_LOADER", File(native, "libproot-loader.so").path)
            put("PROOT_TMP_DIR", temp.path)
            put("LD_LIBRARY_PATH", native.path)
        }
        return builder
    }
}

private fun deleteTree(file: File) {
    val mode = try {
        Os.lstat(file.path).st_mode
    } catch (_: android.system.ErrnoException) {
        // ignored: nothing at the path is the outcome a delete wants.
        return
    }
    if (OsConstants.S_ISDIR(mode)) {
        runCatching { Os.chmod(file.path, 0x1c0) }
        file.list()?.forEach { deleteTree(File(file, it)) }
    }
    if (!file.delete()) throw IllegalStateException("could not delete ${file.path}")
}

private class TarUnpacker(private val root: File) {
    private val canonicalRoot = root.canonicalPath
    private val directories = mutableListOf<Pair<File, Int>>()

    fun unpack(input: InputStream) {
        val header = ByteArray(512)
        var longName: String? = null
        var longLink: String? = null
        var pax = emptyMap<String, String>()
        while (true) {
            if (!readFully(input, header)) break
            if (header.all { it == 0.toByte() }) break
            val size = number(header, 124, 12)
            val type = header[156].toInt().toChar()
            when (type) {
                'L' -> { longName = text(read(input, size)); continue }
                'K' -> { longLink = text(read(input, size)); continue }
                'x' -> { pax = paxRecords(read(input, size)); continue }
                'g' -> { skip(input, size); continue }
            }
            val prefix = string(header, 345, 155)
            val name = pax["path"] ?: longName ?: (if (prefix.isEmpty()) "" else "$prefix/") + string(header, 0, 100)
            val link = pax["linkpath"] ?: longLink ?: string(header, 157, 100)
            val length = pax["size"]?.toLong() ?: size
            longName = null
            longLink = null
            pax = emptyMap()
            val mode = number(header, 100, 8).toInt() and 0x1ff
            val target = inside(name)
            if (target == null) {
                skip(input, length)
                continue
            }
            when (type) {
                '5' -> {
                    target.mkdirs()
                    directories += target to mode
                }
                '2' -> {
                    target.parentFile?.mkdirs()
                    target.delete()
                    Os.symlink(link, target.path)
                }
                '1' -> {
                    val source = inside(link) ?: throw IllegalStateException("hard link outside the system: $link")
                    target.parentFile?.mkdirs()
                    target.delete()
                    source.copyTo(target)
                    Os.chmod(target.path, source.let { Os.stat(it.path).st_mode and 0xfff })
                }
                '0', '\u0000', '7' -> {
                    target.parentFile?.mkdirs()
                    target.delete()
                    target.outputStream().use { copy(input, it, length) }
                    pad(input, length)
                    Os.chmod(target.path, mode or 0x180)
                    continue
                }
                else -> {}
            }
            skip(input, length)
        }
        for ((directory, mode) in directories.asReversed()) Os.chmod(directory.path, mode or 0x1c0)
    }

    private fun inside(name: String): File? {
        val clean = name.trimStart('/').removePrefix("./")
        if (clean.isEmpty() || clean == ".") return null
        val file = File(root, clean)
        val path = File(file.parentFile?.canonicalPath ?: canonicalRoot, file.name).path
        return if (path == canonicalRoot || path.startsWith("$canonicalRoot/")) file else null
    }

    private fun readFully(input: InputStream, buffer: ByteArray): Boolean {
        var offset = 0
        while (offset < buffer.size) {
            val n = input.read(buffer, offset, buffer.size - offset)
            if (n < 0) {
                if (offset == 0) return false
                throw IllegalStateException("archive ends inside a header")
            }
            offset += n
        }
        return true
    }

    private fun read(input: InputStream, size: Long): ByteArray {
        val bytes = ByteArray(size.toInt())
        if (!readFully(input, bytes)) throw IllegalStateException("archive ends inside an entry")
        pad(input, size)
        return bytes
    }

    private fun copy(input: InputStream, output: OutputStream, size: Long) {
        val buffer = ByteArray(1 shl 16)
        var left = size
        while (left > 0) {
            val n = input.read(buffer, 0, minOf(buffer.size.toLong(), left).toInt())
            if (n < 0) throw IllegalStateException("archive ends inside a file")
            output.write(buffer, 0, n)
            left -= n
        }
    }

    private fun skip(input: InputStream, size: Long) {
        var left = size + padding(size)
        val buffer = ByteArray(8192)
        while (left > 0) {
            val n = input.read(buffer, 0, minOf(buffer.size.toLong(), left).toInt())
            if (n < 0) throw IllegalStateException("archive ends inside an entry")
            left -= n
        }
    }

    private fun pad(input: InputStream, size: Long) {
        var left = padding(size)
        while (left > 0) {
            val n = input.skip(left)
            if (n <= 0) {
                if (input.read() < 0) throw IllegalStateException("archive ends inside padding")
                left -= 1
            } else {
                left -= n
            }
        }
    }

    private fun padding(size: Long) = (512 - size % 512) % 512

    private fun string(bytes: ByteArray, offset: Int, length: Int): String {
        var end = offset
        while (end < offset + length && bytes[end] != 0.toByte()) end++
        return String(bytes, offset, end - offset, Charsets.UTF_8)
    }

    private fun text(bytes: ByteArray) = String(bytes, Charsets.UTF_8).trimEnd('\u0000')

    private fun number(bytes: ByteArray, offset: Int, length: Int): Long {
        if (bytes[offset].toInt() and 0x80 != 0) {
            var value = 0L
            for (i in offset + 1 until offset + length) value = (value shl 8) or (bytes[i].toLong() and 0xff)
            return value
        }
        val digits = string(bytes, offset, length).trim()
        return if (digits.isEmpty()) 0 else digits.toLong(8)
    }

    private fun paxRecords(bytes: ByteArray): Map<String, String> {
        val records = mutableMapOf<String, String>()
        var offset = 0
        while (offset < bytes.size) {
            val space = (offset until bytes.size).firstOrNull { bytes[it] == ' '.code.toByte() } ?: break
            val length = String(bytes, offset, space - offset).toIntOrNull() ?: break
            val record = String(bytes, space + 1, length - (space - offset) - 2, Charsets.UTF_8)
            val equals = record.indexOf('=')
            if (equals > 0) records[record.substring(0, equals)] = record.substring(equals + 1)
            offset += length
        }
        return records
    }
}

class LinuxService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val shown = notification(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(ID, shown, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID, shown)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        PhoneLinux.kill(this)
        PhoneLinux.changed(this)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "linux"
        private const val ID = 7302
        const val STOP = "dev.luisnquin.upgrade.STOP_LINUX"

        fun foreground(context: Context) {
            val intent = Intent(context, LinuxService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LinuxService::class.java))
        }

        private fun notification(context: Context): Notification {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL, "Linux on this phone", NotificationManager.IMPORTANCE_LOW),
                )
            }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val open = PendingIntent.getActivity(
                context,
                ID,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val stop = PendingIntent.getBroadcast(
                context,
                ID,
                Intent(context, LinuxStopReceiver::class.java).setAction(STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val installing = !PhoneLinux.running()
            builder
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(if (installing) "LINUX · INSTALLING" else "LINUX · RUNNING")
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
            if (!installing) {
                @Suppress("DEPRECATION")
                builder.addAction(0, "STOP", stop)
            }
            return builder.build()
        }
    }
}

class LinuxStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = PhoneLinux.stop(context.applicationContext)
}
