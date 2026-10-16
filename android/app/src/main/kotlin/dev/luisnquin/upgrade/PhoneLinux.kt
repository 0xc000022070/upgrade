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
import io.flutter.FlutterInjector
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
import org.json.JSONArray
import org.json.JSONObject
import org.tukaani.xz.XZInputStream

enum class Manager {
    APT,
    PACMAN,
    APK;

    fun ensure(packages: List<String>): String {
        if (packages.isEmpty()) return ""
        val names = packages.joinToString(" ")
        return when (this) {
            APT -> "export DEBIAN_FRONTEND=noninteractive\n" +
                "dpkg -s $names >/dev/null 2>&1 || { apt-get -o APT::Sandbox::User=root update && " +
                "apt-get -o APT::Sandbox::User=root install -y --no-install-recommends $names; }"
            PACMAN -> "pacman -Q $names >/dev/null 2>&1 || pacman -Sy --needed --noconfirm $names"
            APK -> "apk -U add $names"
        }
    }
}

class Distro(json: JSONObject) {
    val id: String = json.getString("id")
    val manager = Manager.valueOf(json.getString("manager").uppercase())
    val libc: String = json.getString("libc")
    private val rootfs = json.getJSONObject("rootfs")
    val url: String = rootfs.getString("url")
    val sha256: String = rootfs.getString("sha256")
    val strip = rootfs.getInt("strip")
    private val base = strings(json.optJSONArray("base"))
    val installerNeeds = strings(json.optJSONArray("installer_needs"))

    val archive get() = archiveOf(url)

    val setup get() = "set -eu\n" + manager.ensure(base)

    fun open(input: InputStream): InputStream =
        if (archive.endsWith(".xz")) XZInputStream(input) else GZIPInputStream(input)

    companion object {
        val ARCHIVES = listOf("rootfs.tar.gz", "rootfs.tar.xz")

        fun archiveOf(url: String) = if (url.endsWith(".xz")) ARCHIVES[1] else ARCHIVES[0]
    }
}

class Tool(json: JSONObject) {
    val id: String = json.getString("id")
    private val libc: String? = json.optString("libc").ifEmpty { null }
    private val packages = json.optJSONObject("packages")
    private val installer = json.optJSONObject("installer")
    private val needs = json.optJSONObject("needs")
    private val after = json.optJSONObject("after")

    fun fits(distro: Distro) =
        (libc == null || libc == distro.libc) && (packages?.has(distro.id) == true || installer != null)

    fun script(distro: Distro): String {
        packages?.optString(distro.id)?.takeIf { it.isNotEmpty() }?.let {
            return "set -eu\n" + distro.manager.ensure(listOf(it))
        }
        val installer = installer ?: throw IllegalStateException("$id has no way onto ${distro.id}")
        val shell = installer.getString("shell")
        val args = strings(installer.optJSONArray("args")).joinToString(" ")
        val links = strings(installer.optJSONArray("links"))
            .joinToString("") { "ln -sf $it /usr/local/bin/${it.substringAfterLast('/')}\n" }
        val extra = after?.optString(distro.id).orEmpty()
        return "set -eu\n" +
            distro.manager.ensure(distro.installerNeeds + strings(needs?.optJSONArray(distro.id))) + "\n" +
            "curl -fsSL ${installer.getString("url")} -o /tmp/upgrade-install\n" +
            "$shell /tmp/upgrade-install $args\n" +
            "rm -f /tmp/upgrade-install\n" +
            links + extra
    }
}

class Catalog(json: JSONObject) {
    val distros = objects(json.getJSONArray("distros")).map { Distro(it) }
    val tools = objects(json.getJSONArray("tools")).map { Tool(it) }

    fun distro(id: String?) = distros.firstOrNull { it.id == id }
    fun tool(id: String?) = tools.firstOrNull { it.id == id }

    companion object {
        private const val ASSET = "assets/linux/catalog.json"
        @Volatile private var loaded: Catalog? = null

        fun of(context: Context): Catalog = loaded ?: synchronized(this) {
            loaded ?: run {
                val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(ASSET)
                Catalog(JSONObject(context.assets.open(key).use { it.reader().readText() }))
            }.also { loaded = it }
        }
    }
}

