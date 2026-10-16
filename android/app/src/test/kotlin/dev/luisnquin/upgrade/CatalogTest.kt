package dev.luisnquin.upgrade

import java.io.File
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CatalogTest {
    private fun json() = JSONObject(File("../../assets/linux/catalog.json").readText())

    private fun refused(change: (JSONObject) -> Unit): String {
        val json = json().also(change)
        return assertThrows(IllegalStateException::class.java) { Catalog(json) }.message.orEmpty()
    }

    private fun JSONObject.tool(id: String): JSONObject {
        val tools = getJSONArray("tools")
        return (0 until tools.length()).map { tools.getJSONObject(it) }.first { it.getString("id") == id }
    }

    @Test
    fun fitsEveryToolOntoTheDistrosItWasBuiltFor() {
        val catalog = Catalog(json())
        val matrix = catalog.tools.associate { tool -> tool.id to catalog.distros.filter { tool.fits(it) }.map { it.id } }
        assertEquals(
            mapOf(
                "tmux" to listOf("ubuntu", "arch", "alpine"),
                "herdr" to listOf("ubuntu", "arch", "alpine"),
                "claude" to listOf("ubuntu", "arch", "alpine"),
                "codex" to listOf("ubuntu", "arch", "alpine"),
                "cursor" to listOf("ubuntu", "arch"),
                "opencode" to listOf("ubuntu", "arch", "alpine"),
            ),
            matrix,
        )
    }

    @Test
    fun quotesWhatItInterpolates() {
        val catalog = Catalog(json())
        val alpine = catalog.distro("alpine")!!
        val claude = catalog.tool("claude")!!
        val script = claude.script(alpine)
        assertTrue(script, script.contains("apk -U add 'bash' 'curl' 'libgcc' 'libstdc++' 'ripgrep'"))
        assertTrue(script, script.contains("bash /tmp/upgrade-install\n"))
        assertTrue(script, script.contains("ln -sf '/root/.local/bin/claude' '/usr/local/bin/claude'"))
        assertEquals("/root/.claude/settings.json", claude.files(alpine).single().path)
        assertEquals("'a'\\''b'", quote("a'b"))
    }

    @Test
    fun runsTheInstallerTheAppFetchedAndNeverItsUrl() {
        val catalog = Catalog(json())
        for (tool in catalog.tools) {
            for (distro in catalog.distros.filter { tool.fits(it) }) {
                val installer = tool.installer(distro) ?: continue
                val script = tool.script(distro)
                assertFalse(script, script.contains(installer.url))
                assertTrue(script, script.contains("rm -f /tmp/upgrade-install\n"))
            }
        }
        val arch = catalog.distro("arch")!!
        assertNull(catalog.tool("opencode")!!.installer(arch))
    }

    @Test
    fun refusesAnInstallerDigestThatIsNotSha256() {
        val message = refused { it.tool("herdr").getJSONObject("installer").put("sha256", "ABC") }
        assertTrue(message, message.contains("herdr installer sha256"))
    }

    @Test
    fun refusesAnInstallerWithoutADigest() {
        assertThrows(JSONException::class.java) {
            Catalog(json().also { it.tool("herdr").getJSONObject("installer").remove("sha256") })
        }
    }

    @Test
    fun refusesARootfsDigestThatIsNotSha256() {
        val message = refused {
            it.getJSONArray("distros").getJSONObject(2).getJSONObject("rootfs").put("sha256", "0".repeat(63))
        }
        assertTrue(message, message.contains("alpine rootfs sha256"))
    }

    @Test
    fun refusesAnotherVersion() {
        assertTrue(refused { it.put("version", 2) }.contains("2"))
    }

    @Test
    fun refusesAPackageThatIsShell() {
        val message = refused { it.tool("tmux").getJSONObject("packages").put("ubuntu", "tmux; rm -rf /") }
        assertTrue(message, message.contains("tmux packages for ubuntu"))
    }

    @Test
    fun refusesAUrlWithASpace() {
        val message = refused {
            it.getJSONArray("distros").getJSONObject(0).getJSONObject("rootfs").put("url", "https://example.com/a b.tar.gz")
        }
        assertTrue(message, message.contains("ubuntu rootfs url"))
    }

    @Test
    fun refusesALinkThatClimbs() {
        val message = refused {
            it.tool("herdr").getJSONObject("installer").put("links", JSONArray(listOf("/root/../etc/herdr")))
        }
        assertTrue(message, message.contains("herdr installer links"))
    }

    @Test
    fun refusesADistroItDoesNotOffer() {
        val message = refused { it.tool("tmux").getJSONObject("packages").put("gentoo", "tmux") }
        assertTrue(message, message.contains("gentoo"))
    }
}