private fun strings(array: JSONArray?) = (0 until (array?.length() ?: 0)).map { array!!.getString(it) }

private fun objects(array: JSONArray) = (0 until array.length()).map { array.getJSONObject(it) }

data class Setup(val distro: String, val nix: Boolean, val tools: List<String> = emptyList()) {
    val mark get() = (listOfNotNull(distro, "nix".takeIf { nix }) + tools).joinToString("") { "$it\n" }

    companion object {
        fun read(mark: List<String>): Setup {
            val words = mark.map { it.trim() }.filter { it.isNotEmpty() }
            return Setup(
                words.firstOrNull() ?: "ubuntu",
                "nix" in words,
                words.drop(1).filter { it != "nix" },
            )
        }
    }
}

private object Nix {
    const val URL = "https://releases.nixos.org/nix/nix-2.35.3/nix-2.35.3-aarch64-linux.tar.xz"
    const val SHA256 = "4a770896faa4d308806d0b4516575e0581443dc817d634b951a219a280554c09"
    const val ARCHIVE = "nix.tar.xz"
    const val UNPACKED = "nix/.installer"

    val INSTALL = """
        set -eu
        nix=/nix/store/n2js98b146g5ddfnfyygsddvvg43ficr-nix-2.35.3
        cacert=/nix/store/07xdbx75iszxrf8p2fshxld6xgmmp3wp-nss-cacert-3.123
        mkdir -p /nix/store /nix/var/nix /etc/nix /etc/profile.d
        printf 'build-users-group =\nsandbox = false\nfilter-syscalls = false\nexperimental-features = nix-command flakes\n' > /etc/nix/nix.conf
        for path in /$UNPACKED/store/*; do mv "${'$'}path" /nix/store/; done
        "${'$'}nix/bin/nix-store" --load-db < /$UNPACKED/.reginfo
        "${'$'}nix/bin/nix-env" --quiet -i "${'$'}nix" "${'$'}cacert"
        rm -rf /$UNPACKED
        printf 'if [ -e /root/.nix-profile/etc/profile.d/nix.sh ]; then . /root/.nix-profile/etc/profile.d/nix.sh; fi\n' > /etc/profile.d/nix.sh
        # libgit2 renames by hard link, which PRoot turns into absolute symlinks; Nix builds
        # this repository in a temporary directory and renames it, leaving them dangling.
        cache=/root/.cache/nix/tarball-cache-v2
        mkdir -p ${'$'}cache/objects/info ${'$'}cache/objects/pack ${'$'}cache/refs/heads ${'$'}cache/refs/tags
        printf 'ref: refs/heads/master\n' > ${'$'}cache/HEAD
        printf '[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n' > ${'$'}cache/config
    """.trimIndent()
}

private class LinuxSystem(val id: String, val dir: File) {
    @Volatile var phase = "idle"
    @Volatile var percent = -1
    @Volatile var error: String? = null
    @Volatile var hostKey: String? = null
    @Volatile var installing: Setup? = null
    @Volatile var sshd: Process? = null
    @Volatile var port = 0
    @Volatile var adding = false
    @Volatile var tool: String? = null
    @Volatile var pending = emptyList<String>()
    @Volatile var toolsError: String? = null

    val rootfs get() = File(dir, "rootfs")
    val fakes get() = File(dir, "proc")
    val temp get() = File(dir, "tmp")
    val installed get() = File(rootfs, PhoneLinux.READY_MARK).exists()
    val running get() = sshd?.isAlive == true
    val busy get() = phase in setOf("download", "unpack", "setup", "nix")

    val setup: Setup?
        get() {
            val mark = File(rootfs, PhoneLinux.READY_MARK)
            if (!mark.exists()) return installing
            return Setup.read(mark.readLines())
        }

    val parts get() = if (dir.name == "linux") {
        listOf(rootfs, fakes, temp, File(dir, PhoneLinux.LEGACY)) + Distro.ARCHIVES.map { File(dir, it) } + File(dir, Nix.ARCHIVE)
    } else {
        listOf(dir)
    }
}

object PhoneLinux {
    private const val TAG = "PhoneLinux"
    const val READY_MARK = ".upgrade-ready"
    const val LEGACY = "legacy"
    private const val SSHD_CONFIG = "/etc/ssh/upgrade_sshd_config"
    private const val AUTHORIZED = "/etc/ssh/upgrade_authorized_keys"

    private val SSHD = """
        for gid in ${'$'}(id -G); do
          grep -q "^[^:]*:[^:]*:${'$'}gid:" /etc/group || echo "android_${'$'}gid:x:${'$'}gid:" >> /etc/group
        done
        mkdir -p /run/sshd
        exec /usr/sbin/sshd -D -e -f @CONFIG@ -o Port=@PORT@
    """.trimIndent()

    private val jobs = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private val systems = java.util.concurrent.ConcurrentHashMap<String, LinuxSystem>()

    @Volatile var sink: EventChannel.EventSink? = null

    fun changed(context: Context) {
        val now = states(context)
        main.post { sink?.success(now) }
    }

    private fun base(context: Context) = File(context.filesDir, "linux")
    private fun shelf(context: Context) = File(base(context), "systems")

    private fun legacyId(context: Context) =
        File(base(context), LEGACY).takeIf { it.exists() }?.readText()?.trim()?.takeIf { it.isNotEmpty() }

    private fun system(context: Context, id: String): LinuxSystem = systems.getOrPut(id) {
        LinuxSystem(id, if (legacyId(context) == id) base(context) else File(shelf(context), id))
    }

    private fun known(context: Context): List<LinuxSystem> {
        val ids = shelf(context).list().orEmpty().toMutableSet()
        legacyId(context)?.let { ids += it }
        ids += systems.keys
        return ids.map { system(context, it) }
    }

    fun running() = systems.values.count { it.running }

    private fun busy() = systems.values.any { it.busy || it.adding }

    private fun settle(context: Context) {
        if (running() == 0 && !busy()) LinuxService.stop(context) else LinuxService.refresh(context)
    }

    fun handle(context: Context, method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        val app = context.applicationContext
        if (method == "state") return result.success(states(app))
        val id = args?.get("id") as? String ?: return result.error("args", "id required", null)
        if (id.isEmpty() || id.contains('/') || id.startsWith(".")) return result.error("args", "bad id", null)
        when (method) {
            "adopt" -> {
                val marker = File(base(app), LEGACY)
                if (!marker.exists() && File(base(app), "rootfs").exists()) {
                    systems.remove(id)
                    marker.writeText(id)
                }
                result.success(null)
            }
            "install" -> {
                val key = args?.get("publicKey") as? String
                val distro = Catalog.of(app).distro(args?.get("distro") as? String)
                if (key == null || distro == null) return result.error("args", "publicKey and distro required", null)
                val system = system(app, id)
                if (system.busy || system.adding) return result.success(state(system))
                val setup = Setup(distro.id, args?.get("nix") == true, tools(app, args))
                system.installing = setup
                system.phase = "download"
                system.percent = 0
                system.error = null
                changed(app)
                LinuxService.foreground(app)
                jobs.execute {
                    try {
                        synchronized(system) { install(app, system, key, setup) }
                        system.phase = "ready"
                        if (setup.tools.isNotEmpty()) add(app, system, setup.tools)
                    } catch (failure: Exception) {
                        Log.e(TAG, "install", failure)
                        system.error = failure.message ?: failure.toString()
                        system.phase = "failed"
                    } finally {
                        system.percent = -1
                        settle(app)
                        changed(app)
                    }
                }
                result.success(state(system))
            }
            "start" -> {
                val key = args?.get("publicKey") as? String
                val port = args?.get("port") as? Int
                if (key == null || port == null) return result.error("args", "publicKey and port required", null)
                val system = system(app, id)
                LinuxService.foreground(app)
                jobs.execute {
                    val outcome = try {
                        synchronized(system) { start(app, system, key, port) }
                        null
                    } catch (failure: Exception) {
                        Log.e(TAG, "start", failure)
                        failure.message ?: failure.toString()
                    }
                    settle(app)
                    changed(app)
                    main.post {
                        if (outcome == null) result.success(state(system)) else result.error("start", outcome, null)
                    }
                }
            }
            "tools" -> {
                val system = system(app, id)
                if (!system.installed || system.busy || system.adding) return result.success(state(system))
                add(app, system, tools(app, args))
                result.success(state(system))
            }
            "stop" -> {
                val system = system(app, id)
                jobs.execute {
                    synchronized(system) { kill(app, system) }
                    settle(app)
                    changed(app)
                    main.post { result.success(state(system)) }
                }
            }
            "remove" -> {
                val system = system(app, id)
                jobs.execute {
                    val outcome = runCatching {
                        synchronized(system) {
                            kill(app, system)
                            for (part in system.parts) deleteTree(part)
                        }
                    }
                    systems.remove(id)
                    settle(app)
                    changed(app)
                    main.post {
                        outcome.fold({ result.success(state(system)) }, { result.error("remove", it.message, null) })
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun states(context: Context): Map<String, Any?> =
        mapOf("systems" to known(context).associate { it.id to state(it) })

    private fun state(system: LinuxSystem): Map<String, Any?> {
        val setup = system.setup
        return mapOf(
            "installed" to system.installed,
            "running" to system.running,
            "phase" to system.phase,
            "percent" to system.percent,
            "error" to system.error,
            "hostKey" to (system.hostKey ?: readHostKey(system)),
            "distro" to setup?.distro,
            "nix" to (setup?.nix == true),
            "tools" to setup?.tools.orEmpty(),
            "tool" to system.tool,
            "pending" to system.pending,
            "toolsError" to system.toolsError,
        )
    }

    private fun tools(context: Context, args: Map<*, *>?): List<String> {
        val asked = (args?.get("tools") as? List<*>).orEmpty()
        return Catalog.of(context).tools.map { it.id }.filter { it in asked }
    }

    private fun add(context: Context, system: LinuxSystem, tools: List<String>) {
        system.adding = true
        system.pending = tools
        system.toolsError = null
        changed(context)
        LinuxService.foreground(context)
        jobs.execute {
            try {
                val catalog = Catalog.of(context)
                for (tool in catalog.tools.filter { it.id in tools }) {
                    val setup = system.setup ?: throw IllegalStateException("Linux is not installed")
                    val distro = catalog.distro(setup.distro) ?: throw IllegalStateException("${setup.distro} is not offered")
                    if (tool.id in setup.tools || !tool.fits(distro)) continue
                    system.tool = tool.id
                    changed(context)
                    step(context, system, tool.id, tool.script(distro), 20)
                    File(system.rootfs, READY_MARK).writeText(setup.copy(tools = setup.tools + tool.id).mark)
                }
                system.pending = emptyList()
            } catch (failure: Exception) {
                Log.e(TAG, "tools", failure)
                system.toolsError = failure.message ?: failure.toString()
            } finally {
                system.tool = null
                system.adding = false
                settle(context)
                changed(context)
            }
        }
    }

    private fun readHostKey(system: LinuxSystem): String? {
        val pub = File(system.rootfs, "etc/ssh/ssh_host_ed25519_key.pub")
        return if (pub.exists()) pub.readText().trim() else null
    }

    private fun install(context: Context, system: LinuxSystem, publicKey: String, setup: Setup) {
        if (system.installed) return
        val distro = Catalog.of(context).distro(setup.distro) ?: throw IllegalStateException("${setup.distro} is not offered")
        val dir = system.dir.apply { mkdirs() }
        for (other in Distro.ARCHIVES) if (other != distro.archive) File(dir, other).delete()
        val archive = File(dir, distro.archive)
        if (!archive.exists() || sha256(archive) != distro.sha256) download(context, system, distro.url, distro.sha256, archive)
        val nix = File(dir, Nix.ARCHIVE)
        if (!setup.nix) nix.delete()
        else if (!nix.exists() || sha256(nix) != Nix.SHA256) download(context, system, Nix.URL, Nix.SHA256, nix)
        system.phase = "unpack"
        system.percent = -1
        changed(context)
        // Never moved after unpack: PRoot stores hard links as absolute symlinks, so a
        // renamed rootfs is full of dead links. The ready mark says it is whole.
        val root = system.rootfs
        deleteTree(root)
        root.mkdirs()
        archive.inputStream().use { TarUnpacker(root, distro.strip).unpack(distro.open(BufferedInputStream(it, 1 shl 16))) }
        File(root, "etc/resolv.conf").apply { delete() }.writeText("nameserver 1.1.1.1\nnameserver 8.8.8.8\n")
        File(root, "etc/hosts").writeText("127.0.0.1 localhost\n::1 localhost\n")
        if (distro.manager == Manager.APT) {
            File(root, "usr/sbin/policy-rc.d").apply { writeText("#!/bin/sh\nexit 101\n") }.setExecutable(true, false)
        }
        val zone = TimeZone.getDefault().id
        File(root, "etc/localtime").delete()
        Os.symlink("/usr/share/zoneinfo/$zone", File(root, "etc/localtime").path)
        File(root, "etc/timezone").writeText("$zone\n")
        File(root, "root").mkdirs()
        File(root, "tmp").mkdirs()
        system.phase = "setup"
        changed(context)
        val script = distro.setup + "\n" + """
            mkdir -p /run/sshd
            passwd -d root
            test -f /etc/ssh/ssh_host_ed25519_key || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
        """.trimIndent()
        step(context, system, "setup", script, 20)
        if (setup.nix) {
            system.phase = "nix"
            changed(context)
            nix.inputStream().use { TarUnpacker(File(root, Nix.UNPACKED), 1).unpack(XZInputStream(BufferedInputStream(it, 1 shl 16))) }
            step(context, system, "nix", Nix.INSTALL, 20)
        }
        writeSshd(root, publicKey)
        File(root, READY_MARK).writeText(setup.copy(tools = emptyList()).mark)
        archive.delete()
        nix.delete()
        system.hostKey = readHostKey(system)
    }

    private fun step(context: Context, system: LinuxSystem, name: String, script: String, minutes: Long) {
        val exit = run(context, system, name, script, TimeUnit.MINUTES.toSeconds(minutes))
        if (exit != 0) throw IllegalStateException("$name exited $exit")
    }

    private fun download(context: Context, system: LinuxSystem, url: String, sha256: String, target: File) {
        val part = File(target.path + ".part")
        system.percent = 0
        changed(context)
        val connection = URL(url).openConnection() as HttpURLConnection
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
                        if (now != system.percent) {
                            system.percent = now
                            changed(context)
                        }
                    }
                }
            }
            val sum = digest.digest().joinToString("") { "%02x".format(it) }
            if (sum != sha256) {
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

    private fun start(context: Context, system: LinuxSystem, publicKey: String, port: Int) {
        if (!system.installed) throw IllegalStateException("Linux is not installed")
        if (system.running && system.port == port) {
            writeSshd(system.rootfs, publicKey)
            return
        }
        kill(context, system)
        writeSshd(system.rootfs, publicKey)
        val process = builder(context, system, SSHD.replace("@CONFIG@", SSHD_CONFIG).replace("@PORT@", "$port"))
            .redirectErrorStream(true)
            .start()
        system.sshd = process
        system.port = port
        Thread {
            runCatching { process.inputStream.bufferedReader().forEachLine { Log.i(TAG, "sshd ${system.id}: $it") } }
            val code = runCatching { process.waitFor() }.getOrDefault(-1)
            Log.i(TAG, "sshd ${system.id} exited $code")
            if (system.sshd === process) {
                system.sshd = null
                settle(context)
                changed(context)
            }
        }.start()
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

    fun stopAll(context: Context) {
        killAll(context)
        LinuxService.stop(context)
        changed(context)
    }

    /// PRoot dies alone on a signal and leaves its tracees running, so every process the
    /// system runs is found by the loader PRoot executes it through.
    fun killAll(context: Context) {
        val processes = systems.values.mapNotNull { system -> system.sshd.also { system.sshd = null } }
        terminate(context) { true }
        for (process in processes) if (!process.waitFor(2, TimeUnit.SECONDS)) process.destroyForcibly()
    }

    /// One system's processes are told from another's by the files they map, which PRoot
    /// opens from that system's rootfs, or failing that by the PRoot they descend from.
    private fun kill(context: Context, system: LinuxSystem) {
        val process = system.sshd
        system.sshd = null
        val proot = File(context.applicationInfo.nativeLibraryDir, "libproot.so").path
        terminate(context) { pid -> owned(pid, system, proot) }
        if (process != null && !process.waitFor(2, TimeUnit.SECONDS)) process.destroyForcibly()
    }

    private fun terminate(context: Context, mine: (Int) -> Boolean) {
        val loader = File(context.applicationInfo.nativeLibraryDir, "libproot-loader.so").path
        fun ours() = tracees(loader).filter(mine)
        for (pid in ours()) runCatching { Os.kill(pid, OsConstants.SIGTERM) }
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (ours().isNotEmpty() && System.nanoTime() < deadline) Thread.sleep(50)
        for (pid in ours()) runCatching { Os.kill(pid, OsConstants.SIGKILL) }
    }

    private fun owned(pid: Int, system: LinuxSystem, proot: String): Boolean {
        val rootfs = system.rootfs.canonicalPath + "/"
        val maps = runCatching { File("/proc/$pid/maps").readText() }.getOrNull()
        if (maps != null && maps.contains(rootfs)) return true
        var at = pid
        repeat(64) {
            at = parent(at) ?: return false
            if (runCatching { Os.readlink("/proc/$at/exe") }.getOrNull() != proot) return@repeat
            val args = runCatching { File("/proc/$at/cmdline").readText().split('\u0000') }.getOrNull() ?: return false
            return args.getOrNull(args.indexOf("-r") + 1) == system.rootfs.path
        }
        return false
    }

    private fun parent(pid: Int): Int? = runCatching {
        val stat = File("/proc/$pid/stat").readText()
        stat.substring(stat.lastIndexOf(')') + 2).split(' ')[1].toInt()
    }.getOrNull()?.takeIf { it > 1 }

    private fun tracees(loader: String): List<Int> =
        File("/proc").listFiles().orEmpty().mapNotNull { entry ->
            val pid = entry.name.toIntOrNull() ?: return@mapNotNull null
            pid.takeIf { runCatching { Os.readlink("/proc/$pid/exe") }.getOrNull() == loader }
        }

    private fun run(context: Context, system: LinuxSystem, name: String, script: String, timeoutSeconds: Long): Int {
        val process = builder(context, system, script).redirectErrorStream(true).start()
        val reader = Thread { runCatching { process.inputStream.bufferedReader().forEachLine { Log.i(TAG, it) } } }
        reader.start()
        if (!process.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            throw IllegalStateException("$name timed out")
        }
        reader.join(2000)
        return process.exitValue()
    }

    private fun procFakes(system: LinuxSystem): Array<String> {
        val dir = system.fakes.apply { mkdirs() }
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

    private fun builder(context: Context, system: LinuxSystem, script: String): ProcessBuilder {
        val native = File(context.applicationInfo.nativeLibraryDir)
        val temp = system.temp.apply { mkdirs() }
        val builder = ProcessBuilder(
            File(native, "libproot.so").path,
            "--kill-on-exit",
            "--link2symlink",
            "-0",
            "-r", system.rootfs.path,
            "-b", "/dev",
            "-b", "/proc",
            "-b", "/sys",
            *procFakes(system),
            "-b", "${temp.path}:/dev/shm",
            "-b", "${File(native, "libupgraded.so").path}:/usr/local/bin/upgraded",
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

private class TarUnpacker(private val root: File, private val strip: Int) {
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
            val target = inside(stripped(name) ?: "")
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
                    val source = inside(stripped(link) ?: "") ?: throw IllegalStateException("hard link outside the system: $link")
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

    private fun stripped(name: String): String? {
        val parts = name.trimStart('/').removePrefix("./").split('/')
        return if (parts.size > strip) parts.drop(strip).joinToString("/") else null
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
        PhoneLinux.killAll(this)
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

        fun refresh(context: Context) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(ID, notification(context))
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
            val running = PhoneLinux.running()
            val installing = running == 0
            builder
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(
                    when (running) {
                        0 -> "LINUX · INSTALLING"
                        1 -> "LINUX · RUNNING"
                        else -> "LINUX · $running RUNNING"
                    },
                )
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
    override fun onReceive(context: Context, intent: Intent) = PhoneLinux.stopAll(context.applicationContext)
}
